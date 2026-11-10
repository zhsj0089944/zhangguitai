#!/bin/bash
# 编译 + 打包 + ad-hoc 签名。不需要 Xcode，CLT 的 swiftc 就够。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="掌柜台"
BIN="zhanguitai"
OUT="build/${APP_NAME}.app"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

cp Resources/Info.plist "$OUT/Contents/Info.plist"
cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

echo "→ 编译中…"
swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  -o "$OUT/Contents/MacOS/$BIN" \
  Sources/*.swift

echo "→ 签名（ad-hoc）"
codesign --force --deep --sign - "$OUT" 2>&1 | sed 's/^/   /'
codesign -dv "$OUT" 2>&1 | grep -E "Identifier|Signature" | sed 's/^/   /'

echo "✅ 产物：$(pwd)/$OUT"
du -sh "$OUT" | awk '{print "   体积：" $1}'
