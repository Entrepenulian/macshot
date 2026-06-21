#!/bin/bash
# Build macshot into a real, double-clickable, persistent menu-bar app.
# Usage:  ./build-app.sh   ->   produces ./macshot.app
set -eo pipefail
cd "$(dirname "$0")"

APP="macshot.app"
echo "[1/4] building release binary..."
swift build -c release

BIN="$(swift build -c release --show-bin-path)/macshot"
echo "[2/4] assembling ${APP}..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/macshot"

echo "[3/4] writing Info.plist..."
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>macshot</string>
  <key>CFBundleDisplayName</key>     <string>macshot</string>
  <key>CFBundleIdentifier</key>      <string>com.macshot.app</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key>      <string>macshot</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <key>LSUIElement</key>             <true/>
  <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS gives the app a stable identity (TCC remembers the
# Desktop-access grant across launches instead of re-asking).
echo "[4/4] ad-hoc signing..."
codesign --force --sign - "${APP}" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "OK - built ${APP}"
echo
echo "Run it:      open ${APP}"
echo "Install it:  mv ${APP} /Applications/"
echo "Quit it:     menu-bar icon -> Quit macshot"
