import AppKit
import ApplicationServices
import MurmurCore

/// Menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func fire() { handler() }
}

/// The menu bar shown while Murmur's window is in front: the standard Murmur, Edit and Window menus, so ⌘Q, ⌘W,
/// ⌘Z, copy/paste and ⌘A work as in any Mac app.
func makeMainMenu() -> NSMenu {
    let main = NSMenu()
    func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        main.addItem(item)
        return item
    }
    func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }
    _ = submenu("Murmur", [
        item("About Murmur", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
        .separator(),
        item("Hide Murmur", #selector(NSApplication.hide(_:)), "h"),
        item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
        item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
        .separator(),
        item("Quit Murmur", #selector(NSApplication.terminate(_:)), "q"),
    ])
    _ = submenu("Edit", [
        item("Undo", Selector(("undo:")), "z"),
        item("Redo", Selector(("redo:")), "z", [.command, .shift]),
        .separator(),
        item("Cut", #selector(NSText.cut(_:)), "x"),
        item("Copy", #selector(NSText.copy(_:)), "c"),
        item("Paste", #selector(NSText.paste(_:)), "v"),
        item("Delete", #selector(NSText.delete(_:))),  // no ⌫ shortcut here: it would take Backspace from text fields
        item("Select All", #selector(NSText.selectAll(_:)), "a"),
    ])
    let window = submenu("Window", [
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        item("Close", #selector(NSWindow.performClose(_:)), "w"),
    ])
    NSApp.windowsMenu = window.submenu
    return main
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum Phase { case idle, recording, processing }

    private var config = ConfigStore.load()
    private let recorder = SpeechRecorder()
    private let overlay = Overlay()
    private var hotkeys: HotkeyMonitor?
    private var statusItem: NSStatusItem!

    private var phase = Phase.idle
    private var handsFree = false
    private var commandMode = false
    private var pressStart = Date()
    private var tapTimer: Timer?
    private var context = FocusContext()
    private var lastTranscript: String?

    private var llm: TextGenerator? { ClaudeClient(config: config.llm) }
    private var detectedLocale = ""

    private let watcher = CorrectionWatcher()
    private var meeting: MeetingRecorder?
    private var meetingTimer: Timer?
    private var meetingSeen = 0
    private var meetingGone = 0
    /// Meeting the user stopped by hand; not restarted until that call ends.
    private var dismissedMeeting: String?
    /// Call Murmur is asking about ("Record meeting?").
    private var askingAbout: String?
    /// The current recording is a voice note: saved to Murmur's notes instead of pasted.
    private var voiceNote = false
    private let mics = MicrophoneMonitor()
    /// Local Whisper (whisper.cpp) for the final text; Apple's recognizer still runs alongside as the fallback.
    private var whisper: WhisperServer?
    private var whisperLanguage: WhisperServer?
    private let downloader = ModelDownloader()
    private lazy var window = MainWindowController(actions: AppActions(
        config: { [unowned self] in self.config },
        updateConfig: { [unowned self] change in self.update(change) },
        meetingStatus: { [unowned self] in
            guard let meeting = self.meeting, !meeting.isFinished else { return nil }
            return "\(meeting.app == "Manual" ? "Meeting" : meeting.app) · \(meeting.minutes) min"
        },
        toggleMeeting: { [unowned self] in
            if let meeting = self.meeting, !meeting.isFinished { self.stopMeeting() } else { self.startMeeting(app: "Manual") }
        },
        resummarize: { [unowned self] note in await self.resummarize(note) }))

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.show()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would both react to the hotkey and fight over the mic and the overlay; the newest one wins.
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        where other != NSRunningApplication.current {
            other.terminate()
        }
        NSApp.mainMenu = makeMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        setIcon("mic")

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            overlay.show("Grant Accessibility access to Murmur, then relaunch it")
            overlay.hide(after: 6)
        }
        SpeechRecorder.requestPermissions { [weak self] granted in
            if !granted {
                self?.overlay.show("Murmur needs Microphone and Speech Recognition access")
                self?.overlay.hide(after: 6)
            }
        }
        // The recording pill shows no transcript while you speak.
        recorder.onPartial = { _ in }
        startHotkeys()
        overlay.model.onAction = { [weak self] action in self?.barAction(action) }

        watcher.onLearned = { [weak self] corrections in self?.learn(corrections) }
        mics.preference = config.microphone
        mics.onChange = { [weak self] picked in self?.microphoneChanged(to: picked) }
        mics.start()
        if config.meetings.autoDetect, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        startWhisper()
        WhisperSetup.suggestOnFirstLaunch(models: [config.whisperModel, config.whisperLanguageModel],
                                          engine: config.speechEngine) { [weak self] in
            self?.downloadModels(ModelDownloader.missing([self?.config.whisperModel ?? "", self?.config.whisperLanguageModel ?? ""]))
        }
        UpdateChecker.checkInBackground { [weak self] message in
            self?.overlay.show(message)
            self?.overlay.hide(after: 8)
        }
        recoverUnfinishedMeetings()
        meetingTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMeeting() }
        }
        // `--open <section or meeting id>` opens the window there (e.g. "Tasks", "Ask Claude").
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            let target = args[i + 1]
            if let section = Section(rawValue: target) { window.show(section: section) } else { window.show(meeting: target) }
        } else if !args.contains("--background") {
            window.show()
        }
    }

    private func startHotkeys() {
        hotkeys?.stop()
        let monitor = HotkeyMonitor(hotkey: config.hotkey)
        monitor.onDown = { [weak self] control in Task { @MainActor in self?.keyDown(control: control) } }
        monitor.onUp = { [weak self] in Task { @MainActor in self?.keyUp() } }
        monitor.onEscape = { [weak self] in Task { @MainActor in self?.cancel() } }
        monitor.start()
        hotkeys = monitor
    }

    // MARK: Bar

    private func barAction(_ action: BarAction) {
        switch action {
        case .toggleMeeting:
            if let meeting, !meeting.isFinished { stopMeeting() } else { startMeeting(app: "Manual") }
        case .voiceNote:
            guard phase == .idle else { return }
            voiceNote = true
            startRecording(command: false)
            handsFree = true
            showRecordingState()
        case .dictate:
            // Hands-free dictation into the app you were typing in; click stop (or tap fn) to finish.
            guard phase == .idle else { return }
            startRecording(command: false)
            handsFree = true
            showRecordingState()
        case .pasteLast:
            guard let text = lastTranscript else {
                overlay.show("Nothing dictated yet")
                overlay.hide(after: 1.5)
                return
            }
            context = FocusContext.capture()
            insert(text, raw: text, note: "repaste")
        case .openMurmur:
            window.show()
        case .stopRecording:
            if phase == .recording { finishRecording() }
        case .cancelRecording:
            cancel()
        }
    }

    private func showRecordingState() {
        overlay.showRecording(voiceNote ? "Voice note" : commandMode ? "Murmur command" : "Murmur recording",
                              stoppable: handsFree || voiceNote)
    }

    // MARK: Push-to-talk / hands-free state machine

    private func keyDown(control: Bool) {
        switch phase {
        case .processing:
            return
        case .recording:
            if handsFree {
                finishRecording()
            } else if tapTimer != nil {
                // Second tap within the window latches hands-free mode.
                tapTimer?.invalidate()
                tapTimer = nil
                handsFree = true
                showRecordingState()
            }
        case .idle:
            startRecording(command: control)
        }
    }

    private func keyUp() {
        guard phase == .recording, !handsFree, tapTimer == nil else { return }
        if Date().timeIntervalSince(pressStart) < 0.3 {
            // A quick tap: wait briefly for a second tap, otherwise discard.
            tapTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.tapTimer = nil
                    self?.cancel(silently: true)
                }
            }
        } else {
            finishRecording()
        }
    }

    private func startRecording(command: Bool) {
        watcher.stop()
        meeting?.yieldSpeech()
        context = FocusContext.capture()
        commandMode = command
        handsFree = false
        pressStart = Date()
        do {
            let words = config.dictionary.sorted { ($0.starred ?? false) && !($1.starred ?? false) }.map(\.word)
            try recorder.start(locales: config.languages, contextualStrings: words, device: mics.current?.id,
                               ready: { [weak self] in
                                   guard let self, self.phase == .recording else { return }
                                   if self.config.playSounds { NSSound(named: "Tink")?.play() }
                                   self.showRecordingState()
                               },
                               failed: { [weak self] error in
                                   guard let self, self.phase == .recording else { return }
                                   self.tapTimer?.invalidate()
                                   self.tapTimer = nil
                                   self.recorder.cancel()
                                   self.phase = .idle
                                   self.handsFree = false
                                   self.voiceNote = false
                                   self.setIcon("mic")
                                   self.overlay.show(error.localizedDescription)
                                   self.overlay.hide(after: 3)
                                   self.mics.refresh()
                               })
        } catch {
            overlay.show(error.localizedDescription)
            overlay.hide(after: 3)
            return
        }
        phase = .recording
        setIcon("mic.fill")
        showRecordingState()
    }

    private func cancel(silently: Bool = false) {
        tapTimer?.invalidate()
        tapTimer = nil
        guard phase == .recording else { return }
        recorder.cancel()
        phase = .idle
        handsFree = false
        voiceNote = false
        setIcon("mic")
        if silently {
            overlay.hide()
        } else {
            overlay.show("Cancelled")
            overlay.hide(after: 0.8)
        }
    }

    private func finishRecording() {
        phase = .processing
        handsFree = false
        setIcon("ellipsis.circle")
        if config.playSounds { NSSound(named: "Pop")?.play() }
        overlay.showWorking()
        recorder.stop { [weak self] raw, locale in
            Task { @MainActor in
                self?.detectedLocale = locale
                await self?.process(raw)
            }
        }
    }

    private func process(_ raw: String) async {
        defer {
            phase = .idle
            setIcon("mic")
        }
        let transcript = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNote = voiceNote
        voiceNote = false
        guard !transcript.isEmpty else {
            overlay.show("Didn't catch that")
            overlay.hide(after: 1)
            return
        }
        if isNote {
            await saveVoiceNote(transcript)
            return
        }

        if commandMode {
            guard let llm else {
                overlay.show("Command Mode needs a Claude API key (see config.json)")
                overlay.hide(after: 3)
                return
            }
            do {
                let output = try await Pipeline.command(instruction: transcript, selected: context.selectedText,
                                                        appName: context.appName, llm: llm)
                insert(output, raw: transcript, note: "command")
            } catch {
                overlay.show("Command failed: \(error)")
                overlay.hide(after: 3)
            }
            return
        }

        let category = AppClassifier.classify(bundleId: context.bundleId, windowTitle: context.windowTitle)
        let request = DictationRequest(raw: transcript, category: category, style: config.styles.style(for: category),
                                       cleanup: config.cleanup, dictionary: config.dictionary, snippets: config.snippets,
                                       language: String(detectedLocale.prefix(2)), appName: context.appName, beforeText: context.beforeText,
                                       selectedText: context.selectedText, afterText: context.afterText)
        let result = await Pipeline.dictate(request, llm: config.cleanup == .none ? nil : llm)
        insert(result.text, raw: transcript, note: "\(category.rawValue)/\(request.style.rawValue)"
            + (result.usedLLM ? "/llm" : "/local") + (result.error.map { " (\($0))" } ?? ""))
    }

    /// Saves a voice note with Murmur's notes (Meetings), titled and summarized like a meeting.
    private func saveVoiceNote(_ text: String) async {
        overlay.showWorking("Saving voice note")
        var note = MeetingTranscript(app: "Voice note", started: pressStart)
        note.add(TranscriptSegment(start: 0, speaker: .me, text: text, locale: detectedLocale))
        note.ended = Date()
        let corpus = await Task.detached(priority: .utility) { MurmurLibrary.topicCorpus() }.value
        let notes = await MeetingSummarizer.notesAlways(note, model: summaryModel(for: note.languages), corpus: corpus)
        note.summary = notes.summary
        // Short notes have no repeated topic words: name them after how they start.
        let opening = text.split(separator: " ").prefix(7).joined(separator: " ")
        note.title = notes.title ?? (opening + (text.wordCount > 7 ? "…" : ""))
        try? FileManager.default.createDirectory(at: ConfigStore.meetingsDirectory, withIntermediateDirectories: true)
        let url = MurmurLibrary.fileName(date: note.started, title: note.title ?? "Voice note")
        try? note.markdown.write(to: url, atomically: true, encoding: .utf8)
        overlay.show("Voice note saved — Murmur ▸ Meetings")
        overlay.hide(after: 2.5)
    }

    private func insert(_ text: String, raw: String, note: String) {
        lastTranscript = text
        guard AXIsProcessTrusted() else {
            // Without Accessibility, macOS silently drops the synthetic ⌘V; leave the text on the clipboard instead.
            Paster.copy(text)
            overlay.show("Copied — press ⌘V. To paste automatically, switch Murmur on in Accessibility settings")
            overlay.hide(after: 5)
            appendHistory(raw: raw, text: text, note: note + " [no accessibility: copied]")
            openAccessibilitySettingsOnce()
            return
        }
        let ctx = context
        Paster.insert(text, into: ctx.element, allowDirectInsert: !ctx.isElectron,
                      restoreClipboard: config.restoreClipboard) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .verified, .unverified:
                self.overlay.hide()
                if self.config.autoLearnDictionary, let element = ctx.element {
                    self.watcher.watch(element: element, inserted: text, cursorHint: ctx.cursorLocation ?? 0,
                                       language: String(self.detectedLocale.prefix(2)))
                }
            case .failed:
                self.overlay.show("Couldn't paste into \(ctx.appName ?? "this app") — it's on the clipboard, press ⌘V")
                self.overlay.hide(after: 4)
            }
            self.appendHistory(raw: raw, text: text, note: note + " [paste: \(outcome)]")
        }
    }

    private var openedAccessibilitySettings = false

    private func openAccessibilitySettingsOnce() {
        guard !openedAccessibilitySettings,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        openedAccessibilitySettings = true
        NSWorkspace.shared.open(url)
    }

    // MARK: Microphone

    /// A headset was connected or removed, or the macOS input changed: use the new mic and say so.
    private func microphoneChanged(to picked: InputDevice?) {
        guard let picked else { return }
        if let meeting, !meeting.isFinished { meeting.switchMicrophone(to: picked.uid) }
        guard phase == .idle else { return }  // the next dictation picks it up
        overlay.show((picked.transport == .bluetooth ? "🎧 " : "🎙 ") + "Microphone: \(picked.name)")
        overlay.hide(after: 2.5)
    }

    // MARK: Learning corrections

    private func learn(_ corrections: [LearnedCorrection]) {
        let changed = CorrectionLearner.merge(corrections, into: &config.dictionary)
        guard !changed.isEmpty else { return }
        ConfigStore.save(config)
        overlay.show("Learned: " + changed.joined(separator: ", "))
        overlay.hide(after: 2)
    }

    // MARK: Meetings

    /// Core Audio and window-list queries run off the main thread so they never delay the hotkey.
    private func pollMeeting() {
        DispatchQueue.global(qos: .utility).async {
            let detected = MeetingDetector.detect()
            DispatchQueue.main.async { [weak self] in self?.checkForMeeting(detected) }
        }
    }

    private func checkForMeeting(_ call: DetectedCall?) {
        let detected = call?.name
        if let meeting, !meeting.isFinished {
            // End when the call app stops using the microphone for ~12 s (manual recordings end by hand).
            guard meeting.app != "Manual" else { return }
            meetingGone = detected == nil ? meetingGone + 1 : 0
            if meetingGone >= 3 { stopMeeting() }
            return
        }
        guard let call, let detected else {
            meetingSeen = 0
            dismissedMeeting = nil
            if askingAbout != nil { meetingGone += 1 } else { meetingGone = 0 }
            // The call ended while we were still asking.
            if askingAbout != nil, meetingGone >= 2 {
                askingAbout = nil
                overlay.hide()
            }
            return
        }
        meetingGone = 0
        guard config.meetings.autoDetect, dismissedMeeting != detected, askingAbout == nil else { return }
        meetingSeen += 1
        guard meetingSeen >= 2 else { return }  // ignore mic use shorter than ~5 s
        guard config.meetings.askBeforeRecording else { return startMeeting(app: detected, bundle: call.bundle) }
        askingAbout = detected
        overlay.showPrompt(app: detected, bundle: call.bundle) { [weak self] record in
            guard let self, self.askingAbout == detected else { return }
            self.askingAbout = nil
            if record {
                self.startMeeting(app: detected, bundle: call.bundle)
            } else {
                self.dismissedMeeting = detected  // not again for this call
            }
        }
    }

    /// - Parameter bundle: the call app, watched for participant names; for a manual recording, whichever app is in
    ///   a call at the time, if any.
    private func startMeeting(app: String, bundle: String? = nil) {
        meetingSeen = 0
        meetingGone = 0
        let words = config.dictionary.map(\.word)
        let recorder = MeetingRecorder(app: app, locales: config.languages, contextualStrings: words)
        recorder.whisper = whisper
        recorder.whisperLanguage = whisperLanguage
        recorder.callBundle = bundle ?? MeetingDetector.detect()?.bundle
        recorder.isSpeechBusy = { [weak self] in self?.phase != .idle }
        recorder.summarizer = { [weak self] languages in self?.summaryModel(for: languages) }
        recorder.onStatus = { [weak self] status in
            self?.overlay.show(status)
            self?.overlay.hide(after: 3)
        }
        recorder.onFinished = { [weak self] url in
            guard let self else { return }
            self.overlay.show("Meeting notes ready")
            self.overlay.hide(after: 3)
            if self.config.meetings.openWhenReady { self.window.show(meeting: url.deletingPathExtension().lastPathComponent) }
        }
        meeting = recorder
        Task { @MainActor in
            do {
                try await recorder.start(microphone: mics.current?.uid)
                // The bar shows the call and its running time; hover it to stop.
                overlay.setMeeting(MeetingBadge(name: app == "Manual" ? "Meeting" : app, started: Date()))
                overlay.hide()
            } catch {
                meeting = nil
                overlay.setMeeting(nil)
                overlay.show("Can't record the meeting: \(error.localizedDescription). Allow Screen Recording for Murmur.")
                overlay.hide(after: 6)
            }
        }
    }

    /// Claude when a key is set (with time for a long transcript), else Apple's on-device model when it is ready and
    /// supports the meeting's language; nil means the offline summarizer.
    private func summaryModel(for languages: [String]) -> (TextGenerator, Int)? {
        if config.llm.enabled, let key = config.llm.resolvedKey {
            return (ClaudeClient(apiKey: key, model: config.llm.model, timeout: 180, effort: "medium", maxTokens: 16_000), 150_000)
        }
        if #available(macOS 26, *), AppleIntelligenceGenerator.isAvailable(for: languages.first ?? "en") {
            return (AppleIntelligenceGenerator(), 5_000)
        }
        return nil
    }

    /// Rewrites a meeting's title and summary from its saved transcript (ticked tasks start over). The transcript
    /// itself, with its speaker names, is left as it is.
    private func resummarize(_ note: MeetingNote) async {
        guard let text = try? String(contentsOf: note.url, encoding: .utf8),
              var transcript = MeetingTranscript.parse(markdown: text, started: note.date,
                                                       ended: note.date.addingTimeInterval(Double(note.minutes) * 60))
        else { return }
        transcript.started = note.date
        let notes = await MeetingSummarizer.notesAlways(transcript, model: summaryModel(for: transcript.languages),
                                                        corpus: MurmurLibrary.topicCorpus(excluding: note.id))
        MurmurLibrary.renameSpeakers(note.url, notes.speakerNames)
        MurmurLibrary.rewrite(note.url, title: notes.title, summary: notes.summary)
    }

    /// Murmur's own notes from before titles existed get an offline title from their topic (no AI, no rewrite of
    /// the summary). Imported notes already have one.
    private func titleUntitledMeetings() {
        Task.detached(priority: .utility) {
            let notes = MurmurLibrary.meetings().filter { $0.customTitle == nil && !$0.inProgress && !$0.transcript.isEmpty }
            guard !notes.isEmpty else { return }
            let corpus = MurmurLibrary.topicCorpus()
            for note in notes {
                guard let t = MeetingTranscript.parse(markdown: note.markdown, started: note.date, ended: note.date),
                      let title = OfflineSummarizer.title(t, corpus: corpus) else { continue }
                MurmurLibrary.rewrite(note.url, title: title)
            }
        }
    }

    /// Notes left unfinished by a quit or crash get their summary on the next launch.
    private func recoverUnfinishedMeetings() {
        let dir = ConfigStore.meetingsDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey,
                                                                                                    .contentModificationDateKey])) ?? []
        for url in files where url.pathExtension == "md" && url != meeting?.fileURL {
            guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(MeetingTranscript.unfinishedMarker)
            else { continue }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let ended = values?.contentModificationDate ?? Date()
            guard var transcript = MeetingTranscript.parse(markdown: text, started: values?.creationDate ?? ended, ended: ended)
            else { continue }
            Task { @MainActor in
                let corpus = await Task.detached(priority: .utility) { MurmurLibrary.topicCorpus() }.value
                let notes = await MeetingSummarizer.notesAlways(transcript, model: summaryModel(for: transcript.languages),
                                                                corpus: corpus)
                transcript.summary = "_Recovered after Murmur stopped during the meeting._\n\n" + notes.summary
                transcript.title = notes.title
                transcript.rename(notes.speakerNames)
                try? transcript.markdown.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        titleUntitledMeetings()
    }

    func applicationWillTerminate(_ notification: Notification) {
        meeting?.finishNow()
        whisper?.stop()
        whisperLanguage?.stop()
    }

    private func startWhisper() {
        whisper?.stop()
        whisperLanguage?.stop()
        whisper = nil
        whisperLanguage = nil
        recorder.whisper = nil
        recorder.whisperLanguage = nil
        guard config.speechEngine == "whisper" else { return }
        let server = WhisperServer(model: config.whisperModel)
        server.start()
        let detector = WhisperServer(model: config.whisperLanguageModel, port: 8180)
        detector.start()
        whisper = server
        whisperLanguage = detector
        recorder.whisper = server
        recorder.whisperLanguage = detector
        meeting?.whisper = server
        meeting?.whisperLanguage = detector
    }

    private func downloadModels(_ models: [String]) {
        var shown = -1
        downloader.onProgress = { [weak self] p in
            let percent = Int(p * 100)
            guard percent / 10 != shown / 10 else { return }  // every 10%
            shown = percent
            self?.overlay.show("Downloading Whisper models… \(percent)%")
            self?.overlay.hide(after: 2)
        }
        downloader.onFinished = { [weak self] error in
            guard let self else { return }
            if let error {
                self.overlay.show("Model download stopped: \(error.localizedDescription)")
            } else {
                self.overlay.show(WhisperServer.program == nil
                                  ? "Models ready — now install whisper.cpp (Murmur menu › Speech recognition)"
                                  : "Whisper models ready")
                self.startWhisper()
            }
            self.overlay.hide(after: 5)
        }
        downloader.start(models)
        overlay.show("Downloading Whisper models (\(ModelDownloader.describe(models)))…")
        overlay.hide(after: 3)
    }

    private var whisperStatus: String {
        switch whisper?.state ?? .off {
        case .ready: return "ready"
        case .loading: return "loading…"
        case .missingProgram: return "not installed (brew install whisper-cpp)"
        case .missingModel: return "models not downloaded yet"
        case .failed(let why): return "stopped: \(why)"
        case .off: return "off"
        }
    }

    private func stopMeeting() {
        guard let meeting, !meeting.isFinished else { return }
        if meeting.app != "Manual", meetingGone < 3 { dismissedMeeting = meeting.app }
        meeting.stop()
        overlay.setMeeting(nil)
        overlay.show("Meeting ended — writing the notes…")
        overlay.hide(after: 3)
    }

    private func appendHistory(raw: String, text: String, note: String) {
        let entry: [String: String] = [
            "date": ISO8601DateFormatter().string(from: Date()), "app": context.appName ?? "", "bundleId":
                context.bundleId ?? "", "mode": note, "lang": detectedLocale, "raw": raw, "text": text,
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let url = ConfigStore.historyURL
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    // MARK: Polish selection

    private func polishSelection() {
        let ctx = FocusContext.capture()
        guard let selected = ctx.selectedText, !selected.isEmpty else {
            overlay.show("Select some text first")
            overlay.hide(after: 1.5)
            return
        }
        guard let llm else {
            overlay.show("Polish needs a Claude API key (see config.json)")
            overlay.hide(after: 3)
            return
        }
        let category = AppClassifier.classify(bundleId: ctx.bundleId, windowTitle: ctx.windowTitle)
        overlay.show("Polishing…")
        Task { @MainActor in
            do {
                let output = try await Pipeline.polish(selected, style: config.styles.style(for: category), llm: llm)
                context = ctx
                insert(output, raw: selected, note: "polish")
            } catch {
                overlay.show("Polish failed: \(error)")
                overlay.hide(after: 3)
            }
        }
    }

    // MARK: Menu

    private func setIcon(_ symbol: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Murmur")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func update(_ change: (inout MurmurConfig) -> Void) {
        change(&config)
        ConfigStore.save(config)
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuild(menu) }
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let keyName = ["fn": "fn", "rightOption": "right ⌥", "rightCommand": "right ⌘", "rightControl": "right ⌃"][
            config.hotkey] ?? config.hotkey
        let help = NSMenuItem(title: "Hold \(keyName) to dictate · double-tap for hands-free · +⌃ for Command Mode",
                              action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)
        menu.addItem(ActionItem("Open Murmur…") { [weak self] in self?.window.show() })
        let llmStatus = llm != nil ? "Claude formatting: on (\(config.llm.model))"
            : (config.llm.enabled ? "Claude formatting: no API key — local rules only" : "Claude formatting: off")
        let status = NSMenuItem(title: llmStatus, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let cleanup = NSMenu()
        for level in CleanupLevel.allCases {
            cleanup.addItem(ActionItem(level.title, checked: config.cleanup == level) { [weak self] in
                self?.update { $0.cleanup = level }
            })
        }
        addSubmenu(menu, "Auto cleanup", cleanup)

        let style = NSMenu()
        for (title, category) in [("Personal messages", AppCategory.personal), ("Work messages", .work),
                                  ("Email", .email), ("Other", .other)] {
            let sub = NSMenu()
            for s in WritingStyle.allCases where !(category == .email && s == .veryCasual) {
                sub.addItem(ActionItem(s.title, checked: config.styles.style(for: category) == s) { [weak self] in
                    self?.update { $0.styles.set(s, for: category) }
                })
            }
            addSubmenu(style, title, sub)
        }
        addSubmenu(menu, "Style", style)

        let languages = NSMenu()
        for (title, id) in [("English (US)", "en-US"), ("English (UK)", "en-GB"), ("Polski", "pl-PL"),
                            ("Русский", "ru-RU"), ("Deutsch", "de-DE"), ("Français", "fr-FR"), ("Español", "es-ES")] {
            languages.addItem(ActionItem(title, checked: config.languages.contains(id)) { [weak self] in
                self?.update { config in
                    if let i = config.languages.firstIndex(of: id) {
                        if config.languages.count > 1 { config.languages.remove(at: i) }
                    } else {
                        config.languages.append(id)
                    }
                }
            })
        }
        addSubmenu(menu, "Languages (auto-detect)", languages)

        let micMenu = NSMenu()
        let auto = config.microphone == MicrophonePicker.automatic
        micMenu.addItem(ActionItem("Automatic — headset, else macOS input" + (auto ? (mics.current.map { " (now: \($0.name))" } ?? "") : ""),
                                   checked: auto) { [weak self] in
            self?.update { $0.microphone = MicrophonePicker.automatic }
            self?.mics.preference = MicrophonePicker.automatic
        })
        micMenu.addItem(.separator())
        for device in mics.devices where device.transport != .virtual {
            micMenu.addItem(ActionItem(device.name, checked: config.microphone == device.uid) { [weak self] in
                self?.update { $0.microphone = device.uid }
                self?.mics.preference = device.uid
            })
        }
        addSubmenu(menu, "Microphone", micMenu)

        let engines = NSMenu()
        engines.addItem(ActionItem("Whisper \(whisper?.modelName ?? "large-v3-turbo") (local) — \(config.speechEngine == "whisper" ? whisperStatus : "off")",
                                   checked: config.speechEngine == "whisper") { [weak self] in
            self?.update { $0.speechEngine = "whisper" }
            self?.startWhisper()
        })
        engines.addItem(ActionItem("Apple (macOS speech recognition only)", checked: config.speechEngine == "apple") { [weak self] in
            self?.update { $0.speechEngine = "apple" }
            self?.startWhisper()
        })
        engines.addItem(.separator())
        let models = [config.whisperModel, config.whisperLanguageModel]
        if downloader.isRunning {
            let item = NSMenuItem(title: "Downloading Whisper models… \(Int(downloader.progress * 100))%", action: nil,
                                  keyEquivalent: "")
            item.isEnabled = false
            engines.addItem(item)
            engines.addItem(ActionItem("Cancel download") { [weak self] in self?.downloader.cancel() })
        } else if !ModelDownloader.missing(models).isEmpty {
            let missing = ModelDownloader.missing(models)
            engines.addItem(ActionItem("Download Whisper models (\(ModelDownloader.describe(missing)))…") { [weak self] in
                self?.downloadModels(missing)
            })
        }
        if WhisperServer.program == nil {
            engines.addItem(ActionItem("Install whisper.cpp…") { WhisperSetup.explainInstall() })
        }
        addSubmenu(menu, "Speech recognition", engines)

        let keys = NSMenu()
        for (title, id) in [("fn / 🌐", "fn"), ("Right Option", "rightOption"), ("Right Command", "rightCommand"),
                            ("Right Control", "rightControl")] {
            keys.addItem(ActionItem(title, checked: config.hotkey == id) { [weak self] in
                self?.update { $0.hotkey = id }
                self?.startHotkeys()
            })
        }
        addSubmenu(menu, "Push-to-talk key", keys)

        menu.addItem(ActionItem("Use Claude for formatting", checked: config.llm.enabled) { [weak self] in
            self?.update { $0.llm.enabled.toggle() }
        })
        menu.addItem(ActionItem(config.llm.resolvedKey == nil ? "Add Claude API key…" : "Claude API key…") { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            ClaudeKey.ask(self.window.model.actions)
        })
        menu.addItem(.separator())
        if let meeting, !meeting.isFinished {
            let recording = NSMenuItem(title: "● Transcribing \(meeting.app) — \(meeting.minutes) min", action: nil,
                                       keyEquivalent: "")
            recording.isEnabled = false
            menu.addItem(recording)
            menu.addItem(ActionItem("Stop meeting notes") { [weak self] in self?.stopMeeting() })
        } else {
            menu.addItem(ActionItem("Start meeting notes now") { [weak self] in self?.startMeeting(app: "Manual") })
        }
        menu.addItem(ActionItem("Notice calls in any app", checked: config.meetings.autoDetect) { [weak self] in
            self?.update { $0.meetings.autoDetect.toggle() }
        })
        menu.addItem(ActionItem("Ask before recording a call", checked: config.meetings.askBeforeRecording) { [weak self] in
            self?.update { $0.meetings.askBeforeRecording.toggle() }
        })
        menu.addItem(ActionItem("Show the Murmur bar", checked: overlay.showIdle) { [weak self] in
            guard let self else { return }
            self.overlay.showIdle.toggle()
            UserDefaults.standard.set(self.overlay.showIdle, forKey: "barShowIdle")
        })
        menu.addItem(ActionItem("Meetings & summaries…") { [weak self] in self?.window.show(section: .meetings) })
        menu.addItem(ActionItem("Tasks from meetings…") { [weak self] in self?.window.show(section: .tasks) })
        menu.addItem(ActionItem("Open meeting notes folder") {
            try? FileManager.default.createDirectory(at: ConfigStore.meetingsDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(ConfigStore.meetingsDirectory)
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Learn words I correct", checked: config.autoLearnDictionary) { [weak self] in
            self?.update { $0.autoLearnDictionary.toggle() }
        })
        let learnedWords = config.dictionary.filter { $0.learned == true }
        if !learnedWords.isEmpty {
            let sub = NSMenu()
            for entry in learnedWords {
                let heard = entry.misspellings.map { " (heard: \($0.joined(separator: ", ")))" } ?? ""
                sub.addItem(ActionItem("Remove “\(entry.word)”\(heard)") { [weak self] in
                    self?.update { $0.dictionary.removeAll { $0.word == entry.word } }
                })
            }
            addSubmenu(menu, "Learned words (\(learnedWords.count))", sub)
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Polish selected text") { [weak self] in self?.polishSelection() })
        menu.addItem(ActionItem("Paste last transcript") { [weak self] in
            guard let self, let text = self.lastTranscript else { return }
            self.context = FocusContext.capture()
            self.insert(text, raw: text, note: "repaste")
        })
        menu.addItem(ActionItem("Copy last transcript") { [weak self] in
            if let text = self?.lastTranscript { Paster.copy(text) }
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Edit config (dictionary, snippets, API key)…") {
            NSWorkspace.shared.open(ConfigStore.configURL)
        })
        menu.addItem(ActionItem("Reload config") { [weak self] in
            guard let self else { return }
            self.config = ConfigStore.load()
            self.startHotkeys()
        })
        menu.addItem(ActionItem("Open history") {
            if FileManager.default.fileExists(atPath: ConfigStore.historyURL.path) {
                NSWorkspace.shared.open(ConfigStore.historyURL)
            }
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Connect to Claude (desktop app & Claude Code)…") { ClaudeConnector.connectFromMenu() })
        menu.addItem(ActionItem("Check for updates… (version \(UpdateChecker.currentVersion))") { UpdateChecker.checkNow() })
        menu.addItem(ActionItem("Quit Murmur") { NSApp.terminate(nil) })
    }

    private func addSubmenu(_ menu: NSMenu, _ title: String, _ submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }
}

/// `Murmur --selftest <out.json> <audio>...`: recognizes each file in every configured language and writes the
/// candidates and the picked language. Launch it via `open -n Murmur.app --args ...` so it uses Murmur's permissions.
func runSelfTest(output: String, files: [String]) -> Never {
    let recorder = SpeechRecorder()
    recorder.alwaysTryAllLanguages = CommandLine.arguments.contains("--all")
    let config = ConfigStore.load()
    let locales = config.languages
    let whisper = CommandLine.arguments.contains("--apple") ? nil
        : WhisperServer.startAndWait(model: config.whisperModel, port: 8179)
    let detector = whisper == nil ? nil
        : WhisperServer.startAndWait(model: ConfigStore.load().whisperLanguageModel, port: 8181)
    recorder.whisper = whisper
    recorder.whisperLanguage = detector
    print("whisper: \(whisper == nil ? "off" : "ready"), language model: \(detector == nil ? "off" : "ready")")
    var report: [[String: Any]] = []
    var pending = files

    func next() {
        guard let file = pending.first else {
            let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            FileManager.default.createFile(atPath: output, contents: data)
            whisper?.stop()
            detector?.stop()
            exit(0)
        }
        pending.removeFirst()
        let words = config.dictionary.sorted { ($0.starred ?? false) && !($1.starred ?? false) }.map(\.word)
        recorder.recognize(file: URL(fileURLWithPath: file), locales: locales, contextualStrings: words) { text, locale in
            let d = recorder.diagnostics
            report.append([
                "file": (file as NSString).lastPathComponent, "errors": d.errors, "picked": locale, "text": text,
                "seconds": d.seconds, "whisper": d.whisper ?? "",
                "candidates": d.candidates.map { ["locale": $0.locale, "text": $0.text, "confidence": $0.confidence ?? -1] },
            ])
            next()
        }
    }
    next()
    RunLoop.main.run()
    exit(0)
}

/// `Murmur --meeting-selftest <file>...`: runs audio files (alternating Others / Me) through meeting chunking,
/// transcription and summarization, and prints the notes path.
func runMeetingSelfTest(files: [String]) -> Never {
    let config = ConfigStore.load()
    let recorder = MeetingRecorder(app: "Self-test", locales: config.languages, contextualStrings: [])
    let whisper = CommandLine.arguments.contains("--apple") ? nil
        : WhisperServer.startAndWait(model: config.whisperModel, port: 8179)
    let detector = whisper == nil ? nil
        : WhisperServer.startAndWait(model: ConfigStore.load().whisperLanguageModel, port: 8181)
    recorder.whisper = whisper
    recorder.whisperLanguage = detector
    print("whisper: \(whisper == nil ? "off" : "ready"), language model: \(detector == nil ? "off" : "ready")")
    recorder.summarizer = { languages in
        if config.llm.enabled, let key = config.llm.resolvedKey {
            return (ClaudeClient(apiKey: key, model: config.llm.model, timeout: 180, effort: "medium", maxTokens: 16_000), 150_000)
        }
        if #available(macOS 26, *), AppleIntelligenceGenerator.isAvailable(for: languages.first ?? "en") {
            return (AppleIntelligenceGenerator(), 5_000)
        }
        return nil
    }
    recorder.onStatus = { print($0) }
    recorder.onFinished = { url in
        print(url.path)
        whisper?.stop()
        detector?.stop()
        exit(0)
    }
    var offset = 0.0
    for (i, file) in files.enumerated() {
        // "--others-only": every file is a voice from the call (tells speakers apart).
        let speaker: Speaker = CommandLine.arguments.contains("--others-only") || i % 2 == 0 ? .others : .me
        try? recorder.feed(file: URL(fileURLWithPath: file), speaker: speaker, at: offset)
        offset += 8
    }
    recorder.stop()
    DispatchQueue.main.asyncAfter(deadline: .now() + 240) { exit(1) }
    RunLoop.main.run()
    exit(0)
}

let arguments = CommandLine.arguments
if arguments.contains("--ax-status") {
    print("accessibility trusted: \(AXIsProcessTrusted())")
    exit(0)
}
if let i = arguments.firstIndex(of: "--paste-test"), arguments.count > i + 1 {
    // Pastes into whatever is focused in the frontmost app and reports whether the text arrived.
    let text = arguments[i + 1]
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        let ctx = FocusContext.capture()
        print("app: \(ctx.appName ?? "?"), electron: \(ctx.isElectron), field readable: \(ctx.element != nil)")
        guard AXIsProcessTrusted() else {
            print("accessibility trusted: false")
            exit(2)
        }
        Paster.insert(text, into: ctx.element, allowDirectInsert: !ctx.isElectron, restoreClipboard: true) { outcome in
            print("paste: \(outcome)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
        }
    }
    RunLoop.main.run()
}
if arguments.contains("--mic-test") {
    // Starts the dictation recorder on the chosen mic and reports how long it takes to go live.
    let config = ConfigStore.load()
    let device = AudioDevices.current(preference: config.microphone)
    let recorder = SpeechRecorder()
    let started = Date()
    print("mic: \(device?.name ?? "system default") [\(device?.transport.rawValue ?? "-")]")
    do {
        try recorder.start(locales: config.languages, contextualStrings: [], device: device?.id, ready: {
            print(String(format: "ready after %.2f s", Date().timeIntervalSince(started)))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                recorder.stop { text, locale in
                    print("stopped cleanly (heard: \(text.isEmpty ? "nothing" : text) \(locale))")
                    exit(0)
                }
            }
        }, failed: { error in
            print("failed: \(error.localizedDescription)")
            exit(1)
        })
        print(String(format: "start() returned after %.3f s", Date().timeIntervalSince(started)))
    } catch {
        print("start error: \(error.localizedDescription)")
        exit(1)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { print("timed out"); exit(1) }
    RunLoop.main.run()
}
if let i = arguments.firstIndex(of: "--replay-test"), arguments.count > i + 1 {
    // Plays files through the live dictation path in real time and prints every recognizer result.
    let recorder = SpeechRecorder()
    let whisper = arguments.contains("--apple") ? nil
        : WhisperServer.startAndWait(model: ConfigStore.load().whisperModel, port: 8179)
    let detector = whisper == nil ? nil
        : WhisperServer.startAndWait(model: ConfigStore.load().whisperLanguageModel, port: 8181)
    recorder.whisper = whisper
    recorder.whisperLanguage = detector
    print("whisper: \(whisper == nil ? "off" : "ready"), language model: \(detector == nil ? "off" : "ready")")
    var files = Array(arguments[(i + 1)...])
    let started = Date()
    recorder.onRawResult = { text, isFinal in
        print(String(format: "  %5.1fs %@ %@", Date().timeIntervalSince(started), isFinal ? "FINAL" : "     ", text))
    }
    func next() {
        guard let file = files.first else { whisper?.stop(); detector?.stop(); exit(0) }
        files.removeFirst()
        print("== \((file as NSString).lastPathComponent)")
        do {
            try recorder.replay(file: URL(fileURLWithPath: file), locales: ConfigStore.load().languages) { text, locale in
                print("RESULT [\(locale)]: \(text)")
                next()
            }
        } catch {
            print("error: \(error)")
            next()
        }
    }
    next()
    RunLoop.main.run()
}
if arguments.contains("--bar-hover-test") {
    // Drives the bar with the real pointer: hover, click a menu item, drag to each spot. Puts the pointer back.
    MainActor.assumeIsolated {
        let bar = Overlay()
        bar.showIdle = true
        bar.move(to: .center)
        bar.model.onAction = { print("  action: \($0)") }
        bar.debugLog = arguments.contains("--verbose")
        let original = NSEvent.mouseLocation
        let screenHeight = NSScreen.screens[0].frame.height
        func post(_ type: CGEventType, _ p: NSPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: p.x, y: screenHeight - p.y),
                    mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        var steps: [(Double, () -> Void)] = []
        var t = 1.0
        func at(_ delay: Double, _ f: @escaping () -> Void) { t += delay; steps.append((t, f)) }
        var p = NSPoint.zero
        at(0) { p = NSPoint(x: bar.debugPillOnScreen.midX, y: bar.debugPillOnScreen.midY); post(.mouseMoved, NSPoint(x: p.x - 4, y: p.y)) }
        at(0.1) { post(.mouseMoved, p) }
        at(0.2) { post(.mouseMoved, NSPoint(x: p.x + 2, y: p.y)) }
        at(0.6) { print("hover → expanded: \(bar.model.expanded), takes clicks: \(!bar.debugIgnoresMouse)") }
        at(0.1) {
            let f = bar.debugPillOnScreen
            p = NSPoint(x: f.minX + 6 + 31, y: f.midY)  // first item: Meeting
            post(.mouseMoved, p)
        }
        at(0.2) { print("click 'Meeting':"); post(.leftMouseDown, p) }
        at(0.08) { post(.leftMouseUp, p) }
        for (name, target) in [("left", { NSPoint(x: NSScreen.main!.visibleFrame.minX + 60, y: NSScreen.main!.visibleFrame.midY + 40) }),
                               ("right", { NSPoint(x: NSScreen.main!.visibleFrame.maxX - 80, y: NSScreen.main!.visibleFrame.midY - 30) }),
                               ("center", { NSPoint(x: NSScreen.main!.visibleFrame.midX + 50, y: NSScreen.main!.visibleFrame.minY + 50) })] {
            at(0.6) {
                let f = bar.debugPillOnScreen
                p = NSPoint(x: f.midX, y: f.midY)
                post(.mouseMoved, p)
            }
            at(0.5) { post(.leftMouseDown, p) }
            for i in 1...12 {
                at(0.03) {
                    let to = target()
                    let q = NSPoint(x: p.x + (to.x - p.x) * Double(i) / 12, y: p.y + (to.y - p.y) * Double(i) / 12)
                    post(.leftMouseDragged, q)
                }
            }
            at(0.05) { post(.leftMouseUp, target()) }
            at(0.6) { print("drag to \(name) → spot: \(bar.model.anchor), pill at \(bar.debugPillOnScreen.origin), drag events: \(bar.debugDragEvents), expanded: \(bar.model.expanded)") }
        }
        at(0.3) { post(.mouseMoved, original); bar.move(to: .center) }
        at(0.5) { exit(0) }
        for (time, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + time, execute: f) }
        withExtendedLifetime(bar) { NSApplication.shared.run() }
    }
}
if arguments.contains("--section-timing") {
    // Opens the window and times switching between its sections.
    MainActor.assumeIsolated {
        let config = ConfigStore.load()
        let controller = MainWindowController(actions: AppActions(config: { config }, updateConfig: { _ in },
                                                                  meetingStatus: { nil }, toggleMeeting: {}, resummarize: { _ in }))
        controller.show(section: .home)
        // Let the data load first.
        let deadline = Date().addingTimeInterval(8)
        while controller.model.meetings.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        for (name, ms) in controller.timeSections() { print(String(format: "%-12@ %6.0f ms", name as NSString, ms)) }
        exit(0)
    }
}
if arguments.contains("--bar-highlight-test") {
    // Opens the menu, then sweeps the pointer across its buttons and reports which one is highlighted.
    MainActor.assumeIsolated {
        let bar = Overlay()
        bar.showIdle = true
        bar.move(to: .center)
        let original = NSEvent.mouseLocation
        let screenHeight = NSScreen.screens[0].frame.height
        func move(_ p: NSPoint) {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: p.x, y: screenHeight - p.y),
                    mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let f = bar.debugPillOnScreen
            move(NSPoint(x: f.midX - 3, y: f.midY))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { move(NSPoint(x: f.midX, y: f.midY)) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            let f = bar.debugPillOnScreen
            print("menu open: \(bar.model.expanded), width \(f.width)")
            let xs = stride(from: f.minX + 10, through: f.maxX - 10, by: 22).map { $0 }
            for (i, x) in xs.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.25) {
                    move(NSPoint(x: x, y: f.midY))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        print(String(format: "  x=%.0f → %@", x, bar.model.hoveredItem ?? "-"))
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(xs.count) * 0.25 + 0.5) {
                move(original)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    print("after leaving → \(bar.model.hoveredItem ?? "-"), menu open: \(bar.model.expanded)")
                    exit(0)
                }
            }
        }
        withExtendedLifetime(bar) { NSApplication.shared.run() }
    }
}
if arguments.contains("--bar-demo") {
    // Shows each state of the bar for 2.5 s (for screenshots): resting, menu, recording, working, call prompt,
    // meeting badge, message, then the left and right positions.
    MainActor.assumeIsolated {
        let bar = Overlay()
        bar.showIdle = true
        let steps: [(String, () -> Void)] = [
            ("resting", { bar.hide() }),
            ("menu", { bar.model.expanded = true }),
            ("recording", { bar.model.expanded = false; bar.showRecording() }),
            ("voice note", { bar.showRecording("Voice note", stoppable: true) }),
            ("working", { bar.showWorking() }),
            ("prompt", { bar.showPrompt(app: "Microsoft Teams", bundle: "com.microsoft.teams2") { _ in } }),
            ("meeting", { bar.hide(); bar.setMeeting(MeetingBadge(name: "Microsoft Teams", started: Date().addingTimeInterval(-754))) }),
            ("message", { bar.show("Voice note saved — Murmur ▸ Meetings") }),
            ("left", { bar.hide(); bar.move(to: .left); bar.model.expanded = true; bar.setMeeting(nil) }),
            ("right", { bar.move(to: .right); bar.model.expanded = false }),
        ]
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(i) * 2.5) {
                print(step.0)
                fflush(stdout)
                step.1()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(steps.count) * 2.5) { bar.move(to: .center); exit(0) }
        withExtendedLifetime(bar) { NSApplication.shared.run() }
    }
}
if let i = arguments.firstIndex(of: "--whatsapp-test"), arguments.count > i + 1 {
    // Runs the WhatsApp button: copies the text, opens WhatsApp and presses ⌘N (New Chat).
    let text = arguments[i + 1]
    MainActor.assumeIsolated {
        print("accessibility trusted: \(AXIsProcessTrusted())")
        Share.whatsApp(text)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(0) }
    RunLoop.main.run()
}
if let i = arguments.firstIndex(of: "--call-scan"), arguments.count > i + 1 {
    // Reads a call app the way the meeting recorder does (read-only) and prints what it found.
    let bundle = arguments[i + 1]
    print("accessibility trusted: \(AXIsProcessTrusted())")
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { print("not running"); exit(1) }
    let started = Date()
    let (elements, titles) = CallObserver.scan(pid: app.processIdentifier)
    let reading = CallRoster.read(elements, windowTitles: titles, oneToOne: CallObserver.oneToOneApps.contains(bundle))
    print(String(format: "%d elements in %.2f s; small-window titles: %@", elements.count, Date().timeIntervalSince(started), titles))
    print("participants: \(reading.participants)\nspeaking: \(reading.speaking)")
    if arguments.contains("--verbose") {
        for e in elements.prefix(400) {
            let found = CallRoster.read([e], windowTitles: [], oneToOne: false)
            print("  \(e.role) \(e.domID ?? ""): \(e.texts.joined(separator: " | ").prefix(arguments.contains("--full") ? 2000 : 120))"
                  + (found.participants.isEmpty ? "" : "   → \(found.participants) speaking \(found.speaking)"))
        }
    }
    exit(0)
}
if arguments.contains("--list-mics") {
    let pick = AudioDevices.current(preference: ConfigStore.load().microphone)
    for d in AudioDevices.inputDevices() {
        print("\(d.uid == pick?.uid ? "→" : " ") \(d.name) [\(d.transport.rawValue)] id=\(d.id)")
    }
    exit(0)
}
if let i = arguments.firstIndex(of: "--meeting-selftest"), arguments.count > i + 1 {
    runMeetingSelfTest(files: Array(arguments[(i + 1)...]).filter { !$0.hasPrefix("--") })
}
if let i = arguments.firstIndex(of: "--selftest"), arguments.count > i + 2 {
    runSelfTest(output: arguments[i + 1], files: Array(arguments[(i + 2)...]))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
