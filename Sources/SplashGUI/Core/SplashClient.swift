import Foundation

struct StatusSnapshot {
    let raw: [String: Any]

    subscript(_ path: [String]) -> Any? {
        var current: Any? = raw
        for key in path {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[key]
        }
        return current
    }

    private func num(_ path: [String]) -> Double? {
        guard let v = self[path] else { return nil }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    func number(_ path: String...) -> Double? {
        num(path)
    }

    func string(_ path: String...) -> String? {
        guard let v = self[path] else { return nil }
        return v as? String
    }

    func int(_ path: String...) -> Int? {
        num(path).map { Int($0) }
    }

    var instanceModel: String? { string("instance", "model") }
    var instancePID: Int? { int("instance", "pid") }
    var maxContextTokens: Int? {
        int("maximum_context_tokens") ?? int("native", "maximum_context_tokens")
    }
    // The memory budget Splash actually charged itself (== the --max-memory it was given, or
    // its own ceiling when the flag was omitted). Verified live on 1.3.2, spec §8.1.
    var hardBudgetBytes: Int? { int("memory_plan", "budget", "hard_budget_bytes") }
    var ttftP50: Double? { number("metrics", "ttft_ms", "p50") }
    var ttftP95: Double? { number("metrics", "ttft_ms", "p95") }
    var itlP50: Double? { number("metrics", "itl_ms", "p50") }
    var itlP95: Double? { number("metrics", "itl_ms", "p95") }
    var cacheHitRate: Double? { number("cache", "hit_rate") }
    var cacheLookups: Int? { int("cache", "lookups") }
    var reusedTokens: Int? { int("cache", "reused_tokens") }
    var kvPagesActive: Int? { int("kv", "pages_active") }
    var kvBlockTokens: Int? { int("kv", "block_tokens") }
    // What the running server accepts: ["text"] or ["text","image","pdf"].
    var inputModalities: [String]? { self[["input_modalities"]] as? [String] }

    // Live fraction of the granted context window occupied by active requests' KV:
    // resident tokens (active pages x tokens-per-page) over the ceiling. Server-wide, so it
    // reflects every client (web chat included), not just app-run requests.
    var contextUsedFraction: Double? {
        guard let active = kvPagesActive, let block = kvBlockTokens, block > 0,
              let max = maxContextTokens, max > 0 else { return nil }
        return min(1.0, Double(active * block) / Double(max))
    }
    // Raw tokens held by active requests' KV (pages × tokens-per-page); the toolbar caption
    // shows this over the granted window, the bar shows the fraction.
    var contextUsedTokens: Int? {
        guard let active = kvPagesActive, let block = kvBlockTokens else { return nil }
        return active * block
    }
    var kvResidentBytes: Int? { int("kv", "resident_backing_bytes") }
    var stateBytes: Int? { int("state", "bytes") }
    var stateEntries: Int? { int("state", "entries") }
    var queued: Int? { int("scheduler", "queued") }
    var prefilling: Int? { int("scheduler", "prefilling") }
    var decoding: Int? { int("scheduler", "decoding") }
}

final class SplashClient {
    let port: Int

    init(port: Int) { self.port = port }

    private var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func ready() async -> Bool {
        guard let url = URL(string: "\(baseURL)/ready") else { return false }
        let req = URLRequest(url: url, timeoutInterval: 3)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse { return http.statusCode == 200 }
            return false
        } catch {
            return false
        }
    }

    func fetchStatus() async -> StatusSnapshot? {
        guard let url = URL(string: "\(baseURL)/status") else { return nil }
        let req = URLRequest(url: url, timeoutInterval: 5)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return StatusSnapshot(raw: dict)
        } catch {
            return nil
        }
    }

    func fetchMetric(_ name: String) async -> Double? {
        guard let url = URL(string: "\(baseURL)/metrics") else { return nil }
        let req = URLRequest(url: url, timeoutInterval: 5)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            for line in text.split(separator: "\n") {
                if line.hasPrefix(name + " ") || line.hasPrefix(name + "{") {
                    let parts = line.split(separator: " ")
                    if parts.count >= 2, let v = Double(parts.last!) { return v }
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    func probePort() async -> (open: Bool, pid: Int?, detail: String?) {
        let lockPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Splash/runtime/serve-\(port).lock")
        if let data = try? Data(contentsOf: lockPath),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pid = dict["pid"] as? Int {
            let model = dict["model"] as? String ?? "?"
            let running = kill(Int32(pid), 0) == 0
            if running { return (true, pid, "a Splash server for \(model)") }
        }
        guard let url = URL(string: "\(baseURL)/health") else { return (false, nil, nil) }
        let req = URLRequest(url: url, timeoutInterval: 2)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                return (true, nil, "something responding on port \(port)")
            }
        } catch {}
        return (false, nil, nil)
    }
}