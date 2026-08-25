#!/bin/zsh
# Remove a from-source install (app, extension, relay agent, CLI shim).
# Config and Telegram session in ~/.config/send-to-my-bot are kept unless --purge.
set -euo pipefail

APP_NAME="SendToMyBot"
ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALLED="$HOME/Applications/$APP_NAME.app"

"$ROOT/scripts/unregister.sh" --app "$INSTALLED" || true
rm -rf "$INSTALLED" "$HOME/Library/Application Support/$APP_NAME" "$HOME/.local/bin/send-to-my-bot"

if [[ "${1:-}" == "--purge" ]]; then
    rm -rf "$HOME/.config/send-to-my-bot" "$HOME/Library/Logs/$APP_NAME.log"
    echo "Removed everything, including the Telegram session."
else
    echo "Removed. Config kept in ~/.config/send-to-my-bot (use --purge to delete)."
fi
echo "The sandbox container in ~/Library/Containers/app.sendtomybot.share is left to macOS."
