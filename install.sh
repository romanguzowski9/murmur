#!/bin/bash
# Installs or updates Murmur from its latest GitHub release:
#   curl -fsSL https://raw.githubusercontent.com/romanguzowski9/murmur/main/install.sh | bash
#
# 1. Installs Murmur.app (with whisper.cpp built in) into Applications.
# 2. Downloads the Whisper speech models once (1.7 GB).        MURMUR_SKIP_MODELS=1 skips this.
# 3. Helps you create a Claude API key for meeting summaries. MURMUR_SKIP_KEY=1 skips this.
set -euo pipefail
REPO="${MURMUR_REPO:-romanguzowski9/murmur}"
SUPPORT="$HOME/Library/Application Support/Murmur"
CONFIG="$SUPPORT/config.json"
MODELS="$SUPPORT/Models"
MODEL_SOURCE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;35m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
# Questions read from the terminal, since this script itself arrives through a pipe.
has_tty() { [[ -t 1 ]] && { : </dev/tty; } 2>/dev/null; }
ask() { local answer; read -r -p "$1" answer </dev/tty || true; printf '%s' "$answer"; }

if [[ "$(uname)" != "Darwin" ]]; then echo "Murmur runs on macOS only." >&2; exit 1; fi
major=$(sw_vers -productVersion | cut -d. -f1)
if (( major < 15 )); then echo "Murmur needs macOS 15 or later (this Mac has $(sw_vers -productVersion))." >&2; exit 1; fi

# 1. The app ---------------------------------------------------------------------------------------------------
step "Installing Murmur"
url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*Murmur-[^"]*\.zip"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/')
if [[ -z "$url" ]]; then echo "No release found at github.com/$REPO." >&2; exit 1; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Downloading $(basename "$url")…"
curl -fL --progress-bar "$url" -o "$tmp/Murmur.zip"
ditto -x -k "$tmp/Murmur.zip" "$tmp"

dest=${MURMUR_DEST:-/Applications}
[[ -w "$dest" ]] || dest="$HOME/Applications"
mkdir -p "$dest"
for app in "/Applications/Murmur.app" "$HOME/Applications/Murmur.app"; do
  # Anchored: "/Applications/…" must not match "~/Applications/…".
  if pgrep -f "^$app/Contents/MacOS/Murmur" >/dev/null; then
    echo "Quitting the running Murmur…"
    # Quitting normally lets a meeting in progress be summarized first.
    osascript -e "tell application \"$app\" to quit" 2>/dev/null || pkill -f "^$app/Contents/MacOS/Murmur" || true
    sleep 3
  fi
done
rm -rf "$dest/Murmur.app"
ditto "$tmp/Murmur.app" "$dest/Murmur.app"
# Downloaded with curl, so macOS hasn't quarantined it; clear the flag in case it was set another way.
xattr -dr com.apple.quarantine "$dest/Murmur.app" 2>/dev/null || true
echo "Installed $dest/Murmur.app ($(defaults read "$dest/Murmur.app/Contents/Info" CFBundleShortVersionString))."

# 2. Speech recognition: whisper.cpp and its models --------------------------------------------------------------
if [[ ! -x "$dest/Murmur.app/Contents/MacOS/whisper-server" ]] && ! command -v whisper-server >/dev/null \
   && [[ ! -x /opt/homebrew/bin/whisper-server && ! -x /usr/local/bin/whisper-server ]]; then
  step "Installing whisper.cpp"
  if command -v brew >/dev/null; then
    brew install whisper-cpp
  else
    echo "This build doesn't include whisper.cpp and Homebrew isn't installed; Murmur will use Apple's speech"
    echo "recognition. For Whisper, install Homebrew (https://brew.sh), then run: brew install whisper-cpp"
  fi
fi

if [[ "${MURMUR_SKIP_MODELS:-}" != "1" ]]; then
  mkdir -p "$MODELS"
  for model in ggml-large-v3-turbo.bin:1624555275 ggml-base.bin:147951465; do
    name=${model%%:*}; size=${model##*:}
    have=$(stat -f %z "$MODELS/$name" 2>/dev/null || echo 0)
    [[ "$have" == "$size" ]] && continue
    step "Downloading the Whisper model $name ($((size / 1000000)) MB, once)"
    # Resumable: running the installer again continues an interrupted download.
    curl -fL --progress-bar -C - "$MODEL_SOURCE/$name" -o "$MODELS/$name.part"
    mv "$MODELS/$name.part" "$MODELS/$name"
  done
  echo "Speech models ready in $MODELS"
fi

# 3. Claude API key, for meeting summaries -----------------------------------------------------------------------
current_key=""
[[ -f "$CONFIG" ]] && current_key=$(plutil -extract llm.apiKey raw "$CONFIG" 2>/dev/null || true)

save_key() {
  mkdir -p "$SUPPORT"
  if [[ ! -f "$CONFIG" ]]; then
    (umask 077; printf '{"llm":{"apiKey":"%s","enabled":true}}\n' "$1" > "$CONFIG")
  elif plutil -extract llm json -o /dev/null "$CONFIG" 2>/dev/null; then
    plutil -replace llm.apiKey -string "$1" "$CONFIG"
    plutil -replace llm.enabled -bool YES "$CONFIG"
  else
    plutil -insert llm -json "{\"apiKey\":\"$1\",\"enabled\":true}" "$CONFIG"
  fi
  chmod 600 "$CONFIG"
}

# 200: the key works; 401: wrong key. Read-only request, free. The key goes to curl on stdin, not the command line.
check_key() {
  printf 'header = "x-api-key: %s"\nheader = "anthropic-version: 2023-06-01"\n' "$1" \
    | curl -s -o /dev/null -w '%{http_code}' -K - https://api.anthropic.com/v1/models || true
}

if [[ -z "$current_key" && "${MURMUR_SKIP_KEY:-}" != "1" ]] && has_tty; then
  step "Claude API key (optional, for meeting summaries)"
  cat <<'TEXT'
Murmur writes meeting summaries — topics, decisions, tasks, who said what — with Claude.
Dictation and transcription work without it, on your Mac.

To create a key:
  1. Sign in at console.anthropic.com (a Claude.ai subscription doesn't include API use;
     the Console is separate and pay-as-you-go).
  2. Settings → Billing: add credit (from $5). A one-hour meeting costs about $0.04.
  3. Settings → API Keys → Create Key, name it "Murmur", and copy it (it starts with sk-ant-).
The key is saved only on this Mac, in Murmur's settings (readable only by you).
TEXT
  echo
  if [[ "$(ask "Open the Anthropic Console in your browser now? [Y/n] ")" != [nN]* ]]; then
    open "https://console.anthropic.com/settings/keys"
  fi
  for attempt in 1 2 3; do
    echo
    read -r -s -p "Paste your API key and press Return (or just Return to skip): " key </dev/tty || key=""
    echo
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    [[ -z "$key" ]] && { echo "Skipped. Add it later from the Murmur menu › Add Claude API key…"; break; }
    if [[ "$key" != sk-ant-* ]]; then echo "That doesn't look like a Claude API key (they start with sk-ant-)."; continue; fi
    status=$(check_key "$key")
    case "$status" in
      200) save_key "$key"; bold "Key saved — meeting summaries will be written by Claude."; break ;;
      401|403) echo "Anthropic didn't accept that key. Check you copied all of it." ;;
      *) save_key "$key"; echo "Couldn't reach Anthropic to check the key (HTTP $status); saved it anyway."; break ;;
    esac
  done
elif [[ -n "$current_key" ]]; then
  echo
  echo "Claude API key: already set."
fi

# Done ----------------------------------------------------------------------------------------------------------
step "Starting Murmur"
[[ "${MURMUR_NO_OPEN:-}" == "1" ]] || open "$dest/Murmur.app"
cat <<'TEXT'
Murmur is in your menu bar (the waveform icon). When macOS asks, allow Microphone, Speech Recognition
and Accessibility; for meeting notes also Screen & System Audio Recording.
Hold fn and speak to dictate. To update later, run this installer again.
TEXT
