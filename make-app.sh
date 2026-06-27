#!/bin/bash
# Build Vesta.app — a double-clickable bundle with the vesta logo as its icon.
# The binary is self-contained (ghostty is statically linked), so the bundle is
# just: the executable + the SPM resource bundle + an .icns + Info.plist.
set -euo pipefail
cd "$(dirname "$0")"

CONF="${1:-release}"            # make-app.sh [release|debug]
APP="Vesta.app"
BINDIR=".build/$CONF"

# Bundle version (CFBundleShortVersionString) — what the in-app updater compares against
# the latest GitHub release. Prefer VESTA_VERSION (CI passes the tag), else the latest git
# tag, else a dev fallback. Must look like a version (digits…), else fall back.
VERSION="${VESTA_VERSION:-}"
[ -z "$VERSION" ] && VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
case "$VERSION" in [0-9]*) ;; *) VERSION="0.1.0" ;; esac

echo ">> building ($CONF)..."
swift build -c "$CONF" >/dev/null

BIN="$BINDIR/vesta"
BUNDLE=$(ls -d "$BINDIR"/Vesta_vesta.bundle 2>/dev/null | head -1)
[ -x "$BIN" ] || { echo "no binary at $BIN"; exit 1; }
[ -d "$BUNDLE" ] || { echo "no resource bundle next to binary"; exit 1; }

echo ">> compiling app icon..."
ICONOUT=$(mktemp -d)
# Prefer the Icon Composer document (AppIcon.icon) — actool renders its
# liquid-glass treatment to AppIcon.icns + Assets.car. Fall back to the SVG.
if [ -d AppIcon.icon ] && xcrun actool AppIcon.icon --compile "$ICONOUT" --app-icon AppIcon \
     --platform macosx --minimum-deployment-target 26.0 \
     --output-partial-info-plist "$ICONOUT/icon.plist" >/dev/null 2>&1 && [ -f "$ICONOUT/AppIcon.icns" ]; then
  echo ">> rendered AppIcon.icon (Icon Composer)"
else
  echo "  WARN: actool failed; rendering icon from assets/vesta-logo.svg"
  ICONSET=$(mktemp -d)/Vesta.iconset; mkdir -p "$ICONSET"
  qlmanage -t -s 1024 -o /tmp assets/vesta-logo.svg >/dev/null 2>&1
  SRC=/tmp/vesta-logo.svg.png
  for s in 16 32 128 256 512; do
    sips -z $s $s          "$SRC" --out "$ICONSET/icon_${s}x${s}.png"      >/dev/null
    sips -z $((s*2)) $((s*2)) "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICONOUT/AppIcon.icns"
fi

echo ">> assembling ${APP}..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "$BIN" "${APP}/Contents/MacOS/Vesta"
# Mux helpers (Milestone 3): the daemon + the per-pane relay. They live beside
# the main binary so muxHelperPath() resolves them via Bundle.main.executableURL.
cp "$BINDIR/vestad"        "${APP}/Contents/MacOS/vestad"
cp "$BINDIR/vesta-attach"  "${APP}/Contents/MacOS/vesta-attach"
# Resource bundle as DATA in Resources (Bundle.module also searches Bundle.main.resourceURL),
# so codesign doesn't treat it as unsigned nested code.
cp -R "$BUNDLE" "${APP}/Contents/Resources/"
cp "$ICONOUT/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
# NOTE: we deliberately do NOT ship Assets.car. On macOS 26 (Tahoe) Finder would
# prefer its liquid-glass icon variant (via CFBundleIconName), but the Icon
# Composer source composes the whole logo with a lighten/translucent blend that
# renders washed-out with a white border. The flat AppIcon.icns (the dark tile +
# white flame) is the intended look, so we use only that (CFBundleIconFile).
# Legal: ship the license + third-party attribution inside the bundle.
cp LICENSE "${APP}/Contents/Resources/LICENSE" 2>/dev/null || true
cp NOTICE  "${APP}/Contents/Resources/NOTICE"  2>/dev/null || true

# ghostty's resources dir (themes/, for `theme = <name>` color sync). A Finder
# launch doesn't inherit $GHOSTTY_RESOURCES_DIR, so bundle Vesta's own vendored
# copy (Resources/ghostty, committed to the repo). GhosttyApp points
# GHOSTTY_RESOURCES_DIR at this bundled dir — no installed Ghostty required.
GRES="Resources/ghostty"
[ -d "$GRES/themes" ] || GRES="${GHOSTTY_RESOURCES_DIR:-/Applications/Ghostty.app/Contents/Resources/ghostty}"
if [ -d "$GRES/themes" ]; then
  cp -R "$GRES" "${APP}/Contents/Resources/ghostty"
  echo ">> bundled ghostty resources (themes) from $GRES"
else
  echo "  WARN: no ghostty resources at $GRES — named themes won't resolve in the bundle"
fi

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Vesta</string>
  <key>CFBundleDisplayName</key>     <string>Vesta</string>
  <key>CFBundleExecutable</key>      <string>Vesta</string>
  <key>CFBundleIdentifier</key>      <string>io.github.notnaki.vesta</string>
  <key>CFBundleIconFile</key>        <string>AppIcon</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>__VERSION__</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSPrincipalClass</key>        <string>NSApplication</string>
  <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
  <!-- open a folder in Vesta: "Open With", `open -a Vesta <dir>`, drag-to-icon -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>      <string>Folder</string>
      <key>CFBundleTypeRole</key>      <string>Viewer</string>
      <key>LSHandlerRank</key>         <string>Alternate</string>
      <key>LSItemContentTypes</key>    <array><string>public.folder</string></array>
    </dict>
  </array>
  <!-- Finder right-click > Services > New Vesta Session Here -->
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key>   <dict><key>default</key><string>New Vesta Session Here</string></dict>
      <key>NSMessage</key>    <string>newSessionHere</string>
      <key>NSPortName</key>   <string>Vesta</string>
      <key>NSSendFileTypes</key> <array><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
sed -i '' "s/__VERSION__/$VERSION/" "${APP}/Contents/Info.plist"
echo ">> bundle version $VERSION"

# Sign the executable then the wrapper (no --deep — the resource bundle is data).
# SIGN_ID set (e.g. "Developer ID Application: Name (TEAMID)") → real signing with
# Hardened Runtime + entitlements (required for notarization). Else ad-hoc.
ENT="$(dirname "$0")/Vesta.entitlements"
if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --options runtime --timestamp --entitlements "$ENT" \
    --sign "$SIGN_ID" "${APP}/Contents/MacOS/Vesta"
  codesign --force --options runtime --timestamp --entitlements "$ENT" \
    --sign "$SIGN_ID" "${APP}/Contents/MacOS/vestad"
  codesign --force --options runtime --timestamp --entitlements "$ENT" \
    --sign "$SIGN_ID" "${APP}/Contents/MacOS/vesta-attach"
  codesign --force --options runtime --timestamp --entitlements "$ENT" \
    --sign "$SIGN_ID" "${APP}"
  echo "OK: signed with Developer ID ($SIGN_ID)"
else
  codesign --force --sign - "${APP}/Contents/MacOS/Vesta" >/dev/null 2>&1 || true
  codesign --force --sign - "${APP}/Contents/MacOS/vestad" >/dev/null 2>&1 || true
  codesign --force --sign - "${APP}/Contents/MacOS/vesta-attach" >/dev/null 2>&1 || true
  codesign --force --sign - "${APP}" >/dev/null 2>&1 && echo "OK: signed (ad-hoc)" || echo "  (codesign skipped)"
fi

echo "OK: built $APP — open with: open ${APP}"
