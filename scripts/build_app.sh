#!/bin/zsh
# Builds Murmur.app into ./build (release, ad-hoc signed).
#   UNIVERSAL=1      build for Apple silicon and Intel (releases do this)
#   SIGN_IDENTITY=…  sign with this certificate (e.g. "Developer ID Application: …") instead of ad hoc
set -euo pipefail
cd "$(dirname "$0")/.."
ARCHS=()
[[ "${UNIVERSAL:-}" == "1" ]] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" --product Murmur
swift build -c release "${ARCHS[@]}" --product murmur-mcp
BIN=$(swift build -c release "${ARCHS[@]}" --show-bin-path)
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
# "owner/repo" of the GitHub repository, for Check for updates.
REPOSITORY=${MURMUR_REPOSITORY:-$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##' || true)}
SIGN=${SIGN_IDENTITY:--}
APP=build/Murmur.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Icon drawn by scripts/make_icon.swift.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/Murmur" "$APP/Contents/MacOS/Murmur"
# The MCP server Claude launches to read meeting notes; signed on its own first, like any nested executable.
# whisper.cpp's server, when built by scripts/build_whisper.sh (releases); otherwise Murmur uses Homebrew's.
if [[ -x build/whisper/whisper-server ]]; then
  cp build/whisper/whisper-server "$APP/Contents/MacOS/whisper-server"
  if [[ "${SIGN_IDENTITY:--}" == "-" ]]; then
    codesign --force --sign - "$APP/Contents/MacOS/whisper-server"
  else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/whisper-server"
  fi
fi
cp "$BIN/murmur-mcp" "$APP/Contents/MacOS/murmur-mcp"
if [[ "$SIGN" == "-" ]]; then
  codesign --force --sign - "$APP/Contents/MacOS/murmur-mcp"
else
  codesign --force --options runtime --timestamp --sign "$SIGN" "$APP/Contents/MacOS/murmur-mcp"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.murmur.dictation</string>
  <key>CFBundleName</key><string>Murmur</string>
  <key>CFBundleExecutable</key><string>Murmur</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>MurmurRepository</key><string>$REPOSITORY</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Murmur listens while you hold the dictation key.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Murmur turns your speech into text.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Murmur transcribes the other side of your calls for meeting notes.</string>
</dict>
</plist>
PLIST
# iCloud Drive and Finder attach extended attributes that codesign refuses.
xattr -cr "$APP"
if [[ "$SIGN" == "-" ]]; then
  # Ad-hoc signature with an identifier-based requirement, so macOS keeps the Accessibility/Screen Recording
  # approval across updates (the default ad-hoc requirement is the exact binary hash, which changes every build).
  codesign --force --sign - -r='designated => identifier "local.murmur.dictation"' "$APP"
else
  # A real certificate: hardened runtime (needed for notarization) with microphone access.
  cat > build/entitlements.plist <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>
ENT
  codesign --force --options runtime --timestamp --entitlements build/entitlements.plist --sign "$SIGN" "$APP"
fi
echo "Built $PWD/$APP"

# --install: replace ~/Applications/Murmur.app, the copy you approve in Privacy & Security.
# macOS ties ad-hoc approvals to the exact build, so re-approve Accessibility after installing a new build.
if [[ "${1:-}" == "--install" ]]; then
  pkill -f "Applications/Murmur.app/Contents/MacOS/Murmur" || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/Murmur.app
  cp -R "$APP" ~/Applications/Murmur.app
  echo "Installed ~/Applications/Murmur.app"
fi
