#!/bin/zsh
# Register the share extension with macOS and load the relay LaunchAgent.
# Usage: scripts/register.sh --app <ShareToClaw.app> --script <share_to_claw.py> --uv <uv>
set -euo pipefail

APP_ID="app.sharetoclaw"
APP_NAME="ShareToClaw"
AGENT_LABEL="$APP_ID.relay"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$HOME/Library/Logs/$APP_NAME.log"
QUEUE="$HOME/Library/Containers/$APP_ID.share/Data/queue"

APP="" SCRIPT="" UV=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --script) SCRIPT="$2"; shift 2 ;;
        --uv) UV="$2"; shift 2 ;;
        *) echo "unknown argument: $1"; exit 2 ;;
    esac
done
[[ -d "$APP" && -f "$SCRIPT" && -x "$UV" ]] || { echo "usage: register.sh --app <.app> --script <share_to_claw.py> --uv <uv>"; exit 2; }

TEMPLATE="$ROOT/agent/relay.plist.template"
[[ -f "$TEMPLATE" ]] || TEMPLATE="$(dirname "$SCRIPT")/relay.plist.template"

echo "== registering with LaunchServices + PlugInKit"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
# macOS 26+ only hands the .appex to pkd after the host app has been launched
# once; without this the extension registers as "no matches" and never appears.
open -jg "$APP" 2>/dev/null || open "$APP"
sleep 3
pluginkit -a "$APP/Contents/PlugIns/${APP_NAME}Ext.appex"
pluginkit -e use -i "$APP_ID.share" 2>/dev/null || true
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true

echo "== relay LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__UV__|$UV|g" -e "s|__SCRIPT__|$SCRIPT|g" \
    -e "s|__QUEUE__|$QUEUE|g" -e "s|__LOG__|$LOG|g" \
    "$TEMPLATE" > "$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

echo "== share extension:"
pluginkit -m -A -v -i "$APP_ID.share" || echo "  (not visible — open $APP_NAME.app once, then re-run)"
if [[ ! -f "$HOME/.config/share-to-claw/config.json" ]]; then
    echo
    echo "Next: configure destinations (asks only for what is missing)"
    echo "    share-to-claw setup"
fi
