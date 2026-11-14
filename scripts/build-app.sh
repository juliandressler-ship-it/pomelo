#!/bin/bash
set -euo pipefail
# 0.1.11: offline PDF editing and PDF actions on the Shift wheel.
cd "$(dirname "$0")/.."
# Ausgabe in "dist.noindex": Spotlight und Launchpad zeigen diese Bau-Kopie nicht an
app="$PWD/dist.noindex/Pomelo.app"
module_cache="$PWD/.build/module-cache"
mkdir -p "$app/Contents/MacOS" "$module_cache" "$PWD/.build"

# macOS 15 (Sequoia) is the minimum supported release. Intel (x86_64) builds are
# first-class; set BUILD_UNIVERSAL=1 to produce one app for Intel and Apple silicon.
MIN_MACOS="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
if [[ "${BUILD_UNIVERSAL:-0}" == "1" || "${ARCHS:-}" == "universal" ]]; then
  archs=(x86_64 arm64)
else
  read -r -a archs <<< "${ARCHS:-$(uname -m)}"
fi

binaries=()
for arch in "${archs[@]}"; do
  binary="$PWD/.build/Pomelo-$arch"
  find NativeApp/Sources -name '*.swift' -print0 | xargs -0 xcrun swiftc \
    -swift-version 5 -O -parse-as-library \
    -target "$arch-apple-macosx$MIN_MACOS" \
    -module-cache-path "$module_cache" \
    -o "$binary"
  binaries+=("$binary")
done

if (( ${#binaries[@]} > 1 )); then
  xcrun lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/Pomelo"
else
  cp "${binaries[0]}" "$app/Contents/MacOS/Pomelo"
fi
chmod +x "$app/Contents/MacOS/Pomelo"

# Eigene Kennung für die überarbeitete Fassung "Pomelo" (Einstellungen werden beim ersten Start übernommen).
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Pomelo</string>
<key>CFBundleIdentifier</key><string>de.juliandressler.pomelo</string>
<key>CFBundleName</key><string>Pomelo</string>
<key>CFBundleDisplayName</key><string>Pomelo</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.11</string>
<key>CFBundleVersion</key><string>12</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Pomelo reads the files you selected in Finder when you press the Finder shortcut. It does not change anything in Finder.</string>
</dict></plist>
PLIST
mkdir -p "$app/Contents/Resources"
xcrun swiftc -module-cache-path "$module_cache" NativeApp/Sources/UI/BrandArtwork.swift scripts/make-icon.swift -o .build/make-icon
.build/make-icon "$PWD/.build/AppIcon.iconset"
python3 scripts/package-icon.py .build/AppIcon.iconset "$app/Contents/Resources/AppIcon.icns"
python3 scripts/package-pdf-editor.py "$app/Contents/Resources/PDFEditor"
cp LICENSE "$app/Contents/Resources/GPL-3.0.txt"
cp NOTICE "$app/Contents/Resources/NOTICE.txt"
cp NativeApp/LICENSE "$app/Contents/Resources/Satsuma-MIT.txt"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
# Developer trials use ad-hoc signing. Developer ID + notarization is required for trusted public distribution.
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$app"
else
  codesign --force --sign - "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"
test -x "$app/Contents/MacOS/Pomelo"
plutil -lint "$app/Contents/Info.plist"
printf 'Built %s (%s, macOS %s+)\n' "$app" "$(xcrun lipo -archs "$app/Contents/MacOS/Pomelo")" "$MIN_MACOS"
