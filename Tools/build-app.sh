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
cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>VideoCut++</string>
  <key>CFBundleDisplayName</key><string>VideoCut++</string>
  <key>CFBundleExecutable</key><string>VideoCut</string>
  <key>CFBundleIdentifier</key><string>com.videocutplusplus.desktop</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
printf '%s\n' "$PWD/$bundle"
