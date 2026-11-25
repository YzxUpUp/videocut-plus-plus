#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --arch arm64 -c release
release_dir="$(swift build --arch arm64 -c release --show-bin-path)"
bundle="dist/VideoCut++.app"
contents="$bundle/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
install -m 755 "$release_dir/VideoCut" "$contents/MacOS/VideoCut"
install -m 644 Tools/watermark.py Tools/setup.sh "$contents/Resources"
iconset=".build/VideoCut.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  double_size=$((size * 2))
  sips -z "$size" "$size" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$double_size" "$double_size" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$contents/Resources/AppIcon.icns"
cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>VideoCut++</string>
  <key>CFBundleDisplayName</key><string>VideoCut++</string>
  <key>CFBundleExecutable</key><string>VideoCut</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundleIdentifier</key><string>com.videocutplusplus.desktop</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.3.1</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
printf '%s\n' "$PWD/$bundle"
