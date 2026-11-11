#!/bin/bash
# Install screen-lease: CLI + window-id helper + menu bar light (LaunchAgent) + Claude Code skill.
#   BIN_DIR    where the CLI and binaries go (default ~/.local/bin)
#   SKILL_DIR  Claude Code skills dir (default ~/.claude/skills); set to "" to skip
# Re-run any time to rebuild and reinstall. Uninstall: ./install.sh --uninstall
set -eu

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
SKILL_DIR="${SKILL_DIR-$HOME/.claude/skills}"
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
