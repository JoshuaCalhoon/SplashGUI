import SwiftUI

@main
struct SplashGUIApp: App {
    @StateObject private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--install-engine") {
            let args = CommandLine.arguments
            var port = 8095
            if let i = args.firstIndex(of: "--port"), i + 1 < args.count, let p = Int(args[i + 1]) {
                port = p
            }
            exit(EngineInstaller.runCLI(port: port))
        }
        if CommandLine.arguments.contains("--auto-profile") {
            exit(runAutoProfileProbe())
        }
        if CommandLine.arguments.contains("--check-model") {
            setbuf(stdout, nil)
            let cfg = ConfigStore.shared.load()
            if let mismatch = MachineInfo.modelHashMismatch(cfg.run.modelID) {
                print(mismatch)
                exit(1)
            }
            print("\(cfg.run.modelID): hash check passed")
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("SplashGUI") {
            RootView()
                .environmentObject(model)
        }
        .defaultSize(width: 1240, height: 720)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
    }
}

struct RootView: View {
    enum Section: String, CaseIterable, Identifiable {
        case run = "Run"
        case provider = "Provider"
        case status = "Status"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .run: return "server.rack"
            case .provider: return "powerplug"
            case .status: return "gauge"
            }
        }
    }

    @EnvironmentObject var model: AppModel
    @State private var section: Section = .run
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            NavigationSplitView(columnVisibility: $columnVisibility) {
                List(selection: $section) {
                    ForEach(Section.allCases) { s in
                        Label(s.rawValue, systemImage: s.icon).tag(s)
                    }
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(180)
            } detail: {
                Group {
                    switch section {
                    case .run: RunTab()
                    case .provider: ProviderTab()
                    case .status: StatusTab()
                    }
                }
                .safeAreaInset(edge: .bottom) { phaseFooter }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1040, minHeight: 620)
    }

    // The spec §2 fallback. A `.toolbar` sizes its items to content, so the context slot's
    // `maxWidth: .infinity` never stretched: the row collapsed, the chips clipped and the
    // endpoint wrapped over the field. This bar owns the hidden title-bar strip instead, with
    // the traffic-light gutter reserved on the left and the rest of the width given to the
    // controls. `WindowDragArea` keeps the strip draggable like a real title bar.
    private var titleBar: some View {
        HStack(spacing: 0) {
            // Traffic lights + the sidebar toggle live in the strip over the 180pt sidebar;
            // the server controls belong to the detail column, as they did under .toolbar.
            Color.clear
                .frame(width: 192)
            ServerToolbarControls()
                .frame(maxWidth: .infinity)
        }
        .padding(.trailing, 16)
        .frame(height: 54)
        .background(.bar)
        .background(WindowDragArea())
    }

    private var phaseFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(phaseColor)
                .frame(width: 9, height: 9)
            Text(phaseLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var phaseColor: Color {
        switch model.phase {
        case .ready: return .green
        case .starting: return .orange
        case .stopping: return .orange
        case .exited: return .red
        case .stopped: return .secondary
        }
    }

    private var phaseLabel: String {
        switch model.phase {
        case .stopped:
            // A start failure stays on the footer until the next Start (spec §3).
            if let err = model.lastError { return "Stopped: \(err)" }
            return "Stopped"
        case .starting: return "Starting…"
        case .ready:
            let m = model.effectiveModel ?? model.effectiveModelID
            // The port the server is actually on, not the (possibly edited) toolbar field.
            if let launched = model.launchedRunConfig {
                return "Ready · \(m) on 127.0.0.1:" + String(launched.port)
            }
            return "Ready · \(m)"
        case .stopping: return "Stopping…"
        case .exited(let why): return "Exited: \(why)"
        }
    }
}

// Draggable backing for the custom title bar. Buttons and fields sit above it and keep their
// own clicks; empty parts of the strip move the window, like the system title bar did.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

// Headless readout of what the Run tab would do for the configured model: the catalog pin, the
// auto-config, and the exact launch arguments. Mirrors AppModel.currentAutoProfile +
// RunConfig.effective + SplashServer.buildArguments so all of it is verifiable without the GUI.
func runAutoProfileProbe() -> Int32 {
    setbuf(stdout, nil)
    let cfg = ConfigStore.shared.load()
    let id = cfg.run.modelID
    let entry = CatalogModel.catalog.first { $0.id == id }
    let weights = entry?.weightsBytes ?? MachineInfo.cachedModelSize(id)
    let profile = MachineInfo.autoProfile(modelID: id, languageOnly: cfg.run.languageOnly, weightsBytes: weights)
    let eff = cfg.run.effective(using: profile)
    print("model: \(id)  languageOnly: \(cfg.run.languageOnly)")
    if let e = entry {
        print("catalog: revision \(e.revision ?? "unpinned")  sha256 \(e.sha256.map { String($0.prefix(16)) + "…" } ?? "none")")
        if let url = e.downloadURL { print("pull URL: \(url)") }
        if let target = e.targetFile,
           let installed = MachineInfo.installedDigest(for: id, key: "target/\(target)") {
            print("installed target digest: \(installed.prefix(16))…  matches catalog: \(installed == e.sha256)")
        } else if e.sha256 != nil {
            print("installed target digest: none (not installed; the pull will be checked after)")
        }
    } else {
        print("catalog: no entry (custom ID: unpinned, no hash check)")
    }
    print("physicalRAM: \(MachineInfo.gb(MachineInfo.physicalRAM))  availableRAM: \(MachineInfo.gb(MachineInfo.availableRAM))  metalCap: \(MachineInfo.gb(MachineInfo.metalMaxWorkingSet))")
    print("weightsBytes: \(MachineInfo.gb(weights)) (\(weights ?? -1))")
    if let p = profile {
        print("autoProfile: \(p.contextTokens) tokens (\(p.contextTokens / 1024)K)  maxMemory: \(MachineInfo.gb(p.maxMemoryBytes))  kv: \(p.kvFormat)")
    } else {
        print("autoProfile: nil (insufficient headroom; Splash auto-sizes)")
    }
    print("args: splash " + SplashServer.buildArguments(for: eff, revision: entry?.revision).joined(separator: " "))
    return 0
}