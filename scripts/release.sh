#!/bin/zsh
# Publishes a release: tests, universal build, zip, tag v<VERSION>, GitHub release with the zip.
#   SIGN_IDENTITY="Developer ID Application: …"  sign with a Developer ID (default: ad hoc)
#   NOTARY_PROFILE=name                            notarize with this `xcrun notarytool store-credentials` profile
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(tr -d '[:space:]' < VERSION)
TAG="v$VERSION"

command -v gh >/dev/null || { echo "Install the GitHub CLI: brew install gh" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first." >&2; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "$TAG already exists: raise VERSION." >&2; exit 1; }

swift build -c release --product murmur-cli
.build/release/murmur-cli test > /dev/null || { echo "Tests failed: run .build/release/murmur-cli test" >&2; exit 1; }

UNIVERSAL=1 ./scripts/build_app.sh
# Package from a folder outside iCloud Drive, without the Finder/iCloud attributes that break the signature.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto --norsrc --noextattr build/Murmur.app "$STAGE/Murmur.app"
codesign --verify --deep --strict "$STAGE/Murmur.app"
mkdir -p dist
ZIP="dist/Murmur-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$STAGE/Murmur.app" "$ZIP"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$STAGE/Murmur.app"
  rm -f "$ZIP" && ditto -c -k --norsrc --noextattr --keepParent "$STAGE/Murmur.app" "$ZIP"
fi
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

git tag -a "$TAG" -m "Murmur $VERSION"
git push origin HEAD "$TAG"
REPO=$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
NOTES="Install or update: \`curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash\`"
gh release create "$TAG" "$ZIP" "$ZIP.sha256" --repo "$REPO" --title "Murmur $VERSION" --generate-notes --notes "$NOTES"
echo "Released $TAG"
