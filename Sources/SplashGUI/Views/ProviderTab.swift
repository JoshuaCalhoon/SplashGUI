import SwiftUI
import AppKit

// Client configs are the app's only path to Splash for sampling: the app itself sends no
// requests (Presets retired), and the engine has no serve-level sampling defaults (spec §7).
struct ProviderTab: View {
    @EnvironmentObject var model: AppModel
    @State private var client: ProviderClient = .opencode

    var body: some View {
        SettingsPage {
            SettingsSection("Client") {
                HStack(spacing: 6) {
                    Picker("Client", selection: $client) {
                        ForEach(ProviderClient.allCases) { c in
                            Text(c.rawValue).tag(c)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help(client.tooltip)
                    Spacer()
                }
            }

            // Sampling and the config preview sit side by side: sampling is a narrow fixed
            // column, the config takes the rest. Stacked, the page ran past 720pt and forced a
            // scroll on every reasonable window.
            SettingsSection("Sampling & Config") {
                HStack(alignment: .top, spacing: 20) {
                    samplingColumn
                        .frame(width: 300, alignment: .leading)
                    configColumn
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var samplingColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button("Reset to model card") { model.resetModelProfile() }
                    .buttonStyle(.link)
                    .help(resetHelp)
                Spacer()
            }
            SamplingFieldRow(label: "Temperature",
                             value: clamped($model.config.sampling.temperature, 0...2),
                             enabled: client.carries(.temperature),
                             help: "Sampling temperature, 0 = greedy (deterministic). Every model card in the catalog recommends 1.0 for thinking mode, and the app starts there. Written into the client config; each model keeps its own value.")
            SamplingFieldRow(label: "Top-p",
                             value: clamped($model.config.sampling.topP, 0...1),
                             enabled: client.carries(.topP),
                             help: "Nucleus sampling cutoff: keep the smallest set of tokens whose probabilities sum to top-p. The model cards recommend 0.95.")
            SamplingFieldRow(label: "Top-k",
                             value: clamped(Binding(
                                get: { Double(model.config.sampling.topK) },
                                set: { model.config.sampling.topK = Int($0.rounded()) }), 1...100),
                             digits: 0,
                             enabled: client.carries(.topK),
                             help: "Keep only the k most likely tokens before sampling. The model cards recommend 20; Splash honours larger values (verified to 200).")
            SamplingFieldRow(label: "Presence penalty",
                             value: clamped($model.config.sampling.presencePenalty, -2...2),
                             enabled: client.carries(.presencePenalty),
                             help: "Penalizes tokens that have already appeared, which curbs repetition. Splash accepts −2 to 2. The Qwen3.8 card asks for 1.5 with thinking off.")
            SamplingFieldRow(label: "Min-p",
                             value: clamped($model.config.sampling.minP, 0...1),
                             enabled: client.carries(.minP),
                             help: "Drops tokens whose probability is below this fraction of the most likely token's. Splash accepts 0 to 1. The Bonsai card asks for 0.05 in thinking mode.")
            HStack(spacing: 10) {
                Text("Max Output Tokens")
                    .lineLimit(1)
                    .frame(width: 112, alignment: .leading)
                OptionalIntField(value: $model.config.sampling.maxTokens, placeholder: "unlimited")
                    .disabled(!client.carries(.maxTokens))
                    .opacity(client.carries(.maxTokens) ? 1 : 0.4)
                Spacer()
            }
            .help("Cap on total generated tokens: reasoning AND visible output both count. The app sends no requests itself, and none of the supported client configs carries a per-request output cap: OpenCode reserves output space from the context limit in the config beside this column.")
            HStack(spacing: 10) {
                Text("Seed")
                    .lineLimit(1)
                    .frame(width: 112, alignment: .leading)
                OptionalUInt64Field(value: $model.config.sampling.seed, placeholder: "random")
                    .disabled(!client.carries(.seed))
                    .opacity(client.carries(.seed) ? 1 : 0.4)
                Spacer()
            }
            .help("Fixed seed reproduces outputs, reliably only when the request runs alone with identical cached prefixes; concurrency changes batching and can change results. Written into the OpenCode config's model options.")
            if let off = cardOffLinkLabel {
                HStack(spacing: 6) {
                    Button(off) { model.applyCardOffSampling() }
                        .buttonStyle(.link)
                        .help(cardOffLinkHelp)
                    Spacer()
                }
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("logit_bias isn't supported: Splash refuses any request that sets it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            Text("The app sends no requests itself; these values reach Splash through the config beside them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var configColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(configCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(model.clientConfigText(for: client))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 300)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            HStack(spacing: 10) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.clientConfigText(for: client),
                                                   forType: .string)
                }
                Button("Save…") { saveConfig() }
                Spacer()
            }
            if client == .opencode {
                Text("Paste the providers block into ~/.config/opencode/opencode.jsonc. It adds SplashGUI to /models and its efforts to /variants; it does not set your default model, small model, or agents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if client == .zed {
                Text("Zed keeps API keys out of settings.json: export SPLASH_API_KEY=local before launching Zed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if client == .claudeCode {
                Text("Merge the env block into ~/.claude/settings.json, and unset ANTHROPIC_API_KEY in the shell so Claude Code uses the local token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if client == .codex {
                Text("Add this to ~/.codex/config.toml, and export SPLASH_API_KEY=local before launching Codex.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var configCaption: String {
        var text = client.configCaption
        if model.providerContextTokens.estimate {
            text += " · the context limit is an estimate until the server runs"
        }
        return text
    }

    // Shown only when thinking is actually off AND the model is in the catalog, i.e. only where
    // there is a card to quote.
    private var cardOffLinkLabel: String? {
        guard model.config.sampling.reasoningEffort == "none", let e = model.catalogEntry else { return nil }
        return String(format: "card set for thinking off: %.2f / %.2f / %d · presence %.1f",
                      e.cardOffTemperature, e.cardOffTopP, e.cardOffTopK, e.cardOffPresencePenalty)
    }

    private var cardOffLinkHelp: String {
        guard let e = model.catalogEntry else { return "" }
        return String(format: "Your model card recommends this set when thinking is off: temperature %.2f, top-p %.2f, top-k %d and presence penalty %.1f. Nothing changes until you click it.",
                      e.cardOffTemperature, e.cardOffTopP, e.cardOffTopK, e.cardOffPresencePenalty)
    }

    private var resetHelp: String {
        let serve = " Reasoning effort goes back to model default, Auto goes back on, and language-only resets with it. Other models keep their own settings."
        if let e = model.catalogEntry {
            return "Forget this model's saved settings and go back to its card: temperature \(e.cardTemperature), top-p \(e.cardTopP), top-k \(e.cardTopK), presence \(e.cardPresencePenalty), min-p \(e.cardMinP)." + serve
        }
        return "Forget this model's saved settings and go back to the shipped defaults: the sampling every card in the catalog publishes." + serve
    }

    private func clamped(_ value: Binding<Double>, _ range: ClosedRange<Double>, digits: Int = 2) -> Binding<Double> {
        Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
        )
    }

    private func saveConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = client.saveName
        panel.allowedContentTypes = client == .codex ? [.plainText] : [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? model.clientConfigText(for: client).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// One sampling row: label (112 pt, shared so the fields align) + numeric text field, greyed
// when the selected client cannot carry the value.
private struct SamplingFieldRow: View {
    let label: String
    @Binding var value: Double
    var digits: Int = 2
    let enabled: Bool
    let help: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
            TextField("", value: $value, format: .number.precision(.fractionLength(0...digits)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .monospacedDigit()
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
            Spacer()
        }
        .help(help)
    }
}
