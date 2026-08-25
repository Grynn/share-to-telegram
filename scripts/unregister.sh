#!/bin/zsh
# Unload the relay agent and deregister the share extension.
# Usage: scripts/unregister.sh --app <ShareToClaw.app>
set -euo pipefail

APP_ID="app.sharetoclaw"
APP_NAME="ShareToClaw"
AGENT_LABEL="$APP_ID.relay"

APP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        *) shift ;;
    esac
done

launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
if [[ -n "$APP" && -d "$APP" ]]; then
    pluginkit -r "$APP/Contents/PlugIns/${APP_NAME}Ext.appex" 2>/dev/null || true
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -u "$APP" 2>/dev/null || true
fi
echo "unregistered."
