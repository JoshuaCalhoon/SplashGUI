import SwiftUI

struct StageChipsRow: View {
    @EnvironmentObject var model: AppModel
    var flexibleWidth = true  // trailing Spacer fills the container; off inside toolbars

    var body: some View {
        HStack(spacing: 8) {
            chip("prefill", active: model.currentStage == .prefill)
            chip("generation", active: model.currentStage == .decode)
            if flexibleWidth { Spacer() }
        }
        .help("Live request stage from the 2s status poll. Green = active right now: prefill while a prompt is read, generation while tokens come out.")
    }

    private func chip(_ label: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(label)
                .font(.callout)
                .fontWeight(active ? .semibold : .regular)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Green lives on the dot and the chip outline only. An un-clipped tinted fill let the
        // green wash past the rounded border into the title-bar material.
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(active ? Color.green : Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

// The server control row lives in the window toolbar (title-bar strip), so it works from every
// tab. Was the Run-tab mode bar until 2026-10-15; the blank hidden-titlebar strip above it made
// the old placement read as double-height chrome.
struct ServerToolbarControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            contextSlot
                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            StageChipsRow(flexibleWidth: false)
                .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 6) {
                Text("http://127.0.0.1:")
                    .font(.system(.caption, design: .monospaced))
                    .help("The endpoint other services connect to. OpenAI-compatible API under /v1, Anthropic under /v1/messages.")
                // String ports: Text interpolation of an Int applies locale number formatting,
                // which grouped the port as "8,095".
                TextField("", value: $model.config.run.port, format: .number.grouping(.never))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 52)
                    .foregroundStyle(model.portValid ? Color.primary : Color.red)
                    .help("HTTP port of the server. Splash's own default is 8000, which collides with oMLX, 8090 is MTPLX; the app uses 8095. Change if something else owns the port. Editable while running — an edit is a pending change for Apply & Restart.")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(endpoint, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy the endpoint URL")
            }
            .fixedSize(horizontal: true, vertical: false)
            Button("Apply & Restart") { model.restart() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!(model.phase == .ready && model.hasPendingChanges))
                .help("Stop the server and start it again with the edited settings. Model, context, memory, KV and port changes always need this.")
                .fixedSize(horizontal: true, vertical: false)
            if model.phase == .ready || model.phase == .starting {
                Button("Stop", role: .destructive) { model.stop() }
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Button(model.engineVersion == nil ? "Download & start" : "Start") { model.start() }
                    .disabled(!model.canStart || !model.portValid || model.isInstallingEngine)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private var endpoint: String { "http://127.0.0.1:" + String(model.config.run.port) }

    // One slot, three states, switched in place: the engine install / model load progress while
    // getting to ready, the KV context gauge once ready, an empty gauge otherwise.
    @ViewBuilder
    private var contextSlot: some View {
        if model.isInstallingEngine {
            VStack(alignment: .leading, spacing: 3) {
                Text(engineStepLabel)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                ProgressView(value: min(1, max(0.02, model.engineProgress)))
            }
            .help("First launch downloads the Splash engine (~71 MB). Later launches reuse it.")
        } else if model.phase == .starting {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.loadStage.isEmpty ? "starting…" : model.loadStage)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                ProgressView(value: model.loadProgress ?? 0.05)
            }
            .help("Covers the model download (if needed) and engine loading")
        } else if model.phase == .ready, let snap = model.status, let max = snap.maxContextTokens, max > 0 {
            let used = snap.contextUsedFraction ?? 0
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Context")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(snap.contextUsedTokens ?? 0)/\(max / 1024)K")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: used)
                    .progressViewStyle(.linear)
                    .tint(used > 0.9 ? .orange : .accentColor)
            }
            .help("Tokens held by active requests' KV out of the granted window (server pool gauge, updated on the 2s status poll). While the server starts, this shows the download and load progress instead.")
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text("Context")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: 0)
                    .progressViewStyle(.linear)
            }
            .help("Tokens held by active requests' KV out of the granted window (server pool gauge, updated on the 2s status poll). While the server starts, this shows the download and load progress instead.")
        }
    }

    private var engineStepLabel: String {
        let v = model.engineResolvedVersion.map { " \($0)" } ?? ""
        switch model.engineStep {
        case .checking: return "Checking for the engine…"
        case .downloading: return "Downloading Splash\(v) — \(Int(model.engineProgress * 100))%"
        case .verifying: return "Verifying the download…"
        case .extracting: return "Installing the engine…"
        case .validating: return "Checking the engine…"
        case .switching: return "Activating the engine…"
        default: return "Installing the engine…"
        }
    }
}

struct SliderNumberField: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.05
    var digits: Int = 2
    var trailing: String? = nil
    var labelWidth: CGFloat? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            Slider(value: clampedBinding, in: range)
            TextField("", value: clampedBinding, format: .number.precision(.fractionLength(digits)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .monospacedDigit()
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .help(helpText)
    }

    var helpText: String {
        "Drag or type a value; it snaps to \(step) and clamps to \(range.lowerBound)–\(range.upperBound)."
    }

    private var clampedBinding: Binding<Double> {
        Binding(
            get: { value },
            set: { value = Self.snap($0, range: range, step: step) }
        )
    }

    static func snap(_ v: Double, range: ClosedRange<Double>, step: Double) -> Double {
        let clamped = min(max(v, range.lowerBound), range.upperBound)
        guard step > 0 else { return clamped }
        let snapped = (clamped / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}

struct OptionalIntField: View {
    @Binding var value: Int?
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, value: $value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .disabled(value == nil)
                .opacity(value == nil ? 0.4 : 1)
            Toggle("Set", isOn: Binding(
                get: { value != nil },
                set: { value = $0 ? (value ?? 4096) : nil }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
        }
    }
}

struct OptionalUInt64Field: View {
    @Binding var value: UInt64?
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, value: $value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .disabled(value == nil)
                .opacity(value == nil ? 0.4 : 1)
            Toggle("Set", isOn: Binding(
                get: { value != nil },
                set: { value = $0 ? (value ?? 42) : nil }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
        }
    }
}

struct MemoryBar: View {
    let modelBytes: Int?
    let otherBytes: Int?
    let freeBytes: Int?
    let totalBytes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: max(0, geo.size.width * frac(modelBytes)))
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: max(0, geo.size.width * frac(otherBytes)))
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 16)
            .clipShape(Capsule())
            HStack(spacing: 14) {
                legend("model (charged)", modelBytes, .blue)
                legend("other apps + macOS", otherBytes, .orange)
                legend("free", freeBytes, Color.secondary.opacity(0.25))
                Spacer()
                Text("\(MachineInfo.gb(totalBytes)) total")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .help("Unified-memory breakdown. Model = physical pages charged to the server process tree right now. Weights are memory-mapped and fault in on use — idle weights sit as instantly-reclaimable file cache, so this grows during decode and shrinks when idle. Other = everything else in use. Free = available now.")
    }

    private func frac(_ bytes: Int?) -> CGFloat {
        guard let bytes, totalBytes > 0 else { return 0 }
        return max(0, min(1, CGFloat(bytes) / CGFloat(totalBytes)))
    }

    private func legend(_ name: String, _ bytes: Int?, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(name) \(MachineInfo.gb(bytes))")
                .foregroundStyle(.secondary)
        }
    }
}

struct TimeSeriesChart: View {
    struct SeriesDef {
        let name: String
        let color: Color
        let extract: (StatusSample) -> Double?
        let format: (Double) -> String
    }

    let samples: [StatusSample]
    let defs: [SeriesDef]

    private let bracketHeight: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { ctx, size in
                let plotH = max(0, size.height - bracketHeight)
                for i in 1..<4 {
                    let y = plotH * CGFloat(i) / 4
                    var grid = Path()
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(grid, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
                }
                guard samples.count > 1 else { return }
                let span = CGFloat(Double(max(1, samples.count - 1)))
                let xAt = { (i: Int) in CGFloat(Double(i)) / span * size.width }

                for def in defs {
                    let vals = samples.map(def.extract)
                    let present = vals.compactMap { $0 }
                    guard !present.isEmpty else { continue }
                    let scale = p90(present)
                    guard scale > 0 else { continue }
                    var path = Path()
                    var started = false
                    for (i, v) in vals.enumerated() {
                        guard let v else {
                            started = false
                            continue
                        }
                        let clamped = min(v / scale, 1.0)
                        let x = xAt(i)
                        let y = plotH * 0.96 - CGFloat(clamped) * plotH * 0.92
                        if started {
                            path.addLine(to: CGPoint(x: x, y: y))
                        } else {
                            path.move(to: CGPoint(x: x, y: y))
                            started = true
                        }
                    }
                    ctx.stroke(path, with: .color(def.color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }

                drawBracket(ctx: ctx, width: size.width, plotH: plotH)
            }
            .frame(height: 170)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            HStack(spacing: 14) {
                ForEach(defs, id: \.name) { def in
                    HStack(spacing: 4) {
                        Circle().fill(def.color).frame(width: 7, height: 7)
                        Text("\(def.name) \(currentText(def))")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                stageLegend
            }
            .font(.caption)
        }
        .help("Rolling window (8 min at 2s cadence) of /status samples taken only while the server is actively prefilling or decoding — idle periods leave gaps. Each line scales to the 90th percentile of its own values so bursts don't flatten the rest. The strip below shows request stages: orange prefill, green generation.")
    }

    private var stageLegend: some View {
        HStack(spacing: 10) {
            legendDot(.orange, "prefill")
            legendDot(.green, "generation")
        }
    }

    private func legendDot(_ color: Color, _ name: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).foregroundStyle(.secondary)
        }
    }

    private func drawBracket(ctx: GraphicsContext, width: CGFloat, plotH: CGFloat) {
        let stripY = plotH + 3
        let stripH = bracketHeight - 6
        guard samples.count > 1 else { return }
        let span = CGFloat(Double(max(1, samples.count - 1)))
        let xAt = { (i: Int) in CGFloat(Double(i)) / span * width }
        let segWidth = width / span

        for (i, s) in samples.enumerated() {
            guard let stage = s.stage else { continue }
            let color: Color
            switch stage {
            case .prefill: color = .orange
            case .decode: color = .green
            }
            let x = xAt(i)
            let w = max(1.5, segWidth)
            let rect = CGRect(x: x, y: stripY, width: w, height: stripH)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(0.8)))
        }
    }

    private func p90(_ vals: [Double]) -> Double {
        let sorted = vals.sorted()
        let idx = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.9))
        return max(0.0001, sorted[idx])
    }

    private func currentText(_ def: SeriesDef) -> String {
        for sample in samples.reversed() {
            if let v = def.extract(sample) { return def.format(v) }
        }
        return "—"
    }
}