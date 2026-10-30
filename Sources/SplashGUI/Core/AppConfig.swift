import Foundation

struct RunConfig: Codable, Equatable {
    var modelID: String = "unsloth/Qwen3.8-27B-GGUF:UD-IQ3_XXS"
    var port: Int = 8095
    // Auto sizes context, memory and KV from the Metal ceiling and the model's weights, and
    // leaves the SSD cache to the engine. Off restores the typed values below.
    var auto: Bool = true
    var maxContext: String = "auto"
    var maxMemory: String = "auto"
    var kvFormat: String = "auto"
    var maxCacheDisk: String = "10G"
    var languageOnly: Bool = false
    var decodeShare: Double = 0.5
    var showWebUI: Bool = true
    var defaultReasoningEffort: String? = nil
    // How long the engine keeps its memory wired without a request. Its own default is 10m:
    // the first request after an idle minute pays a weight restore and a slower first prefill,
    // which on a 48 GB Mac is a poor trade for the memory it gives back.
    var idleRelease: String = "60m"
    // Keep the SSD KV/state tier across restarts, so a project you come back to restores its
    // prefix instead of prefilling it again.
    var persistentCache: Bool = true
    var schemaVersion: Int? = 6

    // The memberwise initializer goes away with any custom initializer, and the defaults
    // below are what a missing key falls back to.
    init() {}

    // Explicit decoder: a config.json written by an older build lacks the fields added since,
    // and the synthesized one throws on a missing key, which would drop the whole config —
    // per-model profiles with it — back to factory defaults.
    enum CodingKeys: String, CodingKey {
        case modelID, port, auto, maxContext, maxMemory, kvFormat, maxCacheDisk
        case languageOnly, decodeShare, showWebUI, defaultReasoningEffort
        case idleRelease, persistentCache, schemaVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RunConfig()
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID) ?? d.modelID
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? d.auto
        maxContext = try c.decodeIfPresent(String.self, forKey: .maxContext) ?? d.maxContext
        maxMemory = try c.decodeIfPresent(String.self, forKey: .maxMemory) ?? d.maxMemory
        kvFormat = try c.decodeIfPresent(String.self, forKey: .kvFormat) ?? d.kvFormat
        maxCacheDisk = try c.decodeIfPresent(String.self, forKey: .maxCacheDisk) ?? d.maxCacheDisk
        languageOnly = try c.decodeIfPresent(Bool.self, forKey: .languageOnly) ?? d.languageOnly
        decodeShare = try c.decodeIfPresent(Double.self, forKey: .decodeShare) ?? d.decodeShare
        showWebUI = try c.decodeIfPresent(Bool.self, forKey: .showWebUI) ?? d.showWebUI
        defaultReasoningEffort = try c.decodeIfPresent(String.self, forKey: .defaultReasoningEffort)
            ?? d.defaultReasoningEffort
        idleRelease = try c.decodeIfPresent(String.self, forKey: .idleRelease) ?? d.idleRelease
        persistentCache = try c.decodeIfPresent(Bool.self, forKey: .persistentCache) ?? d.persistentCache
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? d.schemaVersion
    }

    private static func isAuto(_ value: String) -> Bool {
        let v = value.lowercased()
        return v == "auto" || v.isEmpty
    }

    // Resolves what actually launches. With Auto on, the four covered fields come from the
    // profile (or Splash's own sizing when there is none — a custom ID) and the SSD cache is
    // left to the engine; the typed values stay saved untouched. With Auto off, a field that
    // still says "auto" (the pre-switch spelling) falls back to the profile as before, so
    // SplashServer stays policy-free and never sees "auto" for --kv-format.
    func effective(using profile: AutoProfile?) -> RunConfig {
        var out = self
        if auto {
            if let p = profile {
                out.maxContext = String(p.contextTokens)
                out.maxMemory = String(p.maxMemoryBytes)
                out.kvFormat = p.kvFormat
            } else {
                out.maxContext = "auto"
                out.maxMemory = "auto"
                if Self.isAuto(out.kvFormat) { out.kvFormat = "bf16" }
            }
            out.maxCacheDisk = "auto"
            return out
        }
        if let p = profile {
            if Self.isAuto(maxContext) { out.maxContext = String(p.contextTokens) }
            if Self.isAuto(maxMemory) { out.maxMemory = String(p.maxMemoryBytes) }
            if Self.isAuto(kvFormat) { out.kvFormat = p.kvFormat }
        } else if Self.isAuto(kvFormat) {
            out.kvFormat = "bf16"
        }
        return out
    }
}

// The app's shipped starting point: the thinking-mode sampling every model in the catalog's card
// recommends (both cards publish 1.0 / 0.95 / 20 / min_p 0 / presence 0, and the GGUFs carry it
// as general.sampling.*). These values reach Splash through the client configs the Provider
// tab writes — the app itself sends no requests.
struct SamplingDefaults: Codable, Equatable {
    var temperature: Double = 1.0
    var topP: Double = 0.95
    var topK: Int = 20
    // Engine 1.5.0 accepts and applies both (server/frontend.py SAMPLING_NUMBERS); only
    // logit_bias is refused. The Qwen card asks presence 1.5 with thinking off; the Bonsai
    // card asks min_p 0.05 in thinking mode.
    var presencePenalty: Double = 0
    var minP: Double = 0
    var maxTokens: Int? = nil
    var seed: UInt64? = nil
    var reasoningEffort: String? = nil

    init() {}

    // Tolerant decoder (the Codable trap): configs saved before presencePenalty/minP existed
    // must decode with them defaulted, not throw.
    enum CodingKeys: String, CodingKey {
        case temperature, topP, topK, presencePenalty, minP, maxTokens, seed, reasoningEffort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SamplingDefaults()
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? d.temperature
        topP = try c.decodeIfPresent(Double.self, forKey: .topP) ?? d.topP
        topK = try c.decodeIfPresent(Int.self, forKey: .topK) ?? d.topK
        presencePenalty = try c.decodeIfPresent(Double.self, forKey: .presencePenalty) ?? d.presencePenalty
        minP = try c.decodeIfPresent(Double.self, forKey: .minP) ?? d.minP
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed)
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
    }
}

// What one model keeps its settings as, so switching models in the picker swaps each model's
// own sampling and serve fields back in. `reasoningEffort` lives in `sampling`; applying a
// profile also mirrors it into `run.defaultReasoningEffort`, which is the serve flag.
struct ModelProfile: Codable, Equatable {
    var sampling = SamplingDefaults()
    var auto: Bool = true
    var maxContext: String = "auto"
    var maxMemory: String = "auto"
    var kvFormat: String = "auto"
    var languageOnly = false

    // Tolerant decoder (the Codable trap): profiles saved before `auto` existed must decode
    // with it at its default, not throw — a nested failure drops the whole config to factory.
    init() {}

    // The memberwise initializer the custom initializers take away.
    init(sampling: SamplingDefaults, auto: Bool, maxContext: String,
         maxMemory: String, kvFormat: String, languageOnly: Bool) {
        self.sampling = sampling
        self.auto = auto
        self.maxContext = maxContext
        self.maxMemory = maxMemory
        self.kvFormat = kvFormat
        self.languageOnly = languageOnly
    }

    enum CodingKeys: String, CodingKey {
        case sampling, auto, maxContext, maxMemory, kvFormat, languageOnly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ModelProfile()
        sampling = try c.decodeIfPresent(SamplingDefaults.self, forKey: .sampling) ?? d.sampling
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? d.auto
        maxContext = try c.decodeIfPresent(String.self, forKey: .maxContext) ?? d.maxContext
        maxMemory = try c.decodeIfPresent(String.self, forKey: .maxMemory) ?? d.maxMemory
        kvFormat = try c.decodeIfPresent(String.self, forKey: .kvFormat) ?? d.kvFormat
        languageOnly = try c.decodeIfPresent(Bool.self, forKey: .languageOnly) ?? d.languageOnly
    }

    // Snapshot of the live settings, for archiving the model you are switching away from.
    static func snapshot(of config: AppConfig) -> ModelProfile {
        ModelProfile(sampling: config.sampling, auto: config.run.auto,
                     maxContext: config.run.maxContext,
                     maxMemory: config.run.maxMemory, kvFormat: config.run.kvFormat,
                     languageOnly: config.run.languageOnly)
    }
}

// What Splash actually granted a custom model (no app-side profile): the window and memory
// budget from /status, shown as Auto's values on the next launch without waiting for a serve.
struct GrantedSettings: Codable, Equatable {
    var contextTokens: Int
    var memoryBytes: Int
}

struct AppConfig: Codable, Equatable {
    var run = RunConfig()
    var sampling = SamplingDefaults()
    // Archive of per-model settings, keyed by the full model ID including its `:variant`
    // (that suffix is part of Splash's selection-link name, so never strip it). The live
    // editing state stays in `sampling`/`run`; an entry is written when you switch away from
    // that model, and a model with no entry gets its task card instead.
    var modelProfiles: [String: ModelProfile] = [:]
    // Last Splash-granted context/memory for custom IDs, keyed by model ID (see GrantedSettings).
    var grantedAuto: [String: GrantedSettings] = [:]
    var engineVersionOverride: String = ""
    var engineURLOverride: String = ""
    var engineSHA256Override: String = ""
    var checkEngineUpdate: Bool = true
    // Which build to run: the compiled-in pin, the newest release, or a hand-set pin. The
    // override fields above are the custom pin; they decode in every mode so a switch back
    // to .custom restores whatever was typed before.
    var engineMode: EngineMode = .pinned
    // Launch = start: serves the saved model on the saved port without a click. Skips when
    // something already owns the port (the adopt path wins), and in the headless harness
    // (SPLASHGUI_TEST=1) so tests never spawn a server.
    var startOnLaunch: Bool = false

    init() {}

    // Explicit decoder so an older config.json (written before a field existed) still loads with
    // that field at its default. The synthesized one throws on a missing key, which would drop
    // the whole config back to factory defaults and lose the user's settings.
    enum CodingKeys: String, CodingKey {
        case run, sampling, modelProfiles, grantedAuto
        case engineVersionOverride, engineURLOverride, engineSHA256Override, checkEngineUpdate
        case engineMode
        case startOnLaunch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        run = try c.decodeIfPresent(RunConfig.self, forKey: .run) ?? RunConfig()
        sampling = try c.decodeIfPresent(SamplingDefaults.self, forKey: .sampling) ?? SamplingDefaults()
        modelProfiles = try c.decodeIfPresent([String: ModelProfile].self, forKey: .modelProfiles) ?? [:]
        grantedAuto = try c.decodeIfPresent([String: GrantedSettings].self, forKey: .grantedAuto) ?? [:]
        engineVersionOverride = try c.decodeIfPresent(String.self, forKey: .engineVersionOverride) ?? ""
        engineURLOverride = try c.decodeIfPresent(String.self, forKey: .engineURLOverride) ?? ""
        engineSHA256Override = try c.decodeIfPresent(String.self, forKey: .engineSHA256Override) ?? ""
        checkEngineUpdate = try c.decodeIfPresent(Bool.self, forKey: .checkEngineUpdate) ?? true
        // Decoded as a string and mapped, never as the enum directly: a value written by a
        // future build must fall back to .pinned, not throw and drop the whole config to
        // factory defaults (the Codable trap).
        engineMode = EngineMode(rawValue: try c.decodeIfPresent(String.self, forKey: .engineMode) ?? "pinned") ?? .pinned
        startOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .startOnLaunch) ?? false
    }

    func enginePinOverride() -> EnginePin? {
        guard !engineVersionOverride.isEmpty, !engineURLOverride.isEmpty,
              !engineSHA256Override.isEmpty else { return nil }
        return EnginePin(version: engineVersionOverride, sha256: engineSHA256Override,
                         url: engineURLOverride)
    }

    // Writes a model's saved profile into the live fields. reasoningEffort is also the serve
    // flag, so it lands in both places, exactly as the reasoning-effort control writes them.
    mutating func apply(profile: ModelProfile) {
        sampling = profile.sampling
        run.auto = profile.auto
        run.maxContext = profile.maxContext
        run.maxMemory = profile.maxMemory
        run.kvFormat = profile.kvFormat
        run.languageOnly = profile.languageOnly
        run.defaultReasoningEffort = profile.sampling.reasoningEffort
    }
}

struct CatalogModel: Identifiable, Equatable {
    static let windowTokens = 262_144  // Qwen3.8 native window (no YaRN); Splash's own ceiling

    let id: String
    let label: String
    let note: String
    // Whole assembly (target + draft + vision), used to size the auto-profile before a download.
    var approxBytes: Int? = nil
    // The tsv's MEMORY column: the smallest Mac RAM the vendor says the variant is meant for.
    // The picker's too-large warning gates on this, so note and warning agree by construction.
    var memoryGB: Int? = nil
    // Immutable HF commit the pull is pinned to, so a catalog entry always names one exact set of
    // bytes; nil = the repository's default branch (unpinned). Passed as serve --revision.
    var revision: String? = nil
    // The GGUF the engine links into assembly target/, and the sha256 Hugging Face publishes for
    // it (the LFS oid). The engine records the same digest in its model.json, which is what the
    // pre-flight check compares against — no re-hashing the file.
    var targetFile: String? = nil
    var sha256: String? = nil
    // Sampling the model's own card recommends, so defaults come from the card instead of being
    // guessed from the model name. Read from the HF cards 2026-10-29 (unsloth/Qwen3.8-27B-GGUF
    // and prism-ml/Ternary-Bonsai-2-27B-gguf Best Practices): both publish the thinking-mode set
    // below; the GGUFs carry temp/top_p/top_k as general.sampling.*. Engine 1.5.0 accepts every
    // card value — presence penalty and min_p are applied; only logit_bias is refused.
    var cardTemperature: Double = 1.0
    var cardTopP: Double = 0.95
    var cardTopK: Int = 20
    var cardPresencePenalty: Double = 0
    var cardMinP: Double = 0
    // The same card's non-thinking set, relevant when reasoning effort is `none`. Offered as a
    // link, never applied automatically — effort is a serve-wide flag while sampling is per-request.
    var cardOffTemperature: Double = 0.7
    var cardOffTopP: Double = 0.80
    var cardOffTopK: Int = 20
    var cardOffPresencePenalty: Double = 1.5
    var cardOffMinP: Double = 0
    // Reasoning levels this model accepts; nil = all of them. Bonsai's card: defaults to xhigh,
    // medium for shorter answers, and `low` is NOT supported (it behaves like xhigh).
    var supportedEfforts: [String]? = nil
    // The card's own words about reasoning depth, shown in the effort tooltip.
    var cardEffortNote: String = "The card recommends thinking mode; leave the effort at model default unless answers run long."
    // Auto's KV-per-token and window constants are measured on this arch only; other rows get
    // nil from autoProfile and the engine sizes itself.
    var qwen27BArch: Bool = false

    // Every level Splash's API accepts. A model's supportedEfforts filters this list.
    static let allEfforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    // The card as a starting profile: the model's card sampling, model-default reasoning effort,
    // and auto serve fields.
    func cardProfile() -> ModelProfile {
        var p = ModelProfile()
        p.sampling.temperature = cardTemperature
        p.sampling.topP = cardTopP
        p.sampling.topK = cardTopK
        p.sampling.presencePenalty = cardPresencePenalty
        p.sampling.minP = cardMinP
        return p
    }

    var owner: String { id.split(separator: "/").first.map(String.init) ?? "" }
    // Includes the :variant suffix, which is how Splash names its selection link.
    var repo: String {
        let parts = id.split(separator: "/")
        return parts.count > 1 ? String(parts[1]) : id
    }
    // The bare repository, which is what Hugging Face names its cache directory by.
    var hfRepo: String { String(repo.split(separator: ":").first ?? Substring(repo)) }

    var downloadURL: String? {
        guard let revision, let targetFile else { return nil }
        return "https://huggingface.co/\(owner)/\(hfRepo)/resolve/\(revision)/\(targetFile)"
    }

    var onDisk: Bool { MachineInfo.weightsDir(for: id) != nil }

    // The one disk-size-or-catalog-estimate rule: the live launch path, the headless probe, and
    // the auto-profile all read this so they cannot drift apart.
    var weightsBytes: Int? { MachineInfo.cachedModelSize(id) ?? approxBytes }

    var fitsThisMac: Bool {
        guard let memoryGB else { return true }
        return MachineInfo.physicalRAM >= memoryGB * 1_073_741_824
    }

    // The catalog IS Splash's own suggested list (install/suggested-models.tsv as shipped by
    // engine 1.5.0): same order (best first), same facts. The note line carries the tsv's
    // MEMORY / SIZE / ABOUT columns verbatim in meaning — SIZE is the vendor's download figure
    // including the vision projector and DFlash2 draft (the auto-profile's weight basis), and
    // MEMORY feeds fitsThisMac directly, so note and the too-large warning agree by
    // construction. Re-sync on every engine pin bump; the profile-test harness diffs IDs,
    // order and MEMORY against the installed engine's tsv. Hand-verified revision pins and
    // digests are kept only for entries actually measured on hardware (IQ3_XXS, Bonsai);
    // everything else is unpinned, and the free-form Custom slot (see README "Confirmed
    // models") covers the rest.
    static let catalog: [CatalogModel] = [
        CatalogModel(id: "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M", label: "Qwen3.6-35B-A3B Q4_K_M",
                     note: "for 36 GB Macs · 24 GB download · Fast all-rounder",
                     approxBytes: 24_000_000_000, memoryGB: 36),
        CatalogModel(id: "mlx-community/Qwen3.6-35B-A3B-4bit", label: "Qwen3.6-35B-A3B MLX 4-bit",
                     note: "for 36 GB Macs · 21 GB download · Fast all-rounder",
                     approxBytes: 21_000_000_000, memoryGB: 36),
        CatalogModel(id: "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q2_K_XL", label: "Qwen3.6-35B-A3B Q2_K_XL",
                     note: "for 24 GB Macs · 14 GB download · Fast all-rounder",
                     approxBytes: 14_000_000_000, memoryGB: 24),
        CatalogModel(id: "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M", label: "Qwen3.8-27B Q4_K_M",
                     note: "for 36 GB Macs · 21 GB download · Strongest at this size, slower",
                     approxBytes: 21_000_000_000, memoryGB: 36, qwen27BArch: true),
        CatalogModel(id: "mlx-community/Qwen3.8-27B-4bit", label: "Qwen3.8-27B MLX 4-bit",
                     note: "for 36 GB Macs · 20 GB download · Strongest at this size, slower",
                     approxBytes: 20_000_000_000, memoryGB: 36, qwen27BArch: true),
        CatalogModel(id: "unsloth/Qwen3.8-27B-GGUF:UD-IQ3_XXS", label: "Qwen3.8-27B IQ3_XXS",
                     note: "for 24 GB Macs · 16 GB download · Strongest at this size, slower",
                     approxBytes: 16_000_000_000, memoryGB: 24, revision: "4ca720788d1e01f1bff70c033e0d0028fd02e502",
                     targetFile: "Qwen3.8-27B-UD-IQ3_XXS.gguf",
                     sha256: "c0b7c3038681ed2e3040456c1dd45f9858b6c2290bed172c70388a94874f3eee",
                     qwen27BArch: true),
        CatalogModel(id: "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0", label: "Qwen3.8-Flash-Next Q2_0",
                     note: "for 64 GB Macs · 69 GB download · Most capable",
                     approxBytes: 69_000_000_000, memoryGB: 64),
        CatalogModel(id: "unsloth/flint-GGUF:UD-Q4_K_XL", label: "Flint Q4_K_XL",
                     note: "for 48 GB Macs · 26 GB download · Text only",
                     approxBytes: 26_000_000_000, memoryGB: 48),
        CatalogModel(id: "unsloth/Ornith-1.5-122B-GGUF:UD-Q4_K_XL", label: "Ornith-1.5-122B Q4_K_XL",
                     note: "for 128 GB Macs · 82 GB download · Largest model",
                     approxBytes: 82_000_000_000, memoryGB: 128),
        CatalogModel(id: "ornith-ai/Ornith-1.5-122B-MLX-4bit", label: "Ornith-1.5-122B MLX 4-bit",
                     note: "for 128 GB Macs · 71 GB download · Largest model",
                     approxBytes: 71_000_000_000, memoryGB: 128),
        CatalogModel(id: "prism-ml/Ternary-Bonsai-2-27B-gguf:PQ2_0", label: "Bonsai 2 27B (PQ2_0)",
                     note: "for 24 GB Macs · 12 GB download · Smallest download",
                     approxBytes: 12_000_000_000, memoryGB: 24, revision: "b072e1d3b35a0a630cece372c2127528e0994386",
                     targetFile: "Ternary-Bonsai-2-27B-PQ2_0.gguf",
                     sha256: "3907dc1658db1f78a9826bf8d5bcb8dc65db0d466388937af57f2294fae62ec1",
                     cardMinP: 0.05,
                     supportedEfforts: ["none", "minimal", "medium", "high", "xhigh", "max"],
                     cardEffortNote: "Card: thinking by default at xhigh effort; medium for shorter answers; `low` is NOT supported (it behaves like xhigh). The card also recommends min_p 0.05 in thinking mode, which the sampling fields carry."),
        CatalogModel(id: "custom", label: "Custom…", note: "owner/repo[:variant]")
    ]
}

enum AppPaths {
    // ~/Library/Application Support/SplashGUI. Builds before 1.0 were named Splashpad; their
    // folder (config, engine) is moved here on the first launch that finds no SplashGUI
    // folder. The engine's `current` symlink is relative, so the move keeps it valid.
    static let dataDir: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("SplashGUI", isDirectory: true)
        let old = base.appendingPathComponent("Splashpad", isDirectory: true)
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

final class ConfigStore {
    static let shared = ConfigStore()

    private let dir: URL
    private let fileURL: URL

    init() {
        dir = AppPaths.dataDir
        fileURL = dir.appendingPathComponent("config.json")
    }

    func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL) else {
            return AppConfig()
        }
        if let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            var cfg = decoded
            if (cfg.run.schemaVersion ?? 1) < 2 {
                if cfg.run.kvFormat == "int8" { cfg.run.kvFormat = "bf16" }
                cfg.run.schemaVersion = 2
            }
            if (cfg.run.schemaVersion ?? 1) < 3 {
                if cfg.run.kvFormat == "bf16" { cfg.run.kvFormat = "auto" }
                cfg.run.schemaVersion = 3
            }
            if (cfg.run.schemaVersion ?? 1) < 4 {
                // Give the model already selected a profile entry, so its shipped-or-tuned
                // settings survive the first switch away from it and are editable on disk.
                let id = cfg.run.modelID
                if !id.isEmpty && cfg.modelProfiles[id] == nil {
                    cfg.modelProfiles[id] = ModelProfile.snapshot(of: cfg)
                }
                cfg.run.schemaVersion = 4
            }
            if (cfg.run.schemaVersion ?? 1) < 5 {
                // 1.0 shipped with the SSD tier off. A 64K context costs 2.0 GiB of KV pages
                // there (33,280 bytes a token) plus a 152 MiB state, so 10 GB holds about
                // five of them, and the tier only pays for itself if it survives a restart.
                if cfg.run.maxCacheDisk == "0" { cfg.run.maxCacheDisk = "10G" }
                cfg.run.schemaVersion = 5
            }
            if (cfg.run.schemaVersion ?? 1) < 6 {
                // The Auto switch: on only when every field it covers was still "auto".
                // Otherwise off, with the existing values as the typed ones.
                func isAuto(_ v: String) -> Bool { v.lowercased() == "auto" || v.isEmpty }
                let allAuto = isAuto(cfg.run.maxContext) && isAuto(cfg.run.maxMemory)
                    && isAuto(cfg.run.kvFormat) && isAuto(cfg.run.maxCacheDisk)
                cfg.run.auto = allAuto
                if !allAuto && isAuto(cfg.run.kvFormat) {
                    // The KV picker no longer has an Auto segment — resolve what Auto would
                    // have picked once, so the typed set is complete.
                    let id = cfg.run.modelID
                    let weights = CatalogModel.catalog.first { $0.id == id }?.weightsBytes
                        ?? MachineInfo.cachedModelSize(id)
                    let p = MachineInfo.autoProfile(modelID: id, languageOnly: cfg.run.languageOnly,
                                                    weightsBytes: weights)
                    cfg.run.kvFormat = p?.kvFormat ?? "bf16"
                }
                cfg.run.schemaVersion = 6
            }
            return cfg
        }
        return AppConfig()
    }

    func save(_ config: AppConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}