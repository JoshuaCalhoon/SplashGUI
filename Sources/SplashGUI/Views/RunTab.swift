import SwiftUI

struct RunTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // The server controls (Start/Stop, port, chips, context slot) live in the custom
        // title bar — see ServerToolbarControls in StatusWidgets.swift + RootView.titleBar.
        SettingsPage {
            SettingsSection("Model & Server") {
                HStack(alignment: .top, spacing: 28) {
                    modelColumn
                        .frame(maxWidth: .infinity, alignment: .leading)
                    serverColumn
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            SettingsSection("Engine") {
                Toggle("Start server on app launch", isOn: $model.config.startOnLaunch)
                    .help("Launch SplashGUI and it serves the saved model on the saved port, no click needed. A server already on the port is adopted instead of double-launched; engine updates (per the source setting below) install first. Quitting stops the server.")
                HStack(spacing: 6) {
                    Text("Engine source")
                        .fixedSize(horizontal: true, vertical: false)
                    Picker("Engine source", selection: $model.config.engineMode) {
                        Text("This build's pin (\(EngineInstaller.defaultPin.version))").tag(EngineMode.pinned)
                        Text("Always latest release").tag(EngineMode.latest)
                        Text("Custom pin").tag(EngineMode.custom)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
                .help("Pinned: always run the engine version this SplashGUI was released and tested with; bumping it takes a new app build. Latest: before every start, check GitHub's newest Splash release and install it (checksum verified against the release's own .sha256); if GitHub can't be reached the installed engine stays. Custom: install the exact build named by the three fields below.")
                switch model.config.engineMode {
                case .pinned:
                    Toggle("Check for engine update on start", isOn: $model.config.checkEngineUpdate)
                        .help("On: each start installs the engine this SplashGUI build pins if a different one is installed. Off: only download if no engine is installed yet.")
                case .latest:
                    Text("Checks GitHub on every start; a newer release downloads before the server launches. Unreachable GitHub keeps the installed engine.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .custom:
                    // No disclosure wrapper: the picker already hides these unless Custom is
                    // picked, so a second fold on top is just one more click.
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledField("Engine version", $model.config.engineVersionOverride, width: 150)
                        LabeledField("Engine URL", $model.config.engineURLOverride, width: 360)
                        LabeledField("SHA-256", $model.config.engineSHA256Override, width: 360)
                        Text("All three are required; they override the published pin entirely.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Installed engine")
                    Spacer()
                    Text(model.engineVersion ?? "not installed")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            logPane
        }
    }

    // The two columns are separate computed properties: inline they push the GridRow's
    // result-builder tree past the type-checker's complexity limit.

    private var modelColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Model")
                    .fixedSize(horizontal: true, vertical: false)
                Picker("Model", selection: model.modelPickerSelection) {
                    ForEach(CatalogModel.catalog) { m in
                        HStack {
                            Text(m.label)
                            Spacer()
                            Text(m.id == "custom" ? "" : m.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }.tag(m.id)
                    }
                }
                .labelsHidden()
            }
            .help("Hub ID, owner/repo[:variant], shown so you know exactly whose upload you're pulling. The DFlash2 draft model pairs automatically. First start downloads weights and prepares them; later starts map from disk. Each model keeps its own sampling and context settings, saved under its full ID including the :variant; switching models swaps them in, and a model you have not tuned starts on its card's sampling.")
            if model.catalogEntry == nil {
                HStack(spacing: 6) {
                    Text(model.config.run.modelID.isEmpty
                        ? "no model ID set; pick Custom… and type owner/repo[:variant]"
                        : model.config.run.modelID)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                TextField("owner/repo[:variant]", text: model.customIDBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            if let entry = model.catalogEntry {
                HStack(spacing: 6) {
                    Image(systemName: entry.onDisk ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(entry.onDisk ? Color.green : Color.orange)
                    Text(entry.onDisk
                         ? "installed, maps from disk"
                         : "not installed, first start pulls it from Hugging Face")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("· \(entry.note)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .help((entry.downloadURL.map { "pulls, pinned to commit \($0). " } ?? "")
                      + "serve --revision pins the download to this exact commit, so a later re-upload under the same file name cannot change what loads. The catalog also carries its sha256; the app checks it against the digest Splash records before starting.")
                if !entry.fitsThisMac {
                    Label("too large for this Mac's memory, expected to fail",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Toggle(isOn: $model.config.run.auto) {
                HStack(spacing: 6) {
                    Text("Auto")
                    if model.catalogEntry == nil && model.config.run.auto {
                        Text("custom models fill auto settings once Splash launches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .help("Size context, memory and KV precision from this Mac's GPU memory ceiling and the selected model's weights, and let the engine size the SSD cache. The greyed fields show what Auto picked; turn it off to use your own values.")
            LabeledField("Max context", autoAwareText($model.config.run.maxContext, model.autoContextText), width: 120)
                .disabled(model.config.run.auto)
                .help("Context limit: a number with optional K, e.g. 100K or 131072. Lower frees KV memory. With Auto on, the app sizes it from this Mac's GPU memory and the model's weights, up to 262144 tokens.")
            LabeledField("Max memory", autoAwareText($model.config.run.maxMemory, model.autoMemoryText), width: 120)
                .disabled(model.config.run.auto)
                .help("Cap on Metal allocations, e.g. 28G. Lower it to leave room for other GPU work. With Auto on, the app uses this Mac's GPU memory ceiling: \(MachineInfo.gb(MachineInfo.metalMaxWorkingSet)) here, of \(MachineInfo.gb(MachineInfo.physicalRAM)) physical RAM (recommendedMaxWorkingSetSize).")
            LabeledField("SSD cache", autoAwareText($model.config.run.maxCacheDisk, model.autoCacheText), width: 120)
                .disabled(model.config.run.auto)
                .help("SSD cache for KV pages and GDN states, e.g. 16G; 0 turns it off. With Auto on, the engine sizes it: a quarter of the volume's free space, up to 32G. A 64K context costs 2.0 GiB of pages here plus a 152 MiB state. The cache does not raise the context limit. Free disk on this volume: \(MachineInfo.gb(MachineInfo.freeDisk)).")
            Toggle("Keep SSD cache across restarts", isOn: $model.config.run.persistentCache)
                .help("Write the SSD tier to ~/Library/Caches/Splash/prefix-cache instead of a temporary directory, so a project you come back to restores its prefix rather than prefilling it again. Needs an SSD cache above 0.")
            HStack(spacing: 6) {
                Text("KV cache")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Picker("KV cache", selection: kvSelection) {
                    Text("BF16").tag("bf16")
                    Text("INT8").tag("int8")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(model.config.run.auto)
                .help("KV cache precision. BF16 is fastest at long contexts and exact; INT8 halves KV memory for RAM-constrained machines, but slows decode at depth and can cost accuracy (4-bit KV exists in Splash but is not offered here). With Auto on, the app picks BF16 and only drops to INT8 when BF16 would leave under a 32K window. Restart to apply.")
            }
        }
    }

    private var serverColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledField("Idle release", $model.config.run.idleRelease, width: 120)
                .help("How long the engine keeps its memory wired without a request: a duration such as 30m or 2h, or off. The engine's own default is 10m, after which the next request pays a weight restore and a slower first prefill. off keeps the weights resident until POST /v1/memory/release.")
            SliderNumberField(
                label: "Decode share",
                value: $model.config.run.decodeShare,
                range: 0...1, step: 0.05, digits: 2
            )
            .help("When a long prompt prefills while other requests decode, each prefill slice owes this fraction of its own duration to the decoding lanes. 0.5 default; higher keeps in-flight outputs fast at the cost of the new prompt's TTFT; 0 alternates one command each. Only matters under concurrency.")
            HStack(spacing: 6) {
                Text("Default reasoning effort")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Picker("Default reasoning effort", selection: model.reasoningEffortBinding) {
                    Text("model default").tag(String?.none)
                    ForEach(model.supportedEfforts, id: \.self) { e in
                        Text(e).tag(String?.some(e))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("The effort Splash uses for requests that don't set one, such as the web chat on Default or OpenCode with no variant picked. Clients that ask for an effort get what they ask for, and Anthropic-style clients like Claude Code always say. Restart to apply.")
                Spacer()
            }
            Toggle("Language only (skip vision)", isOn: $model.config.run.languageOnly)
                .help("Serve text only: skips loading the vision projector, saving memory. Restart to apply.")
            HStack(spacing: 6) {
                Toggle("Built-in web chat page", isOn: $model.config.run.showWebUI)
                    .help("Serve Splash's built-in chat page at the server URL.")
                // Shipped bug fixed: the button used to show whenever the server was ready,
                // even with the page off (--no-webui) — where it opened a URL that isn't served.
                if model.config.run.showWebUI, model.phase == .ready {
                    Button("Open built-in chat") { openWebChat() }
                }
                Spacer()
            }
        }
    }

    private func openWebChat() {
        if let url = URL(string: "http://127.0.0.1:" + String(model.config.run.port)) {
            NSWorkspace.shared.open(url)
        }
    }

    // While Auto is on the field shows Auto's value and swallows edits (it is disabled — this
    // binding just keeps the typed value untouched underneath).
    private func autoAwareText(_ typed: Binding<String>, _ autoValue: String) -> Binding<String> {
        Binding(
            get: { model.config.run.auto ? autoValue : typed.wrappedValue },
            set: { if !model.config.run.auto { typed.wrappedValue = $0 } }
        )
    }

    // The KV picker follows the same rule: Auto's pick while Auto is on, the typed value below.
    private var kvSelection: Binding<String> {
        Binding(
            get: { model.config.run.auto ? model.autoKVFormat : model.config.run.kvFormat },
            set: { if !model.config.run.auto { model.config.run.kvFormat = $0 } }
        )
    }

    @ViewBuilder
    private var logPane: some View {
        VStack(spacing: 0) {
            Divider()
            ZStack(alignment: .topTrailing) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.logTail.isEmpty
                             ? "no log output yet"
                             : model.logTail.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(model.logTail.isEmpty ? .tertiary : .secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .id("logEnd")
                    }
                    .frame(height: 170)
                    .onChange(of: model.logTail.count) {
                        proxy.scrollTo("logEnd", anchor: .bottom)
                    }
                }
                if !model.logTail.isEmpty {
                    Button {
                        let text = model.logTail.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the log to the clipboard")
                    .padding(6)
                }
            }
        }
        .background(.bar)
    }
}

struct LabeledField: View {
    let title: String
    @Binding var text: String
    var width: CGFloat

    init(_ title: String, _ text: Binding<String>, width: CGFloat) {
        self.title = title
        self._text = text
        self.width = width
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            TextField(title, text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .font(.system(.body, design: .monospaced))
        }
    }
}
