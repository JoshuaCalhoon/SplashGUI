import SwiftUI

struct StatusTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.phase == .ready, let snap = model.status {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    memorySection
                    HStack(alignment: .top, spacing: 10) {
                        Card("TTFT", msText(model.lastRequestTTFT), note: "server p50",
                             help: "Time to first token: how long a request waits before its first token arrives. The median across recent requests, as the server reports it. Long prompts raise it; cached prefixes lower it.")
                        Card("Prefill tok/s", tpsText(model.prefillGaugeValue),
                             note: maximaText(model.prefillMax5m, model.prefillMaxSession),
                             help: "Prompt tokens read per second right now, with the highest rate in the last 5 minutes and in this session.")
                        Card("Decode tok/s", tpsText(model.decodeGaugeValue),
                             note: maximaText(model.decodeMax5m, model.decodeMaxSession),
                             help: "Tokens generated per second right now, with the highest rate in the last 5 minutes and in this session.")
                        Card("Draft acceptance", pctText(snapOfDraft()),
                             help: "Share of the draft model's guessed tokens that the main model accepted. Higher means faster generation; it drops on unpredictable text.")
                        Card("Cache hit rate", pctText(snap.cacheHitRate), note: "lookups \(snap.cacheLookups ?? 0)",
                             help: "Share of prompt lookups that found a cached prefix, so the server skipped reading that part of the prompt again.")
                    }
                    chartBlock

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                              spacing: 10) {
                        Card("TTFT p95", msText(snap.ttftP95),
                             help: "Time to first token for the slowest 5% of recent requests.")
                        Card("ITL p50", msText(snap.itlP50),
                             help: "Inter-token latency: the typical gap between generated tokens. Lower is faster.")
                        Card("ITL p95", msText(snap.itlP95),
                             help: "Inter-token latency for the slowest 5% of gaps between generated tokens.")
                        Card("Reused tokens", compactTokens(snap.reusedTokens),
                             help: "Prompt tokens served from the prefix cache instead of being read again, since the server started. Exact count: \(snap.reusedTokens.map { $0.formatted(.number) } ?? "–").")
                        Card("GDN state", bytesText(snap.stateBytes), note: "\(snap.stateEntries ?? 0) entries",
                             help: "Memory held by cached GDN states, the running state of the model's linear-attention layers, and how many are kept.")
                        Card("Scheduler", schedulerTotal(snap), note: schedulerText(snap),
                             help: "Total requests in the scheduler: the breakdown below counts those waiting, reading their prompt and generating right now.")
                        Card("Free disk", MachineInfo.gb(MachineInfo.freeDisk),
                             note: "volume hosting the SSD cache tier",
                             help: "Free space on the volume that holds the SSD cache.")
                        Card("Engine", model.engineVersion, note: "app-managed",
                             help: "The Splash engine version the app installed and manages, at \(EngineInstaller.currentLink.path).")
                    }

                    Text("Prefix cache is in RAM, and the SSD tier keeps its KV pages and GDN states on disk, including across restarts when “Keep SSD cache across restarts” is on. Restarting the server clears the RAM part; the disk part survives it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "gauge")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(statusText)
                    .foregroundStyle(.secondary)
                if let v = model.engineVersion {
                    Text("engine \(v) installed at \(EngineInstaller.currentLink.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var memorySection: some View {
        if let physical = physicalRAM {
            MemoryBar(
                modelBytes: model.modelFootprint,
                otherBytes: otherUsed,
                freeBytes: availableRAM,
                totalBytes: physical
            )
        }
    }

    @ViewBuilder
    private var chartBlock: some View {
        TimeSeriesChart(samples: model.history, defs: [
            .init(name: "Draft accept", color: .green,
                  extract: { $0.draftAcceptance }, format: { String(format: "%.0f%%", $0 * 100) }),
            .init(name: "Cache hit", color: .mint,
                  extract: { $0.cacheHitRate }, format: { String(format: "%.0f%%", $0 * 100) }),
            .init(name: "Prefill tok/s", color: .orange,
                  extract: { $0.prefillTps }, format: { String(format: "%.0f", $0) }),
            .init(name: "Decode tok/s", color: .blue,
                  extract: { $0.decodeTps }, format: { String(format: "%.0f", $0) })
        ])
    }

    private func maximaText(_ fiveMin: Double?, _ session: Double?) -> String {
        let f = fiveMin.map { String(format: "%.0f", $0) } ?? "–"
        let s = session.map { String(format: "%.0f", $0) } ?? "–"
        return "peak \(f) (5m) · \(s) (session)"
    }

    // "3.77M" style — the grid card has no room for grouped seven-digit counts.
    private func compactTokens(_ n: Int?) -> String? {
        guard let n else { return nil }
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return String(n)
    }

    private var physicalRAM: Int? {
        let v = MachineInfo.physicalRAM
        return v > 0 ? v : nil
    }

    private var availableRAM: Int? {
        MachineInfo.availableRAM
    }

    private var otherUsed: Int? {
        guard let physical = physicalRAM, let avail = availableRAM else { return nil }
        let used = max(0, physical - avail)
        let model = model.modelFootprint ?? 0
        return max(0, used - model)
    }

    private func snapOfDraft() -> Double? {
        model.draftAcceptance ?? model.history.last?.draftAcceptance
    }

    private var statusText: String {
        switch model.phase {
        case .starting:
            return "Starting: status appears once the model has loaded"
        case .stopping:
            return "Stopping…"
        case .ready:
            return "waiting for /status…"
        default:
            return "Server not running; press Start in the toolbar"
        }
    }

    private func msText(_ v: Double?) -> String? {
        v.map { String(format: "%.0f ms", $0) }
    }

    private func tpsText(_ v: Double?) -> String? {
        v.map { String(format: "%.1f", $0) }
    }

    private func pctText(_ v: Double?) -> String? {
        v.map { String(format: "%.1f%%", $0 * 100) }
    }

    private func bytesText(_ v: Int?) -> String {
        guard let v else { return "–" }
        let gb = Double(v) / 1_073_741_824
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        return String(format: "%.0f MB", Double(v) / 1_048_576)
    }

    // The card's big slot is the total; the breakdown lives in the note line like every other
    // card. The three-word form used to sit in the value slot and wrapped to two lines, which
    // made this the tallest card in the grid.
    private func schedulerTotal(_ snap: StatusSnapshot) -> String {
        "\((snap.queued ?? 0) + (snap.prefilling ?? 0) + (snap.decoding ?? 0))"
    }

    private func schedulerText(_ snap: StatusSnapshot) -> String {
        "\(snap.queued ?? 0) queued · \(snap.prefilling ?? 0) prefilling · \(snap.decoding ?? 0) generating"
    }
}

struct Card: View {
    let title: String
    let value: String?
    var note: String = ""
    var help: String = ""

    init(_ title: String, _ value: String?, note: String = "", help: String = "") {
        self.title = title
        self.value = value
        self.note = note
        self.help = help
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "–")
                .font(.system(.title3, design: .monospaced))
                .fontWeight(.medium)
            // Reserve two note lines on every card so a card without a note (Draft acceptance)
            // is the same height as its neighbours, and a wrapping note cannot stretch one card.
            Text(note.isEmpty ? " " : note)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .modifier(HelpIfNotEmpty(help))
    }
}

// .help has no optional overload; an empty tooltip must attach nothing.
private struct HelpIfNotEmpty: ViewModifier {
    let text: String
    init(_ text: String) { self.text = text }
    @ViewBuilder func body(content: Content) -> some View {
        if text.isEmpty { content } else { content.help(text) }
    }
}