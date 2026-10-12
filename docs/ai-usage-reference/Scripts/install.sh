#!/bin/sh
# Build and install AI Usage Bar.
#
# Idempotent: safe to re-run after code changes to redeploy.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/AIUsageBar.app"
LABEL="co.emulus.aiusagebar"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
HOOK="$ROOT/Scripts/claude-statusline.py"
SETTINGS="$HOME/.claude/settings.json"

echo "==> Building"
cd "$ROOT"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/AIUsageBar"

echo "==> Assembling $APP"
# Stop a running copy so the binary can be replaced.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -f "AIUsageBar.app/Contents/MacOS/AIUsageBar" 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AIUsageBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/"*.png "$APP/Contents/Resources/" 2>/dev/null || true
# Ad-hoc signature: unsigned binaries are killed on launch on Apple silicon.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "    (codesign skipped)"

echo "==> Installing the Claude Code statusLine hook"
chmod +x "$HOOK"
python3 - "$SETTINGS" "$HOOK" <<'PY'
import json, os, shutil, sys, time

settings_path, hook = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(settings_path), exist_ok=True)

settings = {}
if os.path.exists(settings_path):
    shutil.copy2(settings_path, settings_path + ".bak-" + time.strftime("%Y%m%d-%H%M%S"))
    try:
        with open(settings_path) as f:
            settings = json.load(f)
    except Exception:
        print("    settings.json unreadable; leaving it alone")
        raise SystemExit(0)

existing = settings.get("statusLine")
if existing and existing.get("command") != hook:
    # Someone else's status line lives here. Displacing it silently would be a
    # surprise, so report and let the user decide.
    print("    statusLine already set to:", existing.get("command"))
    print("    NOT replacing it. Chain the hook manually to use both.")
    raise SystemExit(0)

settings["statusLine"] = {"type": "command", "command": hook}
with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print("    statusLine ->", hook)
PY

echo "==> Installing the Antigravity status hook"
AGY_HOOK="$ROOT/Scripts/agy-status.py"
chmod +x "$AGY_HOOK"
AGY_HOOKS_FILE="$HOME/.gemini/config/hooks.json"
python3 - "$AGY_HOOKS_FILE" "$AGY_HOOK" <<'PY'
import json, os, shutil, sys, time

hooks_path, hook = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(hooks_path), exist_ok=True)

hooks = {}
if os.path.exists(hooks_path):
    shutil.copy2(hooks_path, hooks_path + ".bak-" + time.strftime("%Y%m%d-%H%M%S"))
    try:
        with open(hooks_path) as f:
            hooks = json.load(f)
    except Exception:
        print("    hooks.json unreadable; leaving it alone")
        raise SystemExit(0)

hook_entry = {
    "type": "command",
    "command": hook,
    "timeout": 5,
}

bar_hook = hooks.get("ai-usage-bar", {})
bar_hook["PreInvocation"] = [hook_entry]
bar_hook["PostToolUse"] = [
    {
        "matcher": "*",
        "hooks": [hook_entry]
    }
]
bar_hook["Stop"] = [hook_entry]
hooks["ai-usage-bar"] = bar_hook

with open(hooks_path, "w") as f:
    json.dump(hooks, f, indent=2)
    f.write("\n")
print("    hooks.json -> ai-usage-bar hook")
PY

echo "==> Installing the login agent"
mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/AIUsageBar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null || launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo
echo "Installed. Look for the ring in your menu bar."
echo
echo "Claude's numbers refresh whenever Claude Code renders its status line;"
echo "Gemini's need Antigravity (IDE or CLI) running."
echo
echo "To uninstall:"
echo "  launchctl bootout gui/$(id -u)/$LABEL"
echo "  rm -rf '$APP' '$AGENT'"
echo "  # then remove the \"statusLine\" key from $SETTINGS"
echo "  # and the \"ai-usage-bar\" key from $AGY_HOOKS_FILE"
