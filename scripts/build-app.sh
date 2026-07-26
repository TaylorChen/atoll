#!/bin/bash
# Build Atoll.app — a proper menu-bar app bundle (LSUIElement, icon, no Dock).
# Usage: scripts/build-app.sh [--install]   (--install copies to /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Atoll.app"
VERSION="1.0.2"

echo "→ Release 构建 App + bridge…"
( cd app && swift build -c release )
( cd bridge && go build -ldflags="-s -w" -o ../build/atoll-bridge . )

echo "→ 组装 $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/.build/release/Atoll "$APP/Contents/MacOS/Atoll"
cp app/Resources/Atoll.icns "$APP/Contents/Resources/Atoll.icns"
cp build/atoll-bridge "$APP/Contents/Resources/atoll-bridge"
cp scripts/install-hooks.py "$APP/Contents/Resources/install-hooks.py"
cp scripts/atoll-opencode.js "$APP/Contents/Resources/atoll-opencode.js"
cp scripts/atoll-statusline.sh "$APP/Contents/Resources/atoll-statusline.sh"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Atoll</string>
  <key>CFBundleDisplayName</key><string>Atoll</string>
  <key>CFBundleIdentifier</key><string>app.atoll.macos</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>Atoll</string>
  <key>CFBundleIconFile</key><string>Atoll</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Menu-bar/overlay app: no Dock icon, no app menu. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so Automation/Accessibility permissions attach to a stable identity.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  （自签跳过）"

echo "✅ 已生成 $APP"
if [ "${1:-}" = "--install" ]; then
  echo "→ 安装到 /Applications …"
  rm -rf "/Applications/Atoll.app"
  cp -R "$APP" "/Applications/Atoll.app"
  echo "✅ 已安装。可在启动台/访达双击打开，或用 open -a Atoll。"
fi
