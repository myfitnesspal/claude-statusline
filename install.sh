#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/statusline.sh"

# Check for jq
if ! command -v jq &>/dev/null; then
	echo "Error: jq is required. Install with: brew install jq"
	exit 1
fi

# Symlink the script
ln -sf "$SCRIPT_DIR/statusline.sh" "$DEST"
chmod +x "$DEST"

echo "Linked $DEST -> $SCRIPT_DIR/statusline.sh"

# Check if settings.json already has a statusLine config
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && grep -q '"statusLine"' "$SETTINGS"; then
	echo ""
	echo "Your $SETTINGS already has a statusLine entry."
	echo "Make sure it points to:"
	echo ""
	echo '  "statusLine": {'
	echo '    "type": "command",'
	echo "    \"command\": \"bash $DEST\""
	echo '  }'
else
	echo ""
	echo "Add this to $SETTINGS:"
	echo ""
	echo '  "statusLine": {'
	echo '    "type": "command",'
	echo "    \"command\": \"bash $DEST\""
	echo '  }'
fi
