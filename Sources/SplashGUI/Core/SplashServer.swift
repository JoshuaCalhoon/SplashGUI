import Foundation

final class LogRing {
    private let lock = NSLock()
    private var lines: [String] = []
    private let cap = 800

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

final class SplashServer {
    private var process: Process?
    private var watchdog: Process?
    private let log = LogRing()
    private var killTimer: Timer?
    private var logFile: FileHandle?

    static let logFileURL = AppPaths.dataDir.appendingPathComponent("server.log")

    func spawnWatchdog(serverPID: Int, appPID: Int) {
        stopWatchdog()
        let script = """
        exec 2>>/tmp/splashgui-watchdog.log
        SERVER=\(serverPID)
        APP=\(appPID)
        echo "$(date +%T) armed: server=$SERVER app=$APP"
        while kill -0 $SERVER 2>/dev/null; do
          if ! kill -0 $APP 2>/dev/null; then
            echo "$(date +%T) app gone; TERM $SERVER"
            kill -TERM $SERVER 2>/dev/null
            i=0
            while [ $i -lt 12 ]; do
              kill -0 $SERVER 2>/dev/null || { echo "$(date +%T) exited"; exit 0; }
              sleep 0.1
              i=$((i+1))
            done
            echo "$(date +%T) still alive; KILL $SERVER"
            kill -KILL $SERVER 2>/dev/null
            exit 0
          fi
          sleep 1
        done
        echo "$(date +%T) server gone on its own"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            watchdog = p
        } catch {
            log.append("- watchdog failed to spawn: \(error.localizedDescription)")
        }
    }

    func stopWatchdog() {
        if let w = watchdog, w.isRunning {
            kill(w.processIdentifier, SIGKILL)
        }
        watchdog = nil
    }

    var logLines: [String] { log.snapshot() }

    var childPID: Int? {
        guard let p = process, p.isRunning else { return nil }
        return Int(p.processIdentifier)
    }

    func note(_ line: String) {
        log.append(line)
    }

    var isRunning: Bool { process?.isRunning ?? false }

    struct LaunchTarget {
        let executable: String
        let prefixArgs: [String]
    }

    static func resolveLaunch() -> LaunchTarget? {
        let py = EngineInstaller.pythonPath
        if EngineInstaller.isInstalled {
            return LaunchTarget(executable: py.path, prefixArgs: ["-u", EngineInstaller.launcherPath.path])
        }
        #if DEBUG
        let brew = "/opt/homebrew/bin/splash"
        if FileManager.default.isExecutableFile(atPath: brew) {
            return LaunchTarget(executable: brew, prefixArgs: [])
        }
        #endif
        return nil
    }

    func launch(config: RunConfig, revision: String?) throws {
        guard process == nil else { return }
        guard let target = Self.resolveLaunch() else {
            throw ServerError.missingExecutable
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: target.executable)
        p.arguments = target.prefixArgs + Self.buildArguments(for: config, revision: revision)
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["TERM"] = "dumb"
        p.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        try? FileManager.default.createDirectory(
            at: Self.logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Self.logFileURL.path, contents: nil)
        logFile = FileHandle(forWritingAtPath: Self.logFileURL.path)
        logFile?.write(Data("- splash serve launch \(Date())\n".utf8))

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingest(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingest(data)
        }

        p.terminationHandler = { [weak self] proc in
            self?.process = nil
            self?.killTimer?.invalidate()
            self?.killTimer = nil
            self?.log.append("- exited (\(proc.terminationReason), status \(proc.terminationStatus))")
            try? self?.logFile?.close()
            self?.logFile = nil
        }

        try p.run()
        process = p
        log.append("- splash serve launched (pid \(p.processIdentifier))")
    }

    func stop() {
        guard let p = process else { return }
        killTimer?.invalidate()
        killTimer = nil
        let pid = p.processIdentifier
        kill(pid, SIGTERM)
        log.append("- SIGTERM sent (pid \(pid))")
        let t = Timer(timeInterval: 8.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.killTimer = nil
            if self.process?.isRunning == true {
                kill(pid, SIGKILL)
                self.log.append("- SIGKILL fallback (pid \(pid))")
            }
        }
        RunLoop.main.add(t, forMode: .common)
        killTimer = t
    }

    func terminateHard() {
        guard let p = process else { return }
        kill(p.processIdentifier, SIGKILL)
    }

    private func ingest(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            log.append(String(line))
            logFile?.write(Data((String(line) + "\n").utf8))
        }
    }

    static func buildArguments(for config: RunConfig, revision: String? = nil) -> [String] {
        var args = ["serve", "--model", config.modelID, "--port", String(config.port)]
        // A catalog entry pins an exact HF commit, so the pull is reproducible and a later
        // re-upload under the same name cannot change what this Mac loads.
        if let revision, !revision.isEmpty { args += ["--revision", revision] }
        if config.maxContext.lowercased() != "auto", !config.maxContext.isEmpty {
            args += ["--max-context", config.maxContext]
        }
        if config.maxMemory.lowercased() != "auto", !config.maxMemory.isEmpty {
            args += ["--max-memory", config.maxMemory]
        }
        args += ["--kv-format", config.kvFormat]
        // The SSD tier's quota. "0" turns the tier off and has to be passed; "auto" leaves it
        // to the engine (a quarter of the volume's free space, up to 32G) by leaving the flag
        // out; a size like 10G sets it.
        if !config.maxCacheDisk.isEmpty, config.maxCacheDisk.lowercased() != "auto" {
            args += ["--max-cache-disk", config.maxCacheDisk]
        }
        // The tier's files only outlive the process with this. The engine refuses it without a
        // quota, so it follows the storage cache setting.
        if config.persistentCache, !config.maxCacheDisk.isEmpty, config.maxCacheDisk != "0" {
            args += ["--persistent-cache"]
        }
        // How long the engine keeps its memory wired without a request. "auto" leaves the
        // engine's own 10m, which costs a weight restore and a slower first prefill.
        if !config.idleRelease.isEmpty, config.idleRelease.lowercased() != "auto" {
            args += ["--idle-release", config.idleRelease]
        }
        if config.languageOnly { args += ["--language-only"] }
        if !config.showWebUI { args += ["--no-webui"] }
        if abs(config.decodeShare - 0.5) > 0.001 {
            args += ["--decode-share", String(format: "%.2f", config.decodeShare)]
        }
        if let effort = config.defaultReasoningEffort, !effort.isEmpty {
            args += ["--default-reasoning-effort", effort]
        }
        return args
    }
}

enum ServerError: LocalizedError {
    case missingExecutable

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "Splash engine is not installed yet. Use the Run tab to download it."
        }
    }
}