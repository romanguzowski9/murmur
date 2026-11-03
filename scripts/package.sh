#!/bin/zsh
# Builds the distributable zip: whisper.cpp's server (needs cmake), the universal app, and
# dist/Murmur-<VERSION>.zip with its SHA-256. Used by the release workflow; runs locally too.
#   SIGN_IDENTITY / NOTARY_PROFILE: see scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(tr -d '[:space:]' < VERSION)
if command -v cmake >/dev/null; then
  ./scripts/build_whisper.sh
else
  echo "cmake not found: the app will use Homebrew's whisper-cpp instead of a bundled one." >&2
fi
UNIVERSAL=1 ./scripts/build_app.sh
# Package from a folder outside iCloud Drive, without the Finder/iCloud attributes that break the signature.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto --norsrc --noextattr build/Murmur.app "$STAGE/Murmur.app"
codesign --verify --deep --strict "$STAGE/Murmur.app"
mkdir -p dist
ZIP="dist/Murmur-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --norsrc --noextattr --keepParent "$STAGE/Murmur.app" "$ZIP"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$STAGE/Murmur.app"
  rm -f "$ZIP" && ditto -c -k --norsrc --noextattr --keepParent "$STAGE/Murmur.app" "$ZIP"
fi
(cd dist && shasum -a 256 "Murmur-$VERSION.zip" > "Murmur-$VERSION.zip.sha256")
echo "Packaged $PWD/$ZIP"
