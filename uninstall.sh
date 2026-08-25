#!/bin/zsh
# Remove a from-source install (app, extension, relay agent, CLI shim).
# Config and Telegram session in ~/.config/share-to-claw are kept unless --purge.
set -euo pipefail

APP_NAME="ShareToClaw"
ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALLED="$HOME/Applications/$APP_NAME.app"

"$ROOT/scripts/unregister.sh" --app "$INSTALLED" || true
rm -rf "$INSTALLED" "$HOME/Library/Application Support/$APP_NAME" "$HOME/.local/bin/share-to-claw"

if [[ "${1:-}" == "--purge" ]]; then
    rm -rf "$HOME/.config/share-to-claw" "$HOME/Library/Logs/$APP_NAME.log"
    echo "Removed everything, including the Telegram session."
else
    echo "Removed. Config kept in ~/.config/share-to-claw (use --purge to delete)."
fi
echo "The sandbox container in ~/Library/Containers/app.sharetoclaw.share is left to macOS."
