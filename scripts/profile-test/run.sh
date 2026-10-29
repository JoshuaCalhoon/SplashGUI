#!/usr/bin/env zsh
# Headless regression for the config store: profile swap, schema migration, model cards.
# Drives the real AppModel (no GUI) against a temp fixture at the real config.json path,
# because HOME does not redirect applicationSupportDirectory. Refuses to run while the app
# is up, and restores the original config.json whatever happens.
set -e
cd "$(dirname "$0")"
CORE="../../Sources/SplashGUI/Core"
CFG="$HOME/Library/Application Support/SplashGUI/config.json"
# AppModel auto-starts the server on init when config.startOnLaunch is on; never let the
# harness spawn a real serve.
export SPLASHGUI_TEST=1

if pgrep -f "SplashGUI.app/Contents/MacOS/SplashGUI" >/dev/null; then
  print "SplashGUI is running — quit it first (it saves config.json on change and at exit)." && exit 2
fi
[[ -f "$CFG" ]] || { print "no config.json at $CFG"; exit 2; }

backup=$(mktemp)
cp "$CFG" "$backup"
trap 'cp "$backup" "$CFG"; rm -f "$backup"; print "config.json restored"' EXIT

# A pre-profiles (schemaVersion 2) config: no modelProfiles key, and typed values the assertions
# below read back — proof the file decoded and migrated rather than falling back to factory.
python3 - <<'EOF'
import json, os
p = os.path.expanduser("~/Library/Application Support/SplashGUI/config.json")
c = json.load(open(p))
c['run']['schemaVersion'] = 2
c['run']['kvFormat'] = 'bf16'
c['run']['maxContext'] = '100K'
# Pin the starting model: the assertions below assume the current model is A (IQ3_XXS),
# so the fixture must not inherit whatever model the live config happens to select.
c['run']['modelID'] = 'unsloth/Qwen3.8-27B-GGUF:UD-IQ3_XXS'
c['startOnLaunch'] = False   # live config may have it on; the fixture must stay inert
c['sampling']['temperature'] = 0.23
c.pop('modelProfiles', None)
json.dump(c, open(p, 'w'), indent=1)
EOF

swiftc -swift-version 5 -o /tmp/splashgui-profiletest \
  "$CORE"/AppConfig.swift "$CORE"/AppModel.swift "$CORE"/ClientConfigs.swift \
  "$CORE"/EngineInstaller.swift \
  "$CORE"/MachineInfo.swift "$CORE"/SplashClient.swift "$CORE"/SplashServer.swift main.swift

/tmp/splashgui-profiletest
