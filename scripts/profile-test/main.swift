// Headless assertions for SplashGUI's config store and per-model profiles — no GUI, no Xcode.
// Run via ./run.sh (it handles the config.json backup/fixture dance). Exits non-zero on any failure.
import Foundation
import SwiftUI

let A = "unsloth/Qwen3.8-27B-GGUF:UD-IQ3_XXS"
let B = "prism-ml/Ternary-Bonsai-2-27B-gguf:PQ2_0"
let C = "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M"

var failures = 0
func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    print((cond ? "PASS  " : "FAIL  ") + label + (detail.isEmpty ? "" : "  — " + detail))
    if !cond { failures += 1 }
}

@MainActor
func runTests() {
    // A: a pre-profiles config still decodes (no fallback to factory) and migrates.
    let cfg = ConfigStore.shared.load()
    check("old config decodes — typed values survived",
          cfg.run.maxContext == "100K" && cfg.sampling.temperature == 0.23,
          "\(cfg.run.maxContext) / \(cfg.sampling.temperature)")
    check("schemaVersion migrated to 6", cfg.run.schemaVersion == 6, "\(cfg.run.schemaVersion ?? -1)")
    // v2 flipped int8→bf16, v3 flipped bf16→auto; v6 then resolved the still-auto KV because
    // the typed maxContext keeps Auto off. The endpoint that matters: a concrete KV pick.
    check("typed serve fields migrate to Auto off", cfg.run.auto == false)
    check("auto KV resolved on the Auto-off migration",
          cfg.run.kvFormat == "bf16" || cfg.run.kvFormat == "int8", cfg.run.kvFormat)
    check("v4->v5 turned the SSD tier on", cfg.run.maxCacheDisk == "10G", cfg.run.maxCacheDisk)
    check("idle release defaults to 60m", cfg.run.idleRelease == "60m", cfg.run.idleRelease)
    check("persistent cache defaults on", cfg.run.persistentCache == true)
    check("current model got a seeded profile", cfg.modelProfiles[A] != nil)
    check("seed keeps tuned temp 0.23", cfg.modelProfiles[A]?.sampling.temperature == 0.23)
    check("key keeps the :variant suffix", cfg.modelProfiles.keys.contains { $0.contains(":UD-IQ3_XXS") })

    // B: switching to an untuned model starts it on its CARD — the thinking-mode set both cards
    // publish (1.0 / 0.95 / 20, reasoning left at model default), not the old invented numbers.
    let m = AppModel()
    m.config.sampling.temperature = 0.42
    m.config.sampling.reasoningEffort = "low"
    m.config.run.defaultReasoningEffort = "low"
    m.config.run.maxContext = "100K"
    m.config.run.languageOnly = true
    m.selectModelID(B)
    check("modelID switched", m.config.run.modelID == B)
    check("outgoing temp archived", m.config.modelProfiles[A]?.sampling.temperature == 0.42)
    check("outgoing maxContext archived", m.config.modelProfiles[A]?.maxContext == "100K")
    check("Bonsai card temp 1.0", m.config.sampling.temperature == 1.0, "\(m.config.sampling.temperature)")
    check("Bonsai card topP 0.95", m.config.sampling.topP == 0.95, "\(m.config.sampling.topP)")
    check("Bonsai card topK 20", m.config.sampling.topK == 20, "\(m.config.sampling.topK)")
    check("card leaves reasoning effort at model default",
          m.config.sampling.reasoningEffort == nil && m.config.run.defaultReasoningEffort == nil)
    check("untuned model: maxContext back to auto", m.config.run.maxContext == "auto", m.config.run.maxContext)
    check("untuned model: languageOnly off", m.config.run.languageOnly == false)

    // C: switching back restores the saved profile.
    m.selectModelID(A)
    check("restored temp 0.42", m.config.sampling.temperature == 0.42, "\(m.config.sampling.temperature)")
    check("restored maxContext 100K", m.config.run.maxContext == "100K")
    check("restored reasoning effort (both places)",
          m.config.sampling.reasoningEffort == "low" && m.config.run.defaultReasoningEffort == "low")

    // D: a second Qwen row is also card-driven, and card data is per row.
    m.selectModelID(C)
    check("Qwen Q4_K_M card temp 1.0", m.config.sampling.temperature == 1.0, "\(m.config.sampling.temperature)")
    check("Qwen Q4_K_M card topP 0.95", m.config.sampling.topP == 0.95)
    let bonsai = CatalogModel.catalog.first { $0.id == B }!
    check("Bonsai hides the unsupported 'low' effort",
          bonsai.supportedEfforts?.contains("low") == false
            && bonsai.supportedEfforts?.contains("xhigh") == true,
          "\(bonsai.supportedEfforts ?? [])")
    m.config.run.modelID = B
    check("model exposes the filtered effort list", m.supportedEfforts == bonsai.supportedEfforts)
    m.config.run.modelID = "someone/Custom-Model:x"
    check("hand-typed ID offers every effort", m.supportedEfforts == CatalogModel.allEfforts)

    // E: reset forgets this model's profile and returns to its card.
    m.config.run.modelID = A
    m.resetModelProfile()
    check("reset cleared the stored profile", m.config.modelProfiles[A] == nil)
    check("reset re-applies the card (1.0 / 0.95 / 20)",
          m.config.sampling.temperature == 1.0 && m.config.sampling.topP == 0.95 && m.config.sampling.topK == 20,
          "\(m.config.sampling.temperature)/\(m.config.sampling.topP)/\(m.config.sampling.topK)")
    check("reset returns serve fields to auto",
          m.config.run.maxContext == "auto" && m.config.run.kvFormat == "auto" && m.config.run.languageOnly == false)

    // G: thinking off offers the card's non-thinking set, and only on click.
    m.config.sampling.reasoningEffort = "none"
    m.config.run.defaultReasoningEffort = "none"
    m.applyCardOffSampling()
    check("card's non-thinking set applied on request (0.7 / 0.80 / 20)",
          m.config.sampling.temperature == 0.7 && m.config.sampling.topP == 0.8 && m.config.sampling.topK == 20,
          "\(m.config.sampling.temperature)/\(m.config.sampling.topP)/\(m.config.sampling.topK)")
    m.config.sampling.temperature = 0.55          // hand-tuned value must survive
    m.config.run.modelID = "someone/Custom-Model:x"
    m.applyCardOffSampling()
    check("hand-typed ID has no card, so nothing is rewritten",
          m.config.sampling.temperature == 0.55, "\(m.config.sampling.temperature)")

    // H: what landed on disk reloads the same.
    let reread = ConfigStore.shared.load()
    check("B's card profile persisted", reread.modelProfiles[B]?.sampling.temperature == 1.0,
          "\(reread.modelProfiles[B]?.sampling.temperature ?? -1)")
    check("typed temp 0.55 survives a save", reread.sampling.temperature == 0.55,
          "\(reread.sampling.temperature)")
    check("schemaVersion stays 6", reread.run.schemaVersion == 6)
    // startOnLaunch is absent from this v2 fixture — the tolerant decoder must default it
    // false, not throw the whole config back to factory (the Codable missing-key trap).
    check("startOnLaunch defaults false when the key is absent", reread.startOnLaunch == false)

    // F: the SSD tier and the idle release reach the engine's command line, and the tier's
    // persistence follows the quota (the engine refuses it without one).
    var run = RunConfig()
    run.maxCacheDisk = "10G"
    run.persistentCache = true
    run.idleRelease = "60m"
    let args = SplashServer.buildArguments(for: run)
    check("serve carries the SSD quota", args.contains("--max-cache-disk") && args.contains("10G"))
    check("serve carries the persistent cache", args.contains("--persistent-cache"))
    check("serve carries the idle release", args.contains("--idle-release") && args.contains("60m"))
    var off = RunConfig()
    off.maxCacheDisk = "0"
    off.persistentCache = true
    check("no persistent cache without a quota",
          !SplashServer.buildArguments(for: off).contains("--persistent-cache"))
    off.persistentCache = false
    off.idleRelease = "auto"
    let offArgs = SplashServer.buildArguments(for: off)
    check("persistent cache can be turned off", !offArgs.contains("--persistent-cache"))
    check("auto leaves the engine's own idle release", !offArgs.contains("--idle-release"))
    off.maxCacheDisk = "auto"
    check("auto leaves the SSD quota to the engine", !SplashServer.buildArguments(for: off).contains("--max-cache-disk"))

    // I: the Auto switch resolves the four covered fields at launch.
    let prof = AutoProfile(maxMemoryBytes: 40_000_000_000, contextTokens: 131_072, kvFormat: "int8")
    var arun = RunConfig()   // shipped default: Auto on
    let effAuto = arun.effective(using: prof)
    check("Auto on: profile sizes context and memory",
          effAuto.maxContext == "131072" && effAuto.maxMemory == "40000000000",
          "\(effAuto.maxContext) / \(effAuto.maxMemory)")
    check("Auto on: KV follows the profile", effAuto.kvFormat == "int8")
    check("Auto on: the SSD cache goes to the engine",
          effAuto.maxCacheDisk == "auto"
            && !SplashServer.buildArguments(for: effAuto).contains("--max-cache-disk"))
    let effCustom = arun.effective(using: nil)
    check("Auto on with no profile: Splash sizes context and memory, KV falls back to bf16",
          !SplashServer.buildArguments(for: effCustom).contains("--max-context")
            && !SplashServer.buildArguments(for: effCustom).contains("--max-memory")
            && effCustom.kvFormat == "bf16")
    arun.auto = false
    arun.maxContext = "64K"; arun.maxMemory = "24G"; arun.kvFormat = "bf16"; arun.maxCacheDisk = "10G"
    let effTyped = arun.effective(using: prof)
    check("Auto off: the typed values launch untouched",
          effTyped.maxContext == "64K" && effTyped.maxMemory == "24G"
            && effTyped.kvFormat == "bf16" && effTyped.maxCacheDisk == "10G")

    // J: the Codable trap on the new fields — a profile saved before `auto` existed must
    // decode with it defaulted, and grantedAuto must round-trip.
    let legacy = #"{"sampling":{"temperature":0.5,"topP":0.9,"topK":10},"maxContext":"50K","maxMemory":"auto","kvFormat":"bf16","languageOnly":false}"#
    if let pdata = legacy.data(using: .utf8),
       let prof2 = try? JSONDecoder().decode(ModelProfile.self, from: pdata) {
        check("legacy profile without auto decodes defaulted",
              prof2.auto == true && prof2.maxContext == "50K")
    } else {
        check("legacy profile without auto decodes defaulted", false, "decoder threw")
    }
    var gcfg = AppConfig()
    gcfg.grantedAuto["someone/Custom-Model:x"] = GrantedSettings(contextTokens: 65536, memoryBytes: 25_769_803_776)
    if let gd = try? JSONEncoder().encode(gcfg),
       let back = try? JSONDecoder().decode(AppConfig.self, from: gd) {
        check("grantedAuto round-trips",
              back.grantedAuto["someone/Custom-Model:x"]?.contextTokens == 65536
                && back.grantedAuto["someone/Custom-Model:x"]?.memoryBytes == 25_769_803_776)
    } else {
        check("grantedAuto round-trips", false, "encode/decode threw")
    }

    // K: a schema-5 config whose four covered fields are all "auto" migrates to Auto ON,
    // leaving the KV field alone for the launch-time resolution.
    let cfgURL = AppPaths.dataDir.appendingPathComponent("config.json")
    if let raw = try? Data(contentsOf: cfgURL),
       var dict = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
       var runDict = dict["run"] as? [String: Any] {
        runDict["schemaVersion"] = 5
        runDict["maxContext"] = "auto"
        runDict["maxMemory"] = "auto"
        runDict["kvFormat"] = "auto"
        runDict["maxCacheDisk"] = "auto"
        dict["run"] = runDict
        if let out = try? JSONSerialization.data(withJSONObject: dict) {
            try? out.write(to: cfgURL)
            let migrated = ConfigStore.shared.load()
            check("all-auto schema 5 migrates to Auto on", migrated.run.auto == true)
            check("all-auto migration leaves KV at auto",
                  migrated.run.kvFormat == "auto", migrated.run.kvFormat)
            check("all-auto migration lands on schema 6", migrated.run.schemaVersion == 6)
        } else {
            check("all-auto schema 5 migrates to Auto on", false, "fixture write failed")
        }
    } else {
        check("all-auto schema 5 migrates to Auto on", false, "fixture unreadable")
    }

    // L: the Provider tab's new sampling fields and client configs.
    let legacySampling = #"{"temperature":0.5,"topP":0.9,"topK":10,"maxTokens":null,"seed":null,"reasoningEffort":"none"}"#
    if let sdata = legacySampling.data(using: .utf8),
       let sam = try? JSONDecoder().decode(SamplingDefaults.self, from: sdata) {
        check("legacy sampling without presencePenalty/minP decodes defaulted",
              sam.presencePenalty == 0 && sam.minP == 0 && sam.reasoningEffort == "none")
    } else {
        check("legacy sampling without presencePenalty/minP decodes defaulted", false, "threw")
    }
    let bonsaiRow = CatalogModel.catalog.first { $0.id == B }!
    check("Bonsai card: min_p 0.05, presence 0 in thinking mode",
          bonsaiRow.cardProfile().sampling.minP == 0.05
            && bonsaiRow.cardProfile().sampling.presencePenalty == 0)
    m.config.run.modelID = A
    m.applyCardOffSampling()
    check("card-off applies presence 1.5 and min_p 0",
          m.config.sampling.presencePenalty == 1.5 && m.config.sampling.minP == 0
            && m.config.sampling.temperature == 0.7)
    check("parseContext reads the field spellings",
          AppModel.parseContext("100K") == 102_400 && AppModel.parseContext("131072") == 131_072
            && AppModel.parseContext("auto") == nil)

    var sam = SamplingDefaults()
    sam.seed = 12_345_678_901
    let base = ClientConfigContext(client: .opencode, modelID: "someone/Model:x", label: "Model X",
                                   port: 8095, contextTokens: 65_536,
                                   inputModalities: ["text", "image", "pdf"], sampling: sam)
    if let data = ClientConfigs.text(for: base).data(using: .utf8),
       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let provider = (root["providers"] as? [String: Any])?["splashgui"] as? [String: Any],
       let models = provider["models"] as? [String: Any],
       let model = models["someone/Model:x"] as? [String: Any] {
        let body = model["body"] as? [String: Any]
        check("OpenCode: sampling in the model body",
              (body?["temperature"] as? Double) == 1.0 && (body?["top_k"] as? Int) == 20
                && (body?["presence_penalty"] as? Double) == 0 && (body?["min_p"] as? Double) == 0)
        check("OpenCode: seed passes through body", body?["seed"] != nil)
        let limit = model["limit"] as? [String: Any]
        check("OpenCode: limit math at 64K — out 16384, in 49152",
              (limit?["context"] as? Int) == 65_536 && (limit?["output"] as? Int) == 16_384
                && (limit?["input"] as? Int) == 49_152)
        check("OpenCode: no root model/small_model or agent overrides",
              root["model"] == nil && root["small_model"] == nil
                && root["agent"] == nil && root["agents"] == nil)
        let variants = model["variants"] as? [[String: Any]]
        let variantIDs = variants?.compactMap { $0["id"] as? String }
        let highBody = variants?.first { ($0["id"] as? String) == "high" }?["body"] as? [String: Any]
        check("OpenCode: one variant per effort, reasoning_effort in the body",
              variantIDs == CatalogModel.allEfforts
                && (highBody?["reasoning_effort"] as? String) == "high")
        let reasoning = (model["capabilities"] as? [String: Any])?["reasoning"] as? [String: Any]
        check("OpenCode: reasoning capability advertises the efforts",
              (reasoning?["supported"] as? Bool) == true && (reasoning?["toggle"] as? Bool) == true
                && (reasoning?["effort"] as? [String])?.contains("high") == true)
        let settings = provider["settings"] as? [String: Any]
        let compatibility = model["compatibility"] as? [String: Any]
        check("OpenCode: V2 package + baseURL, reasoning_content and max_tokens compatibility",
              (provider["package"] as? String) == "@opencode/ai/providers/openai-compatible"
                && (settings?["baseURL"] as? String) == "http://127.0.0.1:8095/v1"
                && (compatibility?["reasoningField"] as? String) == "reasoning_content"
                && (compatibility?["maxTokensField"] as? String) == "max_tokens")
    } else {
        check("OpenCode: sampling in the model body", false, "config did not parse")
    }
    let zctx = ClientConfigContext(client: .zed, modelID: base.modelID, label: base.label,
                                   port: base.port, contextTokens: base.contextTokens,
                                   inputModalities: base.inputModalities, sampling: base.sampling)
    let ztext = ClientConfigs.text(for: zctx)
    check("Zed: openai_compatible + api_url + temperature only",
          ztext.contains("openai_compatible") && ztext.contains("api_url")
            && ztext.contains("model_parameters") && !ztext.contains("top_k")
            && ztext.contains("interleaved_reasoning"))
    let cctx = ClientConfigContext(client: .claudeCode, modelID: base.modelID, label: base.label,
                                   port: base.port, contextTokens: base.contextTokens,
                                   inputModalities: base.inputModalities, sampling: base.sampling)
    let ctext = ClientConfigs.text(for: cctx)
    check("Claude Code: env block, bare base URL (no /v1), no sampling",
          ctext.contains("ANTHROPIC_BASE_URL") && ctext.contains("http://127.0.0.1:8095\"")
            && !ctext.contains("/v1") && !ctext.contains("temperature"))
    let xctx = ClientConfigContext(client: .codex, modelID: base.modelID, label: base.label,
                                   port: base.port, contextTokens: base.contextTokens,
                                   inputModalities: base.inputModalities, sampling: base.sampling)
    let xtext = ClientConfigs.text(for: xctx)
    check("Codex: TOML provider, responses wire, 90% compact limit",
          xtext.contains("wire_api = \"responses\"") && xtext.contains("env_key = \"SPLASH_API_KEY\"")
            && xtext.contains("model_auto_compact_token_limit = 58982")
            && xtext.contains("model_provider = \"splash\""))

    // M: engine source — the mode field's tolerant decode and the latest-release resolver.
    // Synthetic JSON, not the live fixture: the app now WRITES engineMode, so the on-disk
    // config always has the key and cannot prove the absent-key default.
    let noMode = #"{"engineURLOverride":"keep-me","sampling":{"temperature":0.3}}"#
    if let nm = noMode.data(using: .utf8),
       let ncfg = try? JSONDecoder().decode(AppConfig.self, from: nm) {
        check("engineMode absent decodes pinned without losing the config",
              ncfg.engineMode == .pinned && ncfg.sampling.temperature == 0.3
                && ncfg.engineURLOverride == "keep-me")
    } else {
        check("engineMode absent decodes pinned without losing the config", false, "decoder threw")
    }
    let oddMode = #"{"engineMode":"sideways","sampling":{"temperature":0.3}}"#
    if let od = oddMode.data(using: .utf8),
       let om = try? JSONDecoder().decode(AppConfig.self, from: od) {
        check("unknown engineMode falls back to pinned without losing the config",
              om.engineMode == .pinned && om.sampling.temperature == 0.3)
    } else {
        check("unknown engineMode falls back to pinned without losing the config", false, "decoder threw")
    }
    var mcfg = AppConfig()
    mcfg.engineMode = .latest
    if let md = try? JSONEncoder().encode(mcfg),
       let mback = try? JSONDecoder().decode(AppConfig.self, from: md) {
        check("engineMode round-trips", mback.engineMode == .latest)
    } else {
        check("engineMode round-trips", false, "encode/decode threw")
    }
    // The resolver's pure half, fed the real 1.5.0 release fixture. A latest that equals the
    // compiled-in pin must produce the identical URL so EngineInstaller reuses its directory
    // instead of keying a hash-named twin off the URL.
    let v150 = "1ddc28bf7bfda8833859a913d7072e2aac9072addb9eb5664f3bf1a83a8d6ee2"
    let assets150 = ["splash-1.5.0-arm64-macos26.tar.gz", "splash-1.5.0-arm64-macos26.tar.gz.sha256",
                     "Splash-1.5.0.dmg", "SHA256SUMS", "appcast.xml"]
    if let lp = EngineResolver.pin(tagName: "1.5.0", assetNames: assets150, sha256Text: v150 + "\n") {
        check("latest 1.5.0 resolves to the compiled-in pin exactly",
              lp == EngineInstaller.defaultPin, "\(lp.version) \(lp.url)")
        check("latest-equals-pinned reuses the pinned install dir",
              EngineInstaller.dirName(for: lp) == EngineInstaller.dirName(for: EngineInstaller.defaultPin))
    } else {
        check("latest 1.5.0 resolves to the compiled-in pin exactly", false, "pin() returned nil")
        check("latest-equals-pinned reuses the pinned install dir", false)
    }
    if let vp = EngineResolver.pin(tagName: "v1.6.1", assetNames: ["splash-1.6.1-arm64-macos26.tar.gz",
                                                                   "splash-1.6.1-arm64-macos26.tar.gz.sha256"],
                                   sha256Text: String(repeating: "A", count: 64)) {
        check("v-prefixed tag: version stripped, download URL keeps the tag",
              vp.version == "1.6.1" && vp.url == "https://github.com/incoai/splash/releases/download/v1.6.1/splash-1.6.1-arm64-macos26.tar.gz"
                && vp.sha256 == String(repeating: "a", count: 64), "\(vp.version) \(vp.url)")
    } else {
        check("v-prefixed tag: version stripped, download URL keeps the tag", false, "pin() returned nil")
    }
    check("release without the .sha256 asset resolves to nil",
          EngineResolver.pin(tagName: "1.6.0", assetNames: ["splash-1.6.0-arm64-macos26.tar.gz"],
                             sha256Text: v150) == nil)
    check("release with a malformed checksum resolves to nil",
          EngineResolver.pin(tagName: "1.6.0", assetNames: assets150.map { $0.replacingOccurrences(of: "1.5.0", with: "1.6.0") },
                             sha256Text: "not-hex") == nil)
    check("release with a renamed payload resolves to nil",
          EngineResolver.pin(tagName: "1.6.0", assetNames: ["splash-1.6.0-x64-macos15.tar.gz",
                                                            "splash-1.6.0-x64-macos15.tar.gz.sha256"],
                             sha256Text: v150) == nil)
    var ccfg = AppConfig()
    ccfg.engineMode = .custom
    ccfg.engineVersionOverride = "1.4.1"
    ccfg.engineURLOverride = "https://github.com/incoai/splash/releases/download/1.4.1/splash-1.4.1-arm64-macos26.tar.gz"
    ccfg.engineSHA256Override = String(repeating: "b", count: 64)
    check("custom mode with all three fields yields the override pin",
          ccfg.enginePinOverride()?.version == "1.4.1")
    ccfg.engineSHA256Override = ""
    check("custom mode with a blank SHA falls back to no override", ccfg.enginePinOverride() == nil)

    // The mode table start() installs by: the custom pin applies only in custom mode, pinned
    // mode ignores the override fields, and latest falls back to the installed engine, never
    // downward to the compiled pin.
    let stale = EnginePin(version: "1.4.1", sha256: String(repeating: "b", count: 64),
                          url: "https://github.com/incoai/splash/releases/download/1.4.1/splash-1.4.1-arm64-macos26.tar.gz")
    let pinnedPlan = AppModel.enginePlan(mode: .pinned, customOverride: stale, installed: true,
                                         checkUpdate: true, latest: nil)
    check("pinned mode ignores complete custom fields",
          pinnedPlan.override == nil && pinnedPlan.ensure == true, "\(pinnedPlan)")
    let customPlan = AppModel.enginePlan(mode: .custom, customOverride: stale, installed: true,
                                         checkUpdate: false, latest: nil)
    check("custom mode installs the custom pin regardless of the update toggle",
          customPlan.ensure == true && customPlan.override == stale)
    let partialPlan = AppModel.enginePlan(mode: .custom, customOverride: nil, installed: true,
                                          checkUpdate: false, latest: nil)
    check("custom mode with partial fields keeps pinned behavior",
          partialPlan.ensure == false && partialPlan.override == nil)
    let latestHit = AppModel.enginePlan(mode: .latest, customOverride: nil, installed: true,
                                        checkUpdate: false, latest: stale)
    check("latest mode installs the resolver answer",
          latestHit.ensure == true && latestHit.override == stale)
    let latestKeep = AppModel.enginePlan(mode: .latest, customOverride: nil, installed: true,
                                         checkUpdate: false, latest: nil)
    check("latest mode offline keeps the installed engine",
          latestKeep.ensure == false && latestKeep.override == nil)
    let latestBootstrap = AppModel.enginePlan(mode: .latest, customOverride: nil, installed: false,
                                              checkUpdate: false, latest: nil)
    check("latest mode offline with nothing installed installs the compiled pin",
          latestBootstrap.ensure == true && latestBootstrap.override == nil)

    // N: the catalog must track the installed engine's suggested list (the sync guard for the
    // Splash-defaults swap). Skips with a PASS when no engine is installed on the test machine.
    let tsv = EngineInstaller.currentLink.appendingPathComponent("install/suggested-models.tsv")
    if let tsvText = try? String(contentsOf: tsv, encoding: .utf8) {
        let ids = tsvText.split(separator: "\n").compactMap { line -> String? in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
            return s.split(separator: "\t").first.map(String.init)
        }
        let cat = CatalogModel.catalog.map(\.id).filter { $0 != "custom" }
        check("catalog matches the installed engine's suggested list",
              cat == ids, "catalog \(cat.count) vs tsv \(ids.count)"
                + (cat == ids ? "" : " diff: \(Set(cat).symmetricDifference(ids).sorted())"))
        let mem = tsvText.split(separator: "\n").compactMap { line -> (String, Int)? in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
            let cols = s.split(separator: "\t").map(String.init)
            guard cols.count >= 3, let gb = Int(cols[2]) else { return nil }
            return (cols[0], gb)
        }
        let tsvMemory = Dictionary(mem.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        let memoryDrift = CatalogModel.catalog.filter { $0.id != "custom" }.compactMap { entry -> String? in
            guard let gb = entry.memoryGB else { return "\(entry.id): catalog row lacks MEMORY" }
            return tsvMemory[entry.id] == gb ? nil : "\(entry.id): tsv \(tsvMemory[entry.id] ?? -1) vs catalog \(gb)"
        }
        check("catalog MEMORY figures match the engine's suggested list",
              memoryDrift.isEmpty, memoryDrift.joined(separator: "; "))
    } else {
        check("catalog matches the installed engine's suggested list", true, "no engine installed, skipped")
    }

    // Auto sizing constants are 27B-arch-only: other archs return nil so the engine sizes itself.
    // The synthetic weight is small so nil can only come from the arch gate, not the budget.
    check("Auto sizing skips non-27B arch rows",
          MachineInfo.autoProfile(modelID: "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0",
                                  languageOnly: false, weightsBytes: 1_000_000_000) == nil)
    check("Auto sizing still covers the 27B arch",
          MachineInfo.autoProfile(modelID: A, languageOnly: false, weightsBytes: 10_000_000_000) != nil)

    exit(failures == 0 ? 0 : 1)
}

MainActor.assumeIsolated { runTests() }
