#!/bin/bash
# Build macsnap into a real, double-clickable, persistent menu-bar app.
# Usage:  ./build-app.sh   ->   produces ./macsnap.app
set -eo pipefail
cd "$(dirname "$0")"

APP="macsnap.app"
echo "[1/4] building release binary..."
swift build -c release

BIN="$(swift build -c release --show-bin-path)/macsnap"
echo "[2/4] assembling ${APP}..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/macsnap"

echo "[3/4] writing Info.plist..."
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>macsnap</string>
  <key>CFBundleDisplayName</key>     <string>macsnap</string>
  <key>CFBundleIdentifier</key>      <string>com.macsnap.app</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key>      <string>macsnap</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <key>LSUIElement</key>             <true/>
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict>
</plist>
PLIST

# Sign with a STABLE self-signed identity so macOS TCC grants (Screen Recording,
# Accessibility, Desktop access) persist across rebuilds. Ad-hoc signatures change
# their cdhash every build, which silently resets every permission — the whole
# reason "Screenshot site" kept asking for access it had already been given.
echo "[4/4] signing with stable identity..."
SIGN_KC="$PWD/macsnap-signing.keychain"
security unlock-keychain -p macsnapsign "${SIGN_KC}" 2>/dev/null || true
if security find-identity -p codesigning "${SIGN_KC}" 2>/dev/null | grep -q "macsnap Self Sign"; then
  codesign --force --sign "macsnap Self Sign" --keychain "${SIGN_KC}" "${APP}" >/dev/null 2>&1 \
    && echo "  signed: macsnap Self Sign (stable)" \
    || { echo "  stable sign failed → ad-hoc"; codesign --force --sign - "${APP}" >/dev/null 2>&1; }
else
  echo "  no stable identity found → ad-hoc"; codesign --force --sign - "${APP}" >/dev/null 2>&1
fi

echo "OK - built ${APP}"
echo
echo "Run it:      open ${APP}"
echo "Install it:  mv ${APP} /Applications/"
echo "Quit it:     menu-bar icon -> Quit macsnap"
