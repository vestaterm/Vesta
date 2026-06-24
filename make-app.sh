#!/bin/bash
# Build Halo.app — a double-clickable bundle with the halo logo as its icon.
# The binary is self-contained (ghostty is statically linked), so the bundle is
# just: the executable + the SPM resource bundle + an .icns + Info.plist.
set -euo pipefail
cd "$(dirname "$0")"

CONF="${1:-release}"            # make-app.sh [release|debug]
APP="Halo.app"
BINDIR=".build/$CONF"

echo ">> building ($CONF)..."
swift build -c "$CONF" >/dev/null

BIN="$BINDIR/halo"
BUNDLE=$(ls -d "$BINDIR"/Halo_halo.bundle 2>/dev/null | head -1)
[ -x "$BIN" ] || { echo "no binary at $BIN"; exit 1; }
[ -d "$BUNDLE" ] || { echo "no resource bundle next to binary"; exit 1; }

echo ">> rendering icon..."
ICONSET=$(mktemp -d)/Halo.iconset; mkdir -p "$ICONSET"
qlmanage -t -s 1024 -o /tmp assets/halo-logo.svg >/dev/null 2>&1
SRC=/tmp/halo-logo.svg.png
for s in 16 32 128 256 512; do
  sips -z $s $s          "$SRC" --out "$ICONSET/icon_${s}x${s}.png"      >/dev/null
  sips -z $((s*2)) $((s*2)) "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o /tmp/AppIcon.icns

echo ">> assembling ${APP}..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "$BIN" "${APP}/Contents/MacOS/Halo"
# Resource bundle as DATA in Resources (Bundle.module also searches Bundle.main.resourceURL),
# so codesign doesn't treat it as unsigned nested code.
cp -R "$BUNDLE" "${APP}/Contents/Resources/"
cp /tmp/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Halo</string>
  <key>CFBundleDisplayName</key>     <string>Halo</string>
  <key>CFBundleExecutable</key>      <string>Halo</string>
  <key>CFBundleIdentifier</key>      <string>dev.halo.terminal</string>
  <key>CFBundleIconFile</key>        <string>AppIcon</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>0.1.0</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSPrincipalClass</key>        <string>NSApplication</string>
  <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
  <!-- open a folder in Halo: "Open With", `open -a Halo <dir>`, drag-to-icon -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>      <string>Folder</string>
      <key>CFBundleTypeRole</key>      <string>Viewer</string>
      <key>LSHandlerRank</key>         <string>Alternate</string>
      <key>LSItemContentTypes</key>    <array><string>public.folder</string></array>
    </dict>
  </array>
  <!-- Finder right-click > Services > New Halo Session Here -->
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key>   <dict><key>default</key><string>New Halo Session Here</string></dict>
      <key>NSMessage</key>    <string>newSessionHere</string>
      <key>NSPortName</key>   <string>Halo</string>
      <key>NSSendFileTypes</key> <array><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# ad-hoc sign (executable then wrapper; no --deep — the resource bundle is data).
codesign --force --sign - "${APP}/Contents/MacOS/Halo" >/dev/null 2>&1 || true
codesign --force --sign - "${APP}" >/dev/null 2>&1 && echo "OK: signed (ad-hoc)" || echo "  (codesign skipped)"

echo "OK: built $APP — open with: open ${APP}"
