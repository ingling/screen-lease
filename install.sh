#!/bin/bash
# Install screen-lease: CLI + window-id helper + menu bar light (LaunchAgent) + Claude Code skill.
#   BIN_DIR    where the CLI and binaries go (default ~/.local/bin)
#   SKILL_DIR  Claude Code skills dir (default ~/.claude/skills); set to "" to skip
# Re-run any time to rebuild and reinstall. Uninstall: ./install.sh --uninstall
#
# Claude Code permission-prompt hooks (light turns yellow while the lease holder waits on a prompt):
#   ./install.sh --claude-hooks           add them to ~/.claude/settings.json (backup kept next to it)
#   ./install.sh --remove-claude-hooks    take them out again
#   CLAUDE_SETTINGS=<path>                another settings file
set -eu

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
SKILL_DIR="${SKILL_DIR-$HOME/.claude/skills}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

claude_hooks() { # add|remove: edit only screen-lease's own entries, keep everything else
	[ -f "$CLAUDE_SETTINGS" ] && cp -p "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak-screen-lease"
	/usr/bin/python3 - "$1" "$CLAUDE_SETTINGS" "$BIN_DIR/screen-lease" <<'PY'
import json, os, re, sys
mode, path, cli = sys.argv[1:]
data = json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}
hooks = data.setdefault("hooks", {})
events = {"PermissionRequest": "prompt", "PostToolUse": "answered", "PostToolUseFailure": "answered",
          "Stop": "answered", "UserPromptSubmit": "answered"}
for event in list(hooks):  # drop earlier screen-lease entries
    groups = []
    for g in hooks[event]:
        g["hooks"] = [h for h in g.get("hooks", [])
                      if not re.search(r"screen-lease'? hook (prompt|answered)", h.get("command", ""))]
        if g["hooks"]:
            groups.append(g)
    if groups:
        hooks[event] = groups
    else:
        del hooks[event]
if mode == "add":
    for event, arg in events.items():
        group = {"hooks": [{"type": "command", "command": f"'{cli}' hook {arg}", "async": True, "timeout": 10}]}
        if event not in ("Stop", "UserPromptSubmit"):
            group["matcher"] = "*"
        hooks.setdefault(event, []).append(group)
if not hooks:
    del data["hooks"]
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
	[ "$1" = add ] && echo "screen-lease hooks added to $CLAUDE_SETTINGS" || echo "screen-lease hooks removed from $CLAUDE_SETTINGS"
	[ -f "$CLAUDE_SETTINGS.bak-screen-lease" ] && echo "previous version: $CLAUDE_SETTINGS.bak-screen-lease"
}
case "${1:-}" in
--claude-hooks) claude_hooks add; exit 0 ;;
--remove-claude-hooks) claude_hooks remove; exit 0 ;;
esac
CONFIG_DIR="$HOME/.config/screen-lease"
LABEL="io.github.screen-lease.light"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [ "${1:-}" = "--uninstall" ]; then
	launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
	for f in "$PLIST" "$BIN_DIR/screen-lease" "$BIN_DIR/ScreenLeaseLight" "$BIN_DIR/windowid"; do
		[ -e "$f" ] || [ -L "$f" ] && mv "$f" "$HOME/.Trash/" && echo "moved to Trash: $f"
	done
	[ -n "$SKILL_DIR" ] && [ -d "$SKILL_DIR/screen-lease" ] && mv "$SKILL_DIR/screen-lease" "$HOME/.Trash/screen-lease-skill.$$" && echo "skill moved to Trash"
	echo "config and state left in place: $CONFIG_DIR, ~/Library/Application Support/screen-lease"
	exit 0
fi

mkdir -p "$BIN_DIR" "$REPO/build" "$CONFIG_DIR" "$HOME/Library/LaunchAgents"

echo "building..."
swiftc -O -o "$REPO/build/ScreenLeaseLight" "$REPO/app/ScreenLeaseLight.swift"
swiftc -O -o "$REPO/build/windowid" "$REPO/app/windowid.swift"

ln -sf "$REPO/bin/screen-lease" "$BIN_DIR/screen-lease"
cp -f "$REPO/build/ScreenLeaseLight" "$REPO/build/windowid" "$BIN_DIR/"

[ -f "$CONFIG_DIR/config.json" ] || cp "$REPO/config.example.json" "$CONFIG_DIR/config.json"

if [ -n "$SKILL_DIR" ]; then
	mkdir -p "$SKILL_DIR/screen-lease"
	sed -e "s#@@CLI@@#$BIN_DIR/screen-lease#g" -e "s#@@WINDOWID@@#$BIN_DIR/windowid#g" \
		"$REPO/skill/SKILL.md.template" >"$SKILL_DIR/screen-lease/SKILL.md"
	echo "skill installed: $SKILL_DIR/screen-lease/SKILL.md"
fi

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key><array><string>$BIN_DIR/ScreenLeaseLight</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
	<key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "menu bar light running (LaunchAgent $LABEL; starts at login)"
echo "CLI: $BIN_DIR/screen-lease   config: $CONFIG_DIR/config.json"
