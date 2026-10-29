import Foundation
import Metal
import os

enum MachineInfo {
    private static let sizeLock = NSLock()
    private static var sizeCache: [String: Int] = [:]

    // Drop a cached size so the next lookup re-reads disk (e.g. after a model finishes downloading).
    static func invalidateModelSize(_ modelID: String) {
        sizeLock.lock()
        sizeCache[modelID] = nil
        sizeLock.unlock()
    }

    static func cachedModelSize(_ modelID: String) -> Int? {
        sizeLock.lock()
        if let v = sizeCache[modelID] {
            sizeLock.unlock()
            return v
        }
        sizeLock.unlock()
        let v = weightsSize(for: modelID)
        sizeLock.lock()
        sizeCache[modelID] = v
        sizeLock.unlock()
        return v
    }

    static var physicalRAM: Int {
        Int(ProcessInfo.processInfo.physicalMemory)
    }

    // The real GPU wired-memory ceiling for this exact chip/RAM combo, read once at runtime
    // (37.44 GB on the 48 GB M5 Pro). Falls back to the ~66% stock ratio if Metal is unavailable.
    static let metalMaxWorkingSet: Int = {
        if let cap = MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize, cap > 0 {
            return Int(cap)
        }
        return physicalRAM * 66 / 100
    }()

    static var availableRAM: Int? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            UInt32(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size))
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(
                to: integer_t.self,
                capacity: MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
            ) { dataPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, dataPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let avail = UInt64(stats.free_count + stats.inactive_count + stats.speculative_count)
        return Int(avail * UInt64(vm_page_size))
    }

    static var freeDisk: Int? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") else { return nil }
        return (attrs[.systemFreeSize] as? Int64).map(Int.init)
    }

    static func footprint(pid: Int) -> Int? {
        var info = rusage_info_current()
        let r = withUnsafeMutableBytes(of: &info) { rawBuf in
            let typed = rawBuf.bindMemory(to: rusage_info_t?.self)
            return proc_pid_rusage(Int32(pid), RUSAGE_INFO_CURRENT, typed.baseAddress)
        }
        guard r == 0 else { return nil }
        return Int(info.ri_phys_footprint)
    }

    static func childPIDs(of parent: Int) -> [Int] {
        var size = 0
        guard sysctlbyname("kern.proc.all", nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let slots = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: slots)
        guard sysctlbyname("kern.proc.all", &procs, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        guard count > 0, count <= procs.count else { return [] }
        return (0..<count)
            .filter { Int(procs[$0].kp_eproc.e_ppid) == parent }
            .map { Int(procs[$0].kp_proc.p_pid) }
    }

    static func serverFootprint(parentPID: Int) -> Int? {
        var total = footprint(pid: parentPID) ?? 0
        for child in childPIDs(of: parentPID) {
            total += footprint(pid: child) ?? 0
        }
        return total > 0 ? total : nil
    }

    static func weightsSize(for modelID: String) -> Int? {
        guard let dir = weightsDir(for: modelID) else { return nil }
        return directorySize(dir)
    }

    // Splash's selection link for a model ID: <models root>/<owner>/<repo[:variant]>, a symlink
    // to the content-addressed assembly under models/.resolved/ that holds model.json. The
    // variant is part of the link name, so it stays in the path here.
    static func selectionDir(for modelID: String) -> URL? {
        guard let slash = modelID.firstIndex(of: "/") else { return nil }
        let owner = String(modelID[..<slash])
        let repo = String(modelID[modelID.index(after: slash)...])
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Splash/models/\(owner)/\(repo)")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    // The Hugging Face cache directory for a model ID: models--<owner>--<repo>, variant stripped.
    // One implementation of the naming rule; existence is the caller's question.
    static func hfCacheDir(for modelID: String) -> URL? {
        guard let slash = modelID.firstIndex(of: "/") else { return nil }
        let owner = String(modelID[..<slash])
        let repo = String(modelID[modelID.index(after: slash)...]).split(separator: ":").first ?? ""
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--\(owner)--\(repo)")
    }

    static func weightsDir(for modelID: String) -> URL? {
        if let splash = selectionDir(for: modelID) { return splash }
        guard let hf = hfCacheDir(for: modelID),
              FileManager.default.fileExists(atPath: hf.path) else { return nil }
        return hf
    }

    // The digest the engine recorded in model.json for one file of an installed assembly, keyed
    // as the record keys it ("target/<file>.gguf"). nil = not installed, or no record. The
    // engine's quick verify only re-checks these records' paths and byte counts, so comparing a
    // catalog hash against them catches a swapped or edited blob that quick verify would pass.
    static func installedDigest(for modelID: String, key: String) -> String? {
        guard let record = selectionDir(for: modelID)?.appendingPathComponent("model.json"),
              let data = try? Data(contentsOf: record), data.count < 4_194_304,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [String: [String: Any]],
              let entry = files[key] else { return nil }
        return entry["digest"] as? String
    }

    // nil when the installed assembly matches the catalog hash (or there is nothing to compare),
    // else a plain-language explanation. One implementation: Start blocks on it, --check-model prints it.
    static func modelHashMismatch(_ modelID: String) -> String? {
        guard let entry = CatalogModel.catalog.first(where: { $0.id == modelID }),
              let expected = entry.sha256, let target = entry.targetFile
        else { return nil }
        guard let installed = installedDigest(for: modelID, key: "target/\(target)") else { return nil }
        guard installed != expected else { return nil }
        return "\(modelID): the installed \(target) does not match the catalog hash. On disk "
            + "\(installed), expected \(expected). The cached download changed or is corrupt — delete "
            + "~/.cache/huggingface/hub/models--\(entry.owner)--\(entry.hfRepo) and start again to re-pull it."
    }

    // Sums the real bytes under a directory, following symlinks. The Splash model path is a
    // symlink into the HF snapshot and its files are symlinks into the content-addressed blob
    // store, so the default enumerator (which treats symlinks as non-regular) sees nothing.
    // Resolving each path and deduping by resolved URL counts each shared blob exactly once.
    static func directorySize(_ url: URL) -> Int? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let root = url.resolvingSymlinksInPath()
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { return nil }
        var seen = Set<URL>()
        var total = 0
        for case let file as URL in enumerator {
            let real = file.resolvingSymlinksInPath()
            guard let vals = try? real.resourceValues(forKeys: Set(keys)) else { continue }
            guard vals.isRegularFile == true else { continue }
            if !seen.insert(real).inserted { continue }
            total += vals.fileSize ?? 0
        }
        return total > 0 ? total : nil
    }

    // Computes run settings for a model from this Mac's GPU wired-memory ceiling. Pure: no
    // process, no UI. weightsBytes overrides the on-disk lookup (e.g. a catalog estimate
    // before the model has downloaded). Returns nil when the model can't be sized confidently.
    // Keys on the Metal ceiling, NOT free RAM: macOS keeps RAM resident and evicts on demand,
    // so availableRAM sits ~50-60% "used" at idle and would spuriously collapse the pick.
    static func autoProfile(modelID: String, languageOnly: Bool, weightsBytes: Int? = nil) -> AutoProfile? {
        let weights = weightsBytes ?? weightsSize(for: modelID)
        guard let weights else { return nil }
        let maxMemory = metalMaxWorkingSet  // hard GPU wired ceiling; already reserves ~22% for the OS
        let engineFixed = 1_610_612_736  // 1.5 GiB: engine buffers + native MTP draft
        let vision = languageOnly ? 0 : 536_870_912  // 0.5 GiB: vision projector
        let budget = maxMemory - weights - engineFixed - vision
        guard budget > 0 else { return nil }
        let window = CatalogModel.windowTokens
        func context(_ bytesPerToken: Int) -> Int {
            let capped = min(budget / bytesPerToken, window)
            return (capped / 32_768) * 32_768
        }
        // All catalog models are Qwen3.8-27B arch → one KV constant (67 KiB/token BF16, half for INT8).
        let bf16 = context(68_608)
        if bf16 >= 32_768 {
            return AutoProfile(maxMemoryBytes: maxMemory, contextTokens: bf16, kvFormat: "bf16")
        }
        let int8 = context(34_304)
        guard int8 >= 32_768 else { return nil }
        return AutoProfile(maxMemoryBytes: maxMemory, contextTokens: int8, kvFormat: "int8")
    }

    static func gb(_ bytes: Int?) -> String {
        guard let bytes else { return "—" }
        return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}

struct AutoProfile: Equatable {
    let maxMemoryBytes: Int
    let contextTokens: Int
    let kvFormat: String
}