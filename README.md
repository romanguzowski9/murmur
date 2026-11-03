# Murmur

Murmur is a free, open-source dictation and meeting-notes app for the Mac menu bar, in the spirit of Wispr Flow.

- **Dictation anywhere.** Hold **fn**, speak, let go: clean, formatted text is pasted where you type. Murmur detects
  English, Polish and Russian (or your own language list) and transcribes with Whisper running on your Mac.
- **Meeting notes.** It notices calls in Teams, Meet, Zoom, WhatsApp, FaceTime and others, and transcribes both
  sides. When the call ends, it writes a summary with topics, decisions and tasks, and tells the speakers apart.
- **Your library.** A window with your meetings, tasks and dictation history. Claude can read it through MCP.
- **Private by default.** Speech recognition runs on your Mac. Only summaries and the optional formatting pass use
  Claude, with your own API key.

It's an independent implementation and doesn't use any Wispr code, servers or prompts.

## Install

Requires macOS 15 or later, on Apple silicon or Intel.

Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/romanguzowski9/murmur/main/install.sh | bash
```

The installer:
1. Puts the latest Murmur into **Applications**. Whisper (whisper.cpp) is built in, so Homebrew isn't needed.
2. Downloads the Whisper speech models once (1.7 GB, from Hugging Face).
3. Walks you through creating a **Claude API key** for meeting summaries. It opens the Anthropic Console, checks
   the key you paste, and saves it in Murmur's settings. You can press Return to skip this.
4. Starts Murmur.

To update, run the same command again; models and key are kept. Your notes and settings stay in
`~/Library/Application Support/Murmur`. `MURMUR_SKIP_MODELS=1` or `MURMUR_SKIP_KEY=1` before `bash` skips a step.

<details>
<summary>Install by hand instead</summary>

1. Download `Murmur-<version>.zip` from the [latest release](https://github.com/romanguzowski9/murmur/releases/latest).
2. Unzip it and move **Murmur.app** to Applications.
3. Murmur isn't signed with an Apple Developer ID, so the first time macOS blocks it. Open **System Settings →
   Privacy & Security** and click **Open Anyway**. Or run `xattr -dr com.apple.quarantine /Applications/Murmur.app`.

</details>

### First launch

1. Murmur lives in the menu bar (the waveform icon).
2. Allow **Microphone**, **Speech Recognition** and **Accessibility**. Accessibility is needed for the fn key and for
   pasting. For meeting notes, also allow **Screen & System Audio Recording**; that's how Murmur hears the call.
3. If fn opens the emoji picker, set System Settings → Keyboard → "Press 🌐 key to" → *Do Nothing*, or choose
   another key in the menu.
4. **Whisper.** If you skipped the model download, Murmur uses Apple's speech recognition and offers the download
   later (menu › Speech recognition).
5. **Claude key.** If you skipped it, add one later with menu › *Add Claude API key…*. To get one, sign in at
   [console.anthropic.com](https://console.anthropic.com), add credit under Billing (from $5; a Claude.ai
   subscription doesn't cover API use), then create a key under API Keys. An hour-long meeting costs about $0.04.
   Without a key, Murmur writes a simpler offline summary.

*Check for updates…* in the menu tells you when a new version is out.

## Build from source

You need Xcode (or its Command Line Tools) with the macOS 26 SDK or later.

```bash
./scripts/build_app.sh
```

```bash
open build/Murmur.app
```

`./scripts/build_app.sh --install` replaces `~/Applications/Murmur.app`. Local builds use Homebrew's
`whisper-cpp`. To bundle whisper.cpp like releases do, install `cmake` and run `./scripts/build_whisper.sh` first. Run the tests with
`swift build -c release && .build/release/murmur-cli test`.

### Releasing

1. Put the new version in `VERSION` and commit.
2. Run `./scripts/release.sh`. It runs the tests, then tags `v<version>` and pushes it.
3. GitHub Actions (`.github/workflows/release.yml`) does the rest:
   - builds whisper.cpp 1.9.5 as one self-contained universal binary (`scripts/build_whisper.sh`);
   - builds the universal app and zips it (`scripts/package.sh`);
   - publishes the release.

   It takes about 10 minutes. To build the zip without releasing, run the workflow by hand from the Actions tab.

The app is signed ad hoc with a fixed identifier, so macOS keeps users' permissions across updates. To sign with an
Apple Developer ID and notarize, set `SIGN_IDENTITY` (and `NOTARY_PROFILE`, a `notarytool` keychain profile) before
packaging (`scripts/package.sh`); in GitHub Actions they'd come from repository secrets.

## How it compares with Wispr Flow

| Wispr Flow | Murmur |
|---|---|
| Cloud speech recognition | Whisper large-v3-turbo through whisper.cpp on your Mac; Apple Speech as the fallback |
| Server-side formatting model | Local rules engine (`MurmurCore/Formatter.swift`), plus an optional Claude pass (`Prompts.swift`) |
| Styles per Personal / Work / Email / Other | Same four categories and four styles (Formal, Casual, Very casual, Excited) |
| Auto Cleanup: None / Light / Medium / High | Same levels |
| Smart formatting: fillers, backtrack, lists, email | Same rules, plus spoken commands ("new line", "question mark") |
| Dictionary and snippets | `dictionary` / `snippets` in config.json, plus words learned from your corrections |
| Push-to-talk, double-tap hands-free, Command Mode, Esc | Hold **fn**, double-tap fn, **fn+⌃**, Esc |
| Meeting notes with speakers | Same, with summaries written by Claude on your own key |

## Speech recognition: local Whisper

The final text comes from **Whisper large-v3-turbo**, run by whisper.cpp on the Mac (Metal GPU). No audio leaves the
computer. Apple's recognizer runs alongside it as the fallback.
1. While you hold the key, the audio is recorded with long pauses trimmed.
2. A small Whisper model (`ggml-base.bin`) picks the language from your list in about 0.15 s.
3. The large model transcribes in that language, with its window fitted to the recording.
4. That takes about 0.5–1 s, instead of about 1.3 s with the full window, or 2.5–5 s when it has to detect the
   language itself.
5. If Whisper isn't running, returns nothing, or returns text known to be invented for silence
   ("Napisy stworzone przez społeczność Amara.org"…), Apple's text is used. If Whisper returns far fewer words than
   Apple heard, it tries once more with the full window.
6. Meeting notes are transcribed the same way, passage by passage.

Setup:
- Install the program with `brew install whisper-cpp`.
- Put `ggml-large-v3-turbo.bin` (1.6 GB) and `ggml-base.bin` (148 MB) from huggingface.co/ggerganov/whisper.cpp in
  `~/Library/Application Support/Murmur/Models/`.
- Murmur starts `whisper-server` on 127.0.0.1:8178 and 8180, and stops it when it quits. The large model uses
  about 1.8 GB of RAM.
- Switch between Whisper and Apple in the menu under *Speech recognition*.

No dictionary prompt is sent to Whisper. In tests it made Polish output worse, because Whisper copies the prompt's
style. The dictionary rules fix spellings afterwards instead.

To check it on audio files:

```bash
open -n -W Murmur.app --args --selftest out.json a.wav b.wav
```

Add `--apple` to the same command to compare with Apple's recognizer alone.

## Languages (automatic detection)

Tick several languages under **Languages (auto-detect)** in the menu, or set `"languages": ["en-US", "pl-PL", "ru-RU"]`.
Apple's speech service handles only one recognition stream per app at a time, so detection is sequential:
the live pass uses the last detected language. If that result isn't confidently in that language,
the recorded audio is re-run in the other languages and the best match is kept. The score combines recognizer
confidence, a language-ID check on the text, and how much of the audio each recognizer covered.
This adds roughly 0.2–1.2 s when the language changes.
To check detection on audio files: `open -n -W build/Murmur.app --args [--all] --selftest out.json clip1.aiff clip2.aiff`.

## Meeting notes

When Teams, WhatsApp, Zoom or FaceTime, or a browser showing Google Meet, Teams or WhatsApp, uses the microphone
for more than about 5 seconds, Murmur starts transcribing. It detects this from Core Audio's list of processes
capturing input, plus window titles for browsers.
- It records the call audio as **Others** (ScreenCaptureKit, Murmur's own sounds excluded) and your microphone as **Me**.
- Speech is split at pauses and transcribed with the same language detection as dictation.
- Mic text that only repeats the call audio (no headphones) is dropped.
- **Speakers.** Like Wispr Flow, Murmur tells the other people on the call apart. When the meeting ends, the
  call audio's passages are grouped by voice into **Speaker 1**, **Speaker 2**… The grouping uses on-device voice
  prints: spectrum shape (MFCCs) plus each person's microphone and connection (`Diarization.swift`). Then names go on
  the labels:
  - **From the call app.** While recording, Murmur reads the call app through Accessibility every 1.5 s. It reads
    Teams video tiles ("Maria Nowak, muted"), roster items, the active-speaker marker, and the name on a
    WhatsApp/FaceTime call window (`CallObserver.swift`, `CallRoster.swift`). This is read-only. People seen are
    written as a `Participants:` line. A speaker is named after whoever the app showed as speaking while they talked.
    In a call with one other person, that person's name is used.
  - **From the conversation.** When Claude writes the summary, it names speakers who are clearly addressed or
    introduce themselves.
  - **By you.** The meeting page shows the speakers as chips. Click one to pick a participant, type a name, or mark it
    as the same person as another speaker. The transcript and summary are rewritten, and ⌘Z undoes it.
  - Measured against Wispr's own speaker labels on three of your recorded meetings: 92–96% of call speech landed with
    the right person (`murmur-cli diarize-eval`). Meetings recorded before this have no voice prints, so their call
    audio stays "Others".
- When the call app releases the microphone for about 12 seconds, Murmur finishes the transcript and **always** writes
  a summary. The prompt is `MeetingSummarizer.system` in `Meeting.swift`, and the summary has these sections:
  - Overview
  - Key discussion points
  - Decisions
  - Action items, as an `| Action | Owner | Deadline |` table that uses "Not specified." where the meeting didn't say
  - Open questions and blockers
- Action-item table rows and `- [ ]` checkbox bullets both become tasks in the Tasks tab, the Ask Claude chat and
  the `list_tasks` tool. Ticking a table row writes `[x]` in front of its action.
- The summary prompt follows Wispr Flow's notes: what the meeting was about and its outcome, one subheading per
  topic, decisions, next steps with owners, and speaker names. Before it is sent, recognition noise is removed:
  fillers, text in a script nobody speaks, short wrong-language fragments Whisper invents, and repetition loops.
  Claude is told the transcript is multilingual speech recognition, so it should fix misheard names and skip
  nonsense rather than quote it.
- Add the key with *Add Claude API key…* in the menu, or with *Add key & rewrite* on any offline summary.
- The summary is written by Claude when a key is set. Otherwise Apple's on-device model writes it, if it's ready and
  supports the meeting's language (English only for now). If neither is available, or the AI fails or returns an
  incomplete answer, the built-in offline summarizer writes it. That one picks out decisions, open questions,
  commitments, owners and due dates from cue phrases in English, Polish and Russian.
- Each meeting is titled after its topic, and the notes file is renamed to match. The AI writes the title when
  it writes the summary (for example "Acme transit delays and GPS tracking"). Without AI, Murmur builds a
  keyword title from the meeting's most distinctive repeated phrases, compared against your other meetings
  (for example "Wartość towaru, konwencji CMR & tysięcy"). Meetings with too little speech keep the app name.
  *Rename…* in the meeting's ⋯ menu sets a title by hand, and *Regenerate title & summary* redoes both.
- A meeting with no speech still gets notes that say so. If Murmur quits during a meeting, it summarizes what it has.
  After a crash, unfinished notes are summarized on the next launch.
- Notes are saved as Markdown in `~/Library/Application Support/Murmur/Meetings/` as the meeting goes,
  and open when the summary is ready.
- You can also start or stop notes from the menu.

This needs **Screen Recording** permission. Let other participants know you're transcribing the call.
To test without a call: `open -n -W --stdout out.txt build/Murmur.app --args --meeting-selftest a.aiff b.aiff ...`

## The Murmur bar

A small capsule sits at the bottom of the screen. It never takes focus from the app you're typing in, and clicks
pass through it except on the capsule itself.
- **Moving it:** drag it and it snaps to the nearest of three spots (middle of the left edge, bottom centre, middle of the right edge). The spot is remembered.
- **On hover:** a quick menu opens: *Meeting* (start or stop notes), *Voice note*, *Dictate* (hands-free),
  *Paste last*, *Murmur* (open the window).
- **While dictating:** a pulsing red dot and "Murmur recording", then a grey "Murmur" while the text is prepared.
- **Voice note:** stop and discard buttons. The transcript is saved with your notes, titled and summarized, and
  its tasks go to Tasks.
- **When any app starts a voice call:** for example Teams, Meet or another browser call, WhatsApp, Phone, FaceTime,
  Zoom, Slack, WeChat or Telegram. The bar shows the app's icon with **Record meeting? Yes / No**. No answer within
  30 seconds means no, and Murmur won't ask again during that call.
- **While a meeting is recorded:** the bar shows the app and a running timer.
- **Menu-bar toggles:** *Show the Murmur bar*, *Notice calls in any app*, and *Ask before recording a call*. Turn
  the last one off to start recording without asking.

## The Murmur window

Murmur opens a window at launch. You can reopen it from the menu bar (*Open Murmur…*) or by opening the app again.
- **Home:** this week's stats, open tasks, recent meetings and dictations.
- **Meetings:** every meeting with its summary and a searchable transcript. *Ask Claude* focuses a chat on that meeting.
  The ⋯ menu copies, regenerates the summary, or shows the file.
- **Tasks:** the next actions from all summaries, filterable by open, done and mine. Ticking a box writes `[x]` into
  the meeting notes.
- **Sharing:** every task has five buttons: copy, email, WhatsApp, Teams and calendar. Tick the checkboxes (or
  *Select all* for a meeting) to share several tasks at once from the bar at the top. Messages are written in the
  language of the meeting's transcript (Polish, Russian or English):
  - **Copy:** the task list, one "• task (termin: …)" line per task.
  - **Email:** "Cześć, proszę pamiętajcie, aby: • … Pozdrawiam, Anna", with subject "Przypomnienie: …".
  - **WhatsApp:** copies "Hej, proszę pamiętaj, aby: • …", opens WhatsApp and presses ⌘N (New Chat). Pick a contact
    and paste.
  - **Teams:** opens a new chat with that message already typed in. Pick the recipient.
  - **Calendar:** one event in the default calendar app, listing the tasks. It goes on the earliest readable
    deadline, otherwise the next working day at 10:00.
  - **Meetings:** each has an *Email summary* button that opens a formatted summary email.
  - Nothing is sent automatically.
- **Dictations:** your dictation history, searchable.
- **Dictionary:** words Murmur listens for. You can add or remove them; learned words are marked.
- **Ask Claude:** chat about your notes. This needs an API key, which you can paste here. Without a key, use the
  Claude app (see below).

`open Murmur.app --args --open Tasks` (or a meeting id) opens the window at that page.
The app icon is drawn by `swift scripts/make_icon.swift`, which writes `Resources/AppIcon.icns`.

## Claude access (MCP)

`Murmur.app/Contents/MacOS/murmur-mcp` is an MCP server. To use it, choose *Connect to Claude…* in the menu. That
registers it as `murmur` for the Claude desktop app (`claude_desktop_config.json`) and Claude Code
(`~/.claude.json`), after backing up each file once. It gives Claude these tools:
- `list_meetings`
- `get_meeting` (summary and transcript)
- `search` (meetings and dictations)
- `list_tasks`
- `set_task_done`
- `list_dictations`

Restart Claude after installing, then ask things like "Using Murmur, what are my open tasks?"

## Importing from Wispr Flow

Quit Murmur first, so it can't overwrite the updated dictionary. Then run:

```bash
.build/debug/murmur-cli import-wispr
```

This reads a copy of Wispr Flow's local database (`~/Library/Application Support/Wispr Flow/flow.sqlite`) and
its `meetings/` folder. Wispr itself is never changed. It imports:
- Dictionary words, correction rules and snippets, merged into config.json.
- Dictation history, appended to history.jsonl.
- Every meeting, as Murmur notes. Each keeps Wispr's title, its summary (speaker tags become names, and owned next
  steps become task checkboxes) and the refined transcript with speaker names. Your own voice is "Me".
  Meetings that Wispr never summarized get Murmur's offline summary.

Running it again adds only what is new. `--force` rewrites meetings imported before, which clears any tasks you ticked.

## Learning from your corrections

After a dictation is pasted, Murmur watches that text field for two minutes. If you replace a dictated word,
by typing or by accepting the keyboard's autocorrection, Murmur saves the new spelling to the dictionary
with the misheard form as a misspelling. Next time the recognizer is biased towards the new spelling,
and the misheard form is replaced automatically. Only unusual words are learned: names, jargon, odd casing,
and words the system spell checker doesn't know. Learned words are listed in the menu, where you can remove them.

## Configure

Edit `~/Library/Application Support/Murmur/config.json` (menu → *Edit config…*, then *Reload config*):

```json
{
  "llm": { "enabled": true, "model": "claude-sonnet-5-5", "apiKey": "sk-ant-..." },
  "dictionary": [ { "word": "Acme Cargo", "misspellings": ["acme cargo"], "starred": true } ],
  "snippets": [ { "trigger": "my calendar link", "expansion": "https://cal.com/you" } ]
}
```

Without an API key, Murmur uses only the local rules engine. Command Mode and Polish need the key.
History is saved to `history.jsonl` in the same folder.

## Tests

```bash
swift build -c release --product murmur-cli && .build/release/murmur-cli test
```

```bash
.build/release/murmur-cli format --category email --style formal "hi Alex um thanks for the call. best Mary"
```
