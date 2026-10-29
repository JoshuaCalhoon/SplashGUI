import Foundation

// The coding clients the Provider tab writes configs for. The OpenCode shape mirrors the
// engine's own connector (install/clients.py _opencode, engine 1.3.2) plus sampling; the
// Claude Code env set and the Codex TOML mirror _claude and _codex. Zed's shape is from its
// current docs (OpenAI-compatible endpoints + agent.model_parameters).
enum ProviderClient: String, CaseIterable, Identifiable {
    case opencode = "OpenCode"
    case zed = "Zed"
    case claudeCode = "Claude Code"
    case codex = "Codex"

    var id: String { rawValue }

    var tooltip: String {
        "The tool to write a config for. Each one gets the endpoint, the model, its context limit and the sampling below, in that tool's own format."
    }

    // Which sampling fields actually reach this client's requests. OpenCode merges the model's
    // `body` into the request body verbatim (V2; verified live against 2.2.2 with an echo
    // server); Zed carries temperature only (agent.model_parameters); Claude Code and Codex
    // expose no sampling knobs — their requests set what they themselves want.
    func carries(_ field: SamplingField) -> Bool {
        switch self {
        case .opencode: return field != .maxTokens
        case .zed: return field == .temperature
        case .claudeCode, .codex: return false
        }
    }

    var configCaption: String {
        switch self {
        case .opencode: return "opencode.json — add this providers block; your model and agent defaults stay untouched"
        case .zed: return "settings.json for Zed (AI section)"
        case .claudeCode: return "settings.json — the env block for ~/.claude/settings.json"
        case .codex: return "config.toml for ~/.codex/config.toml"
        }
    }

    var saveName: String {
        switch self {
        case .opencode: return "opencode-splash.json"
        case .zed: return "zed-splash-settings.json"
        case .claudeCode: return "claude-code-splash-env.json"
        case .codex: return "codex-splash-config.toml"
        }
    }

    var filePattern: String {
        switch self {
        case .codex: return "toml"
        default: return "json"
        }
    }
}

enum SamplingField {
    case temperature, topP, topK, presencePenalty, minP, maxTokens, seed
}

// Everything the config text is built from, resolved by AppModel (granted window when the
// server runs, configured/Auto values otherwise).
struct ClientConfigContext {
    let client: ProviderClient
    let modelID: String
    let label: String
    let port: Int
    let contextTokens: Int
    let inputModalities: [String]
    let sampling: SamplingDefaults
    // Reasoning levels this model accepts; defaults to every level Splash's API takes.
    var efforts: [String] = CatalogModel.allEfforts
}

enum ClientConfigs {
    // The output allowance OpenCode, Zed and Codex reserve: CLIENT_RESPONSE_TOKENS in the
    // engine connector, or a quarter of the window when that is less.
    static func responseTokens(context: Int) -> Int {
        min(32_768, max(1, context / 4))
    }

    static func text(for ctx: ClientConfigContext) -> String {
        switch ctx.client {
        case .opencode: return opencode(ctx)
        case .zed: return zed(ctx)
        case .claudeCode: return claudeCode(ctx)
        case .codex: return codex(ctx)
        }
    }

    // MARK: - OpenCode

    private static func json(_ obj: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj,
                                                options: [.prettyPrinted, .sortedKeys])) ?? Data()
        // JSONSerialization escapes every "/" as "\/" — valid but ugly in a preview meant to
        // be read and pasted. "\/" is the only sequence it produces this way, safe to undo.
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }

    private static func inputModalities(_ ctx: ClientConfigContext) -> [String] {
        ctx.inputModalities
    }

    // JSONSerialization prints a Double's full binary expansion (0.95 -> 0.94999999999999996).
    // A decimal built from Swift's shortest description round-trips to the value the user
    // typed and reads cleanly in the pasted config.
    private static func decimal(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(value))
    }

    // This snippet only adds the provider. It deliberately does NOT set the root `model` or
    // `small_model` and does NOT define `agents`: those are the user's defaults, and overriding
    // them was making every agent point at Splash. Splash appears as one more entry in
    // /models; its reasoning efforts appear as variants in /variants.
    private static func opencode(_ ctx: ClientConfigContext) -> String {
        let out = responseTokens(context: ctx.contextTokens)
        let modalities = inputModalities(ctx)
        // Sampling rides in the model's `body`, which V2 merges into the request body verbatim.
        // (V1's `options` was the old path; agent-level request fields are not sent in V2.)
        var body: [String: Any] = [
            "temperature": decimal(ctx.sampling.temperature),
            "top_p": decimal(ctx.sampling.topP),
            "top_k": ctx.sampling.topK,
            "presence_penalty": decimal(ctx.sampling.presencePenalty),
            "min_p": decimal(ctx.sampling.minP),
        ]
        if let seed = ctx.sampling.seed { body["seed"] = seed }

        // One variant per effort Splash accepts for this model. Splash reads snake_case
        // `reasoning_effort` from the request body, so the body overlay is the reliable path.
        let variants: [[String: Any]] = ctx.efforts.map { effort in
            ["id": effort, "body": ["reasoning_effort": effort]]
        }
        let reasoningEfforts = ctx.efforts.filter { $0 != "none" }
        let reasoning: [String: Any] = [
            "supported": true,
            "toggle": ctx.efforts.contains("none"),
            "effort": reasoningEfforts,
        ]
        let model: [String: Any] = [
            "name": ctx.label,
            "capabilities": [
                "tools": true,
                "input": modalities,
                "output": ["text"],
                "reasoning": reasoning,
            ],
            // Splash streams thinking in reasoning_content and reads the output cap as
            // max_tokens, so tell the OpenAI-compatible package both.
            "compatibility": [
                "reasoningField": "reasoning_content",
                "maxTokensField": "max_tokens",
            ],
            "limit": ["context": ctx.contextTokens,
                      "input": ctx.contextTokens - out,
                      "output": out],
            "body": body,
            "variants": variants,
        ]
        let root: [String: Any] = [
            "$schema": "https://opencode.ai/config.json",
            "providers": [
                "splashgui": [
                    "name": "SplashGUI",
                    "package": "@opencode/ai/providers/openai-compatible",
                    "settings": [
                        "baseURL": "http://127.0.0.1:\(ctx.port)/v1",
                        "apiKey": "local",
                    ],
                    "models": [ctx.modelID: model],
                ]
            ],
        ]
        return json(root)
    }

    // MARK: - Zed

    private static func zed(_ ctx: ClientConfigContext) -> String {
        let modalities = inputModalities(ctx)
        var model: [String: Any] = [
            "name": ctx.modelID,
            "display_name": ctx.label,
            "max_tokens": ctx.contextTokens,
            "max_output_tokens": responseTokens(context: ctx.contextTokens),
            // Splash streams thinking in a dedicated reasoning_content field and takes the
            // output cap as max_tokens; tool calling works. Images follow the vision toggle.
            "capabilities": [
                "tools": true,
                "images": modalities != ["text"],
                "parallel_tool_calls": false,
                "prompt_cache_key": false,
                "chat_completions": true,
                "interleaved_reasoning": true,
                "max_tokens_parameter": true,
            ],
        ]
        if ctx.sampling.reasoningEffort != "none" {
            // Tells Zed which effort to send when thinking is on; unset = the server default.
            model["reasoning_effort"] = ctx.sampling.reasoningEffort ?? "medium"
        }
        var root: [String: Any] = [
            "language_models": [
                "openai_compatible": [
                    "splash": [
                        "api_url": "http://127.0.0.1:\(ctx.port)/v1",
                        "available_models": [model],
                    ]
                ]
            ]
        ]
        // Zed carries temperature per model (agent.model_parameters); the provider is omitted
        // so the entry matches Zed's provider key for the custom provider regardless of its
        // exact spelling. Keys stay out of settings.json — Zed wants SPLASH_API_KEY in the
        // environment (generated from the provider name), noted in the tab's caption.
        if ctx.sampling.temperature > 0 {
            root["agent"] = ["model_parameters": [["model": ctx.modelID,
                                                   "temperature": ctx.sampling.temperature]]]
        }
        return json(root)
    }

    // MARK: - Claude Code

    private static func claudeCode(_ ctx: ClientConfigContext) -> String {
        // Mirrors the engine connector's _claude environment. ANTHROPIC_BASE_URL takes the
        // bare server URL — Claude Code appends /v1/messages itself. No sampling fields:
        // Claude Code sets its own per request.
        let env: [String: Any] = [
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(ctx.port)",
            "ANTHROPIC_AUTH_TOKEN": "local",
            "ANTHROPIC_MODEL": ctx.modelID,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": ctx.modelID,
            "ANTHROPIC_DEFAULT_SONNET_MODEL": ctx.modelID,
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": ctx.modelID,
            "ANTHROPIC_SMALL_FAST_MODEL": ctx.modelID,
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS": String(ctx.contextTokens),
            "CLAUDE_CODE_AUTO_COMPACT_WINDOW": String(ctx.contextTokens),
        ]
        return json(["env": env])
    }

    // MARK: - Codex

    private static func codex(_ ctx: ClientConfigContext) -> String {
        // Mirrors the engine connector's _codex -c overrides, as the config.toml shape.
        // wire_api = responses: Codex speaks /v1/responses, which Splash serves.
        """
        model = "\(ctx.modelID)"
        model_provider = "splash"
        model_context_window = \(ctx.contextTokens)
        model_auto_compact_token_limit = \(ctx.contextTokens * 9 / 10)
        web_search = "disabled"

        [model_providers.splash]
        name = "Splash"
        base_url = "http://127.0.0.1:\(ctx.port)/v1"
        env_key = "SPLASH_API_KEY"
        wire_api = "responses"
        """
    }
}
