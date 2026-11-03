#!/bin/bash
# Installs or updates Murmur from its latest GitHub release:
#   curl -fsSL https://raw.githubusercontent.com/romanguzowski9/murmur/main/install.sh | bash
set -euo pipefail
REPO="${MURMUR_REPO:-romanguzowski9/murmur}"

if [[ "$(uname)" != "Darwin" ]]; then echo "Murmur runs on macOS only." >&2; exit 1; fi
major=$(sw_vers -productVersion | cut -d. -f1)
if (( major < 15 )); then echo "Murmur needs macOS 15 or later (this Mac has $(sw_vers -productVersion))." >&2; exit 1; fi

echo "Looking up the latest Murmur release…"
url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*Murmur-[^"]*\.zip"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/')
if [[ -z "$url" ]]; then echo "No release found at github.com/$REPO." >&2; exit 1; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Downloading $(basename "$url")…"
curl -fL --progress-bar "$url" -o "$tmp/Murmur.zip"
ditto -x -k "$tmp/Murmur.zip" "$tmp"

dest=/Applications
[[ -w "$dest" ]] || dest="$HOME/Applications"
mkdir -p "$dest"
if pgrep -f "$dest/Murmur.app/Contents/MacOS/Murmur" >/dev/null; then
  echo "Quitting the running Murmur…"
  osascript -e 'quit app "Murmur"' 2>/dev/null || pkill -f "$dest/Murmur.app/Contents/MacOS/Murmur" || true
  sleep 2
fi
rm -rf "$dest/Murmur.app"
ditto "$tmp/Murmur.app" "$dest/Murmur.app"
# Downloaded with curl, so macOS hasn't quarantined it; clear the flag in case it was set another way.
xattr -dr com.apple.quarantine "$dest/Murmur.app" 2>/dev/null || true
echo "Installed $dest/Murmur.app ($(defaults read "$dest/Murmur.app/Contents/Info" CFBundleShortVersionString))."

if ! command -v whisper-server >/dev/null && [[ ! -x /opt/homebrew/bin/whisper-server && ! -x /usr/local/bin/whisper-server ]]; then
  echo
  echo "Tip: for the best accuracy install whisper.cpp:  brew install whisper-cpp"
  echo "Murmur then offers to download its speech models. Until then it uses Apple's speech recognition."
fi
open "$dest/Murmur.app"
echo "Murmur is in your menu bar. Allow Microphone, Speech Recognition and Accessibility when macOS asks."
