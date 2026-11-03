#!/bin/zsh
# Starts a release: checks, runs the tests, tags v<VERSION> and pushes. GitHub Actions
# (.github/workflows/release.yml) then builds whisper.cpp and the app and publishes the release.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(tr -d '[:space:]' < VERSION)
TAG="v$VERSION"
[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first." >&2; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "$TAG already exists: raise VERSION." >&2; exit 1; }
swift build -c release --product murmur-cli
.build/release/murmur-cli test > /dev/null || { echo "Tests failed: run .build/release/murmur-cli test" >&2; exit 1; }
git tag -a "$TAG" -m "Murmur $VERSION"
git push origin HEAD "$TAG"
REPO=$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
echo "Tagged $TAG. GitHub is building the release: https://github.com/$REPO/actions"
