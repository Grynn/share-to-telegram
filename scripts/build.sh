#!/bin/zsh
# Build ShareToClaw.app (host app + sandboxed share extension) into a directory.
# Usage: scripts/build.sh [DEST_DIR]   (default: <repo>/build)
set -euo pipefail

APP_ID="app.sharetoclaw"
APP_NAME="ShareToClaw"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$ROOT/build}"
APP="$DEST/$APP_NAME.app"
APPEX="$APP/Contents/PlugIns/${APP_NAME}Ext.appex"

# swiftc for app extensions needs the full Xcode toolchain, not just the CLT.
if [[ -z "${DEVELOPER_DIR:-}" && ! -d "$(xcode-select -p 2>/dev/null)/Platforms" ]]; then
    for candidate in /Applications/Xcode*.app; do
        [[ -d "$candidate/Contents/Developer" ]] && export DEVELOPER_DIR="$candidate/Contents/Developer" && break
    done
fi
command -v swiftc >/dev/null || { echo "swiftc not found — install Xcode"; exit 1; }

TARGET="$(uname -m)-apple-macos13.0"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APPEX/Contents/MacOS"

echo "== host app ($TARGET)"
swiftc "$ROOT/app/HostApp/main.swift" \
    -o "$APP/Contents/MacOS/$APP_NAME" \
    -target "$TARGET" -O -framework AppKit

echo "== share extension"
swiftc "$ROOT/app/ShareExt/ShareViewController.swift" \
    -o "$APPEX/Contents/MacOS/${APP_NAME}Ext" \
    -target "$TARGET" -O -parse-as-library -application-extension \
    -module-name "${APP_NAME}Ext" \
    -framework AppKit -framework UniformTypeIdentifiers \
    -Xlinker -e -Xlinker _NSExtensionMain

cp "$ROOT/app/HostApp/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/app/ShareExt/Info.plist" "$APPEX/Contents/Info.plist"

# PlugInKit silently ignores an .appex that is not signed as sandboxed.
echo "== signing (ad-hoc)"
codesign --force -s - --identifier "$APP_ID.share" \
    --entitlements "$ROOT/app/ShareExt/ShareExt.entitlements" "$APPEX"
codesign --force -s - --identifier "$APP_ID" "$APP"
echo "built $APP"
