# Contributing to SplashGUI

This is the working reference for anyone modifying SplashGUI by hand or with an AI
assistant. It's a distillation of my personal project-memory md files. 

SplashGUI is MIT-licensed and ships **no engine code**, it is a SwiftUI front-end that downloads and manages the separate, Apache-2.0 [Splash engine](https://github.com/incoai/splash). 

## The big picture

- The app wraps `splash serve`: it builds the launch arguments, supervises the child process, polls `/status`, and derives run settings from the machine's Metal ceiling. The engine pulls and verifies models from Hugging Face itself, the app only pins and pre-flights hashes. 
- **`Core/` is logic, `Views/` is presentation, `Core/AppModel` is the single `ObservableObject`.** Views bind to it directly; rules live in Core, not in views.
- Some rules are deliberately single-sourced. Do not duplicate them:
  - `SplashServer.buildArguments`: the one argv builder (the exact launch command).
  - `ClientConfigs`: the one client-config writer (OpenCode / Zed / Claude Code / Codex).
  - `AppModel.enginePlan`: the pure (nonisolated static) engine-source mode table:
    `pinned` ignores custom fields, `custom` requires all three, `latest` keeps the installed engine when the update check fails (never a silent downgrade).
  - `AppModel.portValid`, `AppModel.providerContextTokens`, `AppPaths.dataDir`, `CatalogModel.weightsBytes`, `EngineInstaller.isInstalled`.

### Repo map

```
Sources/SplashGUI/
├── Core/
│   ├── AppConfig.swift        # Codable config (schema 6), model catalog, AppPaths, ConfigStore
│   ├── AppModel.swift         # live state: enginePlan, server lifecycle, status poll, bindings
│   ├── ClientConfigs.swift    # client config text generators (never edits a tool's config in place)
│   ├── EngineInstaller.swift  # pinned engine download/install + headless CLI
│   ├── EngineResolver.swift   # latest-release resolver (GitHub API) → EnginePin, nil on any failure
│   ├── MachineInfo.swift      # RAM/GPU/disk probes, AutoProfile (27B-arch gated), HF cache paths
│   ├── SplashClient.swift     # /status decoder (StatusSnapshot) + HTTP client
│   └── SplashServer.swift     # serve process launch, argv builder, LogRing
└── Views/
    ├── RootView.swift         # @main, sidebar, custom title bar, footer, headless probes
    ├── SettingsLayout.swift   # full-width SettingsPage / SettingsSection cards
    ├── RunTab.swift           # Model & Server + Engine + log pane
    ├── ProviderTab.swift      # client picker, sampling, config preview/copy/save
    ├── StatusTab.swift        # memory bar, headline cards, chart, metric grid
    └── StatusWidgets.swift    # title-bar controls, chips, fields, MemoryBar/TimeSeriesChart
scripts/
├── bundle-app.sh              # dev bundle; --release = Developer ID + notarized DMG
├── release.sh                 # tag + push + gh release create (maintainers)
└── profile-test/              # headless regression harness (see Tests)
```

Runtime state lives in `~/Library/Application Support/SplashGUI` (config.json, engine installs). The app and the `/Applications` copy share that directory and the server port, don't run both at once.

## Build

Requires macOS 26.4+, Apple silicon, and the Swift 6.2 toolchain (Xcode 26 or the standalone toolchain).

```sh
swift build                     # zero warnings expected — treat a new warning as breakage
scripts/bundle-app.sh --open    # ad-hoc signed build/SplashGUI.app
```

## Tests

```sh
scripts/profile-test/run.sh     # the headless harness (~88 assertions against the real AppModel)
```

- **Quit SplashGUI first.** The harness refuses to run while the app is up: it trades your live `config.json` for a fixture and restores it via a trap on exit. Note that `HOME=<tmp>` does *not* redirect `applicationSupportDirectory` on macOS. Tests always touch the real data dir, which is why the backup/restore exists.
- The harness exports `SPLASHGUI_TEST=1` so `AppModel` init doesn't spawn a real engine when `startOnLaunch` is on. Keep that guard when hand-rolling headless runs (compile `Core/*.swift` plus a throwaway `main.swift` - the file must be named exactly `main.swift` for top-level code).
- **Every new behavior gets a harness check.** Extend an existing check or table before adding one. The maintainer mutation-proves load-bearing checks (break the code, watch the specific check fail).

The app binary also doubles as a CLI, useful for verification and CI:

```sh
SplashGUI.app/Contents/MacOS/SplashGUI --install-engine   # install the pinned engine
SplashGUI.app/Contents/MacOS/SplashGUI --auto-profile     # print the derived launch args
SplashGUI.app/Contents/MacOS/SplashGUI --check-model      # verify installed weights' hash (exit 1 on mismatch)
```

## The conventions that matter

### Codable: the trap that silently wipes user settings

The synthesized `Decodable` throws on a **missing** non-optional key even when the property has a default value. Any new field on a Codable config type without a tolerant path sends every existing `config.json` into `ConfigStore.load()`'s catch-all → factory defaults, per-model profiles and all. So:

- `AppConfig`, `RunConfig`, `SamplingDefaults`, and `ModelProfile` have explicit `init(from:)` implementations. **Every new field needs a `decodeIfPresent` + default** (or make it Optional). Nested types are otherwise still strict and the same trap applies if they gain fields.
- A struct with any custom initializer loses its memberwise init, so those types also need an explicit `init()`.
- Config shape changes bump `schemaVersion` and migrate tolerantly (e.g. schema 5 rewrote a stored `"0"` cache quota to `"10G"`; unknown keys like the retired `taskPreset` are ignored and dropped on next save).
- Add a harness fixture check for any new field: old-config decode + migration.

### SwiftUI gotchas (each one was a shipped bug)

- `Text("...\(8095)")` interpolates through `LocalizedStringKey` and renders **"8,095"**. Machine values go through `String(int)` `TextField(value:format:.number)` needs `.grouping(.never)`.
- Grouped `Form` centers rows in a fixed ~704 pt column and wastes wide windows, use `SettingsPage`/`SettingsSection`.
- macOS sizes `.toolbar` items to content, so a stretching item collapses. The server controls live in the custom 54 pt `RootView.titleBar` instead, not a `.toolbar`.
- Long inline view trees hit the type-checker limit ("conform to TableRowContent" cascades). Extract columns/sections into computed properties.
- Labels **hug** their text; alignment comes from `Grid` columns, not fixed-width label frames (fixed frames caused the dead gaps). The two documented exceptions are deliberate local alignments (Provider sampling rows, `LabeledField` value columns).
- **No animation anywhere.** All state movement comes from the 2s status poll.
- **System colors only.** No hex/RGB literals; dark mode comes free from that rule.

### UI copy

- English, sentence case, try to keep em dashes down (especially on anything user-facing) unless you're quoting Dragon's Dogma dialogue.
- Prefer `.help(...)` tooltips over inline prose; inline `.caption` only for facts a user needs without hovering. A tooltip that quotes a number **names its source** (model card, Metal ceiling, engine's own limit). Never present a value as arbitrary.
- Applying card values is an explicit click ("Reset to model card", the thinking-off link), never a side effect of switching models or effort.
- The footer is the single error surface; there is no error banner.

## Working with the Splash engine

Engine behavior here was verified empirically against installed releases, not from docs.
Two standing rules:

1. **Verify against the installed engine payload**
   (`~/Library/Application Support/SplashGUI/engine/current/`), not a stale clone or
   release notes. The `--max-cache-disk` semantics changed between 1.3.0 and 1.3.2; a
   reference tree that is two versions behind will mislead you.
2. **Engine bumps are code changes.** The compiled `EngineInstaller.defaultPin` is the tested default; `latest` mode resolves live from the GitHub releases API (and keeps the installed engine on any failure). When bumping the pin, re-verify every flag `buildArguments` passes against the new payload (1.5.0 rejects CLI abbreviations, for example) and re-check any code comment that claims engine behavior.

Facts worth knowing before touching server integration:

- The engine **always pairs a speed draft** (DFlash2): there is no `--no-draft` flag, sentinel, or env var (verified on 1.5.0). Don't add an app-side "skip draft" toggle until upstream adds the flag.
- Sampling: there are no serve-level defaults; omitted fields fall back to the engine's per-request defaults (temperature 1.0 / top_p 0.95 / top_k 20). On 1.3.2+ every sampling field is accepted **except `logit_bias`** (400). Model-card values are the app's defaults source; card asks the engine refuses are stated in the UI, not silently dropped.
- `--max-cache-disk`: `"auto"` omits the flag (engine follows volume free space), `"0"` disables the SSD tier; `--persistent-cache` is refused without a non-zero quota, so the app must not pass it alongside `"0"`.
- `--idle-release` (default 10 m) unwires weights when idle; the next request pays a ~4–6 s restore plus a slower first prefill. The app defaults to `60m`.
- Model targets are Hub IDs only (`owner/repo[:VARIANT]`, the variant is part of the store-link name). The catalog follows the engine's own `install/suggested-models.tsv` and carries revision+sha256 pins only on rows verified on hardware. The pre-flight hash check exists because the engine's own startup verify only re-checks paths and byte counts.
- Stopping a serve by hand: kill the **Python launcher** first (or in the same batch as the native child), or the launcher auto-restarts the engine. `lsof -i :PORT` also matches TIME_WAIT sockets, don't gate on it.
- Auto-sizing (`MachineInfo.autoProfile`) keys on `recommendedMaxWorkingSetSize` (the Metal wired ceiling), **not** free RAM. macOS keeps RAM resident, so `availableRAM` is misleading. It is gated to the 27B-arch catalog rows (one measured KV constant); other archs and custom IDs return nil so the engine self-sizes. That is a documented semantic ("Splash auto-sizes"), not a bug.

## Pull requests

- Write or at least edit the body yourself. If you have an LLM draft it, that's fine, but please don't let a model dump a 700 word short novel on me when it could have been a paragraph (they really love doing this). The diff will show the code changes so the body just needs to be a "TLDR" of what changed and why.
- Small, reversible steps; match the existing style; don't reflow or reword lines you don't need to change. Keep comments concise, and don't re-state what the code itself already says it does. 
- Reuse before you add: grep for an existing helper or check and extend it. No new options or exports without a caller.
- Don't rename the bundle id (`com.splashgui.app`) or the data directory. Both are migration anchors.
- Before opening a PR: `swift build` with zero warnings, `scripts/profile-test/run.sh` green (app quit), and a new harness check for any new behavior. If you changed visuals, rebuild the dev bundle (`scripts/bundle-app.sh --open`) and actually look at it. If you can't for the life of you get it working but you think it's something that really should be added, go ahead and cut the PR with that as a note, and I'll see if I can wrassle it. 
- Don't commit: `build/`, `.build/`, `scratch/`, DMGs, or anything under `~/Library/Application Support`.

## Releases (maintainers only)

```sh
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=… scripts/bundle-app.sh --release
scripts/release.sh    # tags splashgui/v<version>, pushes main + tag, gh release create
```

- Bump `Resources/Info.plist` version + build first; the build counter stays monotonic.
- **Never move a published tag.** Re-tag forward instead.
- `release.sh` does a plain push: if history was rewritten (squash), force-push `main` as its own step *before* running it.
- Only the app binary is signed/notarized. The engine is downloaded via URLSession (no quarantine xattr) and runs as a child process under its own signature, it does not need ours.

## Notes for AI agents

If you are an LLM or agent working on this repo, whether dispatched by a harness or
driven interactively:

1. **Read before you write.** Never edit a file you haven't just read; never reference a symbol without confirming it exists. Start with `README.md`, this file, then the specific Core/Views files you'll touch.
2. **Verify, don't assert.** "It should work" is not verification. The definition of done is: `swift build` clean with zero warnings, `scripts/profile-test/run.sh` green, and - for behavior the harness can reach - a new check that would fail if you reverted the fix. Run the headless CLI modes (`--auto-profile`, `--check-model`) to confirm engine-facing changes instead of reasoning about argv.
3. **Check the running engine, not your memory of it.** Claims about Splash flags, defaults, or `/status` fields must be confirmed against the installed engine payload or a live endpoint. Comments in this repo that state engine facts name the version they were verified on, re-verify on a pin bump.
4. **The Codable trap and the number-localization trap are the two easiest ways to ship a silent data-loss or display bug.** Re-read those sections before touching config types or any `Text`/`TextField` that renders a machine value.
5. **Respect the live environment.** The harness mutates the real `config.json` (with backup/restore). Quit the app before running it, and never edit `config.json` while the app runs: it saves on picker changes and at quit, silently clobbering external edits. Drive the app or the CLI instead.
6. **Keep scope.** No unrequested features, abstractions, or "while I'm here" refactors; flag unrelated problems in your summary instead of fixing them in passing.
7. **Be honest about uncertainty.** Say what you ran, what passed, and what you could not verify. If you reviewed or relayed another agent's output, grep-verify every load-bearing claim before presenting it as fact. Sub-agent reports have shipped real findings alongside hallucinated symbols and fixes that broke adjacent paths.
8. **Never invent content in docs or comments.** Record only what you observed or what the user decided.
