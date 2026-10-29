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
- **Model catalogue.** Curated, revision-pinned Hugging Face entries with post-download
  hash verification, plus a free-form `owner/repo[:variant]` slot for anything else.
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

| Model | Target size | Loaded | Notes |
| --- | --- | --- | --- |
| Qwen3.8-27B IQ3_XXS | 10.9 GB | 15.7 GB | Default; the lightest Qwen variant |
| Qwen3.8-27B IQ4_XS | 14.3 GB | 19 GB | For 24–32 GB Macs |
| Qwen3.8-27B Q4_K_XL | 17.6 GB | 22.3 GB | Quality pick, needs 32 GB+ |
| Bonsai 2 27B (PQ2_0) | 7.2 GB | 11.2 GB | Ternary 2-bit, the 16 GB-Mac candidate |
| Qwen3.8-27B MLX 4-bit | ~16 GB | — | MLX shards, unpinned |
| Custom… | — | — | Any `owner/repo[:variant]` |

Catalogue entries are pinned to an exact Hugging Face revision and file digest, so a
re-upload under the same name can't silently change what your Mac loads.

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
