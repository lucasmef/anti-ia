#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/Sinal IA.app"
STAGING="$(mktemp -d /private/tmp/sinal-ia-build.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
BUILT_APP="$STAGING/Sinal IA.app"
mkdir -p "$BUILT_APP/Contents/MacOS" "$BUILT_APP/Contents/Resources" build/module-cache
swiftc -O -target "$(uname -m)-apple-macosx12.0" -module-cache-path "$PWD/build/module-cache" Sources/Scanner.swift Sources/ImageScanner.swift Sources/main.swift -import-objc-header Sources/Zlib.h -lz -framework ImageIO -o "$BUILT_APP/Contents/MacOS/SinalIA" -framework AppKit
cp -X Info.plist "$BUILT_APP/Contents/Info.plist"
codesign --force --deep --sign - "$BUILT_APP"
codesign --verify --deep --strict "$BUILT_APP"
ditto --noextattr --norsrc "$BUILT_APP" "$APP"
echo "App criado: $APP"
