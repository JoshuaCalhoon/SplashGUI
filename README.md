# SplashGUI

A native macOS SwiftUI front-end for the [Splash](https://github.com/incoai/splash)
inference engine. It wraps `splash serve` with a model catalogue, engine install and
auto-configuration, per-model profiles, and live status/metrics — so running a
27B-class local model is one click, not a shell session.

SplashGUI is only the front-end. The engine binary is downloaded separately from the
upstream project at first launch; see [the engine's README](https://github.com/incoai/splash)
for how the engine itself works.

## Features

- **One-click server.** Start/stop the engine from the window toolbar; the app
  launches `splash serve`, watches its logs, and shows live phase (starting, ready,
  exited) in the footer.
- **Engine manager.** First launch downloads the pinned Splash engine build (~71 MB),
  verifies its SHA-256, and installs it atomically. Updates are checked on start and
  can be overridden with a custom version/URL/digest.
- **Model catalogue.** Splash's own suggested-model list (same order the engine's desktop
  app offers), with revision + hash pinning on the entries verified on hardware, plus a
  free-form `owner/repo[:variant]` slot for anything else.
- **Auto-configuration.** Context size, memory cap, and KV format are derived from the
  model's on-disk size and the machine's RAM/Metal headroom; per-model profiles let you
  override and then "Reset to model card".
- **SSD KV-cache tier.** The engine's persistent prefix cache gets a configurable disk
  quota (default 10 GB) and survives server restarts when enabled — repeated prompts
  re-prefill from disk instead of from scratch.
- **Presets.** Multi-turn prompt sequences you can run against the live server with
  streamed output and per-run metrics — a built-in smoke test and A/B harness.
- **Status dashboard.** TTFT, prefill/decode throughput, draft acceptance, cache hit
  rate, KV/GDN-state residency, and a RAM meter, with time-series charts.

The engine runs the model's FFN projections on the Apple Neural Engine when it can
(≈1.3× prefill on a 16-core M5 Pro with Qwen3.8-27B); the app simply leaves that
engine-side behaviour enabled.

## Requirements

- macOS 26.4 or later
- Apple silicon
- Enough RAM for the model you pick — see the catalogue table below

## Install

Download the latest `SplashGUI-<version>.dmg` from
[Releases](https://github.com/JoshuaCalhoon/SplashGUI/releases), open it, and drag
SplashGUI to `/Applications`. The app is signed with a Developer ID certificate and
notarized, so Gatekeeper opens it without any right-click workaround.

On first launch the app downloads the Splash engine into its application-support
directory. Model weights are downloaded from Hugging Face when you start a model.

## The model catalogue

The picker ships Splash's own suggested list — the same models and order the Splash
desktop app offers, and the `splash` CLI completes — so the catalogue follows the engine
rather than a third-party opinion. Download sizes are the engine's own figures and
**include the auto-paired DFlash2 speed draft and vision projector**, the same basis the
app's "too large for this Mac" warning uses.

| Model | Download | Smallest Mac | Notes |
| --- | --- | --- | --- |
| Qwen3.6-35B-A3B Q4_K_M (GGUF) | 24 GB | 36 GB | Fast all-rounder |
| Qwen3.6-35B-A3B MLX 4-bit | 21 GB | 36 GB | Fast all-rounder |
| Qwen3.6-35B-A3B Q2_K_XL (GGUF) | 14 GB | 24 GB | Fast all-rounder |
| Qwen3.8-27B Q4_K_M (GGUF) | 21 GB | 36 GB | Strongest at this size, slower |
| Qwen3.8-27B MLX 4-bit | 20 GB | 36 GB | Strongest at this size, slower |
| Qwen3.8-27B IQ3_XXS (GGUF) | 16 GB | 24 GB | Strongest at this size, slower |
| Qwen3.8-Flash-Next Q2_0 (GGUF) | 69 GB | 64 GB | Most capable |
| Flint Q4_K_XL (GGUF) | 26 GB | 48 GB | Text only |
| Ornith-1.5-122B Q4_K_XL (GGUF) | 82 GB | 128 GB | Largest model |
| Ornith-1.5-122B MLX 4-bit | 71 GB | 128 GB | Largest model |
| Ternary-Bonsai 2 27B PQ2_0 | 12 GB | 24 GB | Smallest download |
| Custom… | — | — | Any `owner/repo[:variant]` |

Entries we have verified on hardware carry an exact Hugging Face revision and file
digest (today: IQ3_XXS and Bonsai PQ2_0), so a re-upload under the same name can't
silently change what your Mac loads; the rest follow the engine's default resolution.

## Confirmed models for the Custom slot

Beyond the catalogue, these have run well under SplashGUI — copy the ID into **Custom…**:

| Model ID | Notes |
| --- | --- |
| `JoshuaCalhoon/Qwen3.8-27B-MLX-4bit-GPTQ` | The maintainer's daily driver; most real-world numbers were logged on this quant |
| `unsloth/Qwen3.8-27B-GGUF:UD-IQ4_XS` | ~19 GB with draft + vision; comfortable on 32 GB Macs |
| `unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL` | Dynamic 4-bit with 6-bit layers; the quality pick of the GGUF family |

Custom entries are unpinned (no revision/hash pre-flight) — you get whatever the Hub
serves today.

## Using the server

While the server is running it exposes an OpenAI-compatible API at
`http://localhost:8095/v1` (port configurable on the Run tab). Any client that speaks
that API — OpenAI's own SDKs, coding agents, chat front-ends — can point at it. For a
quick start without any external tool, the engine also serves a built-in web chat page
in the browser ("Built-in web chat page" toggle, on by default).

## Building from source

Requires the Swift 6.2 toolchain (Xcode 26 or the standalone toolchain).

```sh
swift build
scripts/bundle-app.sh --open      # ad-hoc signed build/SplashGUI.app
```

`scripts/bundle-app.sh --release` produces a signed, notarized `SplashGUI-<version>.dmg`.
Set `SIGN_IDENTITY` (a `Developer ID Application` identity) and `NOTARY_PROFILE` (a
`notarytool` keychain profile) in the environment first.

## Tests

```sh
scripts/profile-test/run.sh
```

Headless regression for the config store and per-model profiles (drives the real
`AppModel`, no GUI). Quit SplashGUI before running it.

## Headless modes

The app binary doubles as a CLI for scripting and CI:

```sh
SplashGUI.app/Contents/MacOS/SplashGUI --install-engine   # install the pinned engine
SplashGUI.app/Contents/MacOS/SplashGUI --auto-profile     # print the derived launch args
SplashGUI.app/Contents/MacOS/SplashGUI --check-model      # verify installed weights' hash
```

## Release

Maintainers only:

```sh
scripts/bundle-app.sh --release
scripts/release.sh                # tags, pushes, and creates the GitHub release
```

## Contributing

Issues and pull requests are welcome. A few notes:

- Run `swift build` (zero warnings expected) and `scripts/profile-test/run.sh`
  before opening a PR.
- New `RunConfig` fields must be added to the explicit `init(from:)` decoder with a
  `decodeIfPresent` default — the synthesized `Codable` would break existing
  `config.json` files and silently reset every stored profile to factory defaults.
- Keep GUI copy and code in English; match the existing SwiftUI patterns
  (`Core/` is logic, `Views/` is presentation, `AppModel` is the single observable).

## License

MIT — see [LICENSE](LICENSE). SplashGUI ships no engine code; the Splash engine it
manages is licensed separately under Apache-2.0 by its authors.
