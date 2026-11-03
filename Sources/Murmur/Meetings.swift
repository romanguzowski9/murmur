import AppKit
import AVFoundation
import CoreAudio
import FoundationModels
import MurmurCore
@preconcurrency import ScreenCaptureKit

// MARK: - Detection

/// A voice call in progress: which app, and its bundle ID (for its icon).
struct DetectedCall: Equatable {
    var name: String
    var bundle: String?
}

/// Detects an ongoing call: an app is capturing the microphone. Known call apps are named; a browser is matched to
/// the meeting site from its window titles; any other app holding the microphone (that isn't a dictation or
/// recording tool) counts too, named after the app — Murmur only asks, so a false alarm costs one click.
enum MeetingDetector {
    static let apps: [(String, String)] = [
        ("com.microsoft.teams", "Microsoft Teams"), ("net.whatsapp.whatsapp", "WhatsApp"), ("desktop.whatsapp", "WhatsApp"),
        ("us.zoom.xos", "Zoom"), ("com.apple.facetime", "FaceTime"), ("com.apple.mobilephone", "Phone"),
        ("com.apple.telephonyutilities", "Phone"), ("com.cisco.webex", "Webex"), ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.discord", "Discord"), ("com.skype", "Skype"), ("ru.keepcoder.telegram", "Telegram"),
        ("org.telegram", "Telegram"), ("org.whispersystems.signal", "Signal"), ("com.viber", "Viber"),
        ("com.tencent.xinwechat", "WeChat"), ("com.google.meet", "Google Meet"), ("com.ringcentral", "RingCentral"),
    ]
    /// Apps that use the microphone without being on a call.
    static let notCalls = [
        "com.electron.wispr-flow", "com.apple.siri", "com.apple.assistant", "com.apple.speech", "com.apple.corespeech",
        "com.apple.dictation", "com.apple.voicememos", "com.apple.quicktimeplayerx", "com.apple.screencapture",
        "com.apple.controlcenter", "com.apple.accessibility", "com.obsproject", "com.loom", "com.apple.photobooth",
        "com.apple.garageband", "com.apple.logic", "com.superwhisper", "com.goodsnooze.macwhisper",
    ]
    static let browserMarkers = ["chrome", "edgemac", "thebrowser", "brave", "firefox", "com.apple.webkit", "safari",
                                 "opera", "vivaldi", "atlas", "arc"]
    static let browserTitles: [(String, String)] = [
        ("^Meet [-–]|Google Meet|meet\\.google\\.com", "Google Meet"), ("Microsoft Teams", "Microsoft Teams"),
        ("WhatsApp", "WhatsApp"), ("Zoom", "Zoom"), ("Slack", "Slack"), ("Discord", "Discord"), ("Webex", "Webex"),
        ("Telegram", "Telegram"), ("Messenger", "Messenger"),
    ]

    static func detect() -> DetectedCall? {
        let own = Bundle.main.bundleIdentifier?.lowercased() ?? "local.murmur.dictation"
        let capturing = processesUsingMicrophone().filter { b in !b.hasPrefix(own) && !notCalls.contains { b.hasPrefix($0) } }
        for bundle in capturing {
            if let app = apps.first(where: { bundle.hasPrefix($0.0) }) { return DetectedCall(name: app.1, bundle: bundle) }
        }
        if let browser = capturing.first(where: { b in browserMarkers.contains { b.contains($0) } }) {
            for title in windowTitles() {
                if let match = browserTitles.first(where: { title.range(of: $0.0, options: .regularExpression) != nil }) {
                    return DetectedCall(name: match.1, bundle: browser)
                }
            }
            return DetectedCall(name: "\(appName(browser)) call", bundle: browser)
        }
        // Helper processes ("…helper", "…agent") belong to an app we'd have named above; skip them.
        if let other = capturing.first(where: { !$0.contains("helper") && !$0.hasSuffix("agent") && !$0.hasPrefix("com.apple.") }) {
            return DetectedCall(name: appName(other), bundle: other)
        }
        return nil
    }

    /// The app's display name for a (lower-cased) bundle ID.
    static func appName(_ bundle: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier?.lowercased() == bundle }),
           let name = app.localizedName { return name }
        return bundle.split(separator: ".").last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? bundle
    }

    /// Lower-cased bundle IDs of processes currently capturing audio input (macOS 14.2+).
    static func processesUsingMicrophone() -> [String] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                            mScope: kAudioObjectPropertyScopeGlobal,
                                                            mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &runningAddress, 0, nil, &runningSize, &running) == noErr,
                  running != 0 else { return nil }
            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                           mScope: kAudioObjectPropertyScopeGlobal,
                                                           mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?
            var valueSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &value) {
                AudioObjectGetPropertyData(id, &bundleAddress, 0, nil, &valueSize, $0)
            }
            guard status == noErr, let bundle = value?.takeRetainedValue() as String? else { return nil }
            return bundle.lowercased()
        }
    }

    /// Titles of on-screen windows (needs Screen Recording permission).
    static func windowTitles() -> [String] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return info.compactMap { $0[kCGWindowName as String] as? String }.filter { !$0.isEmpty }
    }
}

// MARK: - Chunking

struct AudioChunk {
    var speaker: Speaker
    var start: Double
    var buffer: AVAudioPCMBuffer
}

/// Converts one audio source to 16 kHz mono and cuts it into utterances at pauses (max 25 s), dropping silence.
final class Chunker {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    static let speechLevel: Float = 0.006

    let speaker: Speaker
    let emit: (AudioChunk) -> Void
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var chunkStart = 0.0
    private var voiced = 0.0
    private var silence = 0.0

    init(speaker: Speaker, emit: @escaping (AudioChunk) -> Void) {
        self.speaker = speaker
        self.emit = emit
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: Double) {
        guard let mono = convert(buffer), let data = mono.floatChannelData?[0], mono.frameLength > 0 else { return }
        let frames = Int(mono.frameLength)
        let piece = Array(UnsafeBufferPointer(start: data, count: frames))
        if samples.isEmpty { chunkStart = time }
        samples += piece
        let rms = sqrt(piece.reduce(0) { $0 + $1 * $1 } / Float(frames))
        let seconds = Double(frames) / 16000
        if rms > Self.speechLevel {
            voiced += seconds
            silence = 0
        } else {
            silence += seconds
        }
        let length = Double(samples.count) / 16000
        if voiced < 0.3 {
            if silence >= 1.5 { reset() }  // nothing said yet: don't keep silence
        } else if (silence >= 0.8 && length >= 2) || length >= 25 {
            flush()
        }
    }

    func flush() {
        defer { reset() }
        guard voiced >= 0.3, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        emit(AudioChunk(speaker: speaker, start: chunkStart, buffer: buffer))
    }

    private func reset() {
        samples = []
        voiced = 0
        silence = 0
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.format)
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }
}

// MARK: - Summaries on device

/// Apple's on-device model (Apple Intelligence), used for summaries when no Claude key is set.
@available(macOS 26, *)
final class AppleIntelligenceGenerator: TextGenerator {
    /// Ready, and able to handle the language (on macOS 27 it supports English but not Polish or Russian).
    static func isAvailable(for language: String) -> Bool {
        guard case .available = SystemLanguageModel.default.availability else { return false }
        return SystemLanguageModel.default.supportsLocale(Locale(identifier: language))
    }

    func complete(system: String, user: String) async throws -> String {
        let session = LanguageModelSession(instructions: system)
        return try await session.respond(to: user).content
    }
}

// MARK: - Recorder

/// Records a call: the call audio ("Others", via ScreenCaptureKit, excluding Murmur) and the microphone ("Me"),
/// transcribes it utterance by utterance with language detection, and summarizes it when it ends.
final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let app: String
    private(set) var transcript: MeetingTranscript
    /// Renamed after the title once the meeting is summarized.
    private(set) var fileURL: URL
    var onStatus: ((String) -> Void)?
    var onFinished: ((URL) -> Void)?
    /// True while the user is dictating; Apple's recognizer serves one stream at a time.
    var isSpeechBusy: () -> Bool = { false }
    /// Picks a model for the summary given the meeting's languages (most spoken first).
    var summarizer: ([String]) -> (TextGenerator, Int)? = { _ in nil }

    private let locales: [String]
    private let contextualStrings: [String]
    private var stream: SCStream?
    private var streamConfig: SCStreamConfiguration?
    private let audioQueue = DispatchQueue(label: "murmur.meeting.audio")
    private var chunkers: [Speaker: Chunker] = [:]
    private let speech = SpeechRecorder()
    /// Local Whisper for the transcripts, when it's running.
    var whisper: WhisperServer? {
        get { speech.whisper }
        set { speech.whisper = newValue }
    }
    var whisperLanguage: WhisperServer? {
        get { speech.whisperLanguage }
        set { speech.whisperLanguage = newValue }
    }
    /// The call app, watched (read-only, via Accessibility) for participant names and its active-speaker marker.
    var callBundle: String?
    private var callObserver: CallObserver?
    private var pending: [AudioChunk] = []
    private var inFlight: AudioChunk?
    private var stopping = false
    private(set) var isFinished = false

    init(app: String, locales: [String], contextualStrings: [String]) {
        self.app = app
        self.locales = locales
        self.contextualStrings = contextualStrings
        let started = Date()
        transcript = MeetingTranscript(app: app, started: started)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH-mm"
        try? FileManager.default.createDirectory(at: ConfigStore.meetingsDirectory, withIntermediateDirectories: true)
        fileURL = ConfigStore.meetingsDirectory.appendingPathComponent("\(df.string(from: started)) \(app).md")
        super.init()
        for speaker in [Speaker.me, .others] {
            chunkers[speaker] = Chunker(speaker: speaker) { [weak self] chunk in
                DispatchQueue.main.async { self?.enqueue(chunk) }
            }
        }
    }

    var minutes: Int { Int(Date().timeIntervalSince(transcript.started) / 60) }

    /// - Parameter microphone: Core Audio UID of the mic to record as "Me"; nil uses the system default.
    func start(microphone: String?) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "Murmur", code: 2, userInfo: [NSLocalizedDescriptionKey: "No display to capture"])
        }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = true
        config.microphoneCaptureDeviceID = microphone
        config.sampleRate = 48000
        config.channelCount = 1
        // Video is required by the API; keep it tiny.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream
        streamConfig = config
        if let callBundle, let observer = CallObserver(bundle: callBundle, started: transcript.started) {
            observer.start()
            callObserver = observer
        }
        write()
    }

    /// Switches the "Me" microphone mid-meeting (e.g. AirPods connected during the call).
    func switchMicrophone(to uid: String) {
        guard let stream, let config = streamConfig, config.microphoneCaptureDeviceID != uid else { return }
        config.microphoneCaptureDeviceID = uid
        stream.updateConfiguration(config) { _ in }
    }

    /// Feeds an audio file as if it came from `speaker` (self-test).
    func feed(file: URL, speaker: Speaker, at offset: Double) throws {
        let audio = try AVAudioFile(forReading: file)
        var position = offset
        while audio.framePosition < audio.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else { break }
            try audio.read(into: buffer)
            if buffer.frameLength == 0 { break }
            chunkers[speaker]?.append(buffer, at: position)
            position += Double(buffer.frameLength) / buffer.format.sampleRate
        }
        // A pause after each turn closes the utterance.
        if let silence = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.processingFormat.sampleRate)) {
            silence.frameLength = silence.frameCapacity
            chunkers[speaker]?.append(silence, at: position)
        }
    }

    func stop() {
        guard !stopping else { return }
        stopping = true
        stream?.stopCapture { _ in }
        stream = nil
        audioQueue.async { [weak self] in
            self?.chunkers.values.forEach { $0.flush() }
            DispatchQueue.main.async { self?.pump() }
        }
    }

    /// Dictation is starting: hand the recognizer over and retry the current chunk afterwards.
    func yieldSpeech() {
        guard let chunk = inFlight else { return }
        speech.cancel()
        inFlight = nil
        pending.insert(chunk, at: 0)
    }

    // SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let speaker: Speaker
        switch type {
        case .audio: speaker = .others
        case .microphone: speaker = .me
        default: return
        }
        guard let buffer = Self.pcmBuffer(sampleBuffer) else { return }
        chunkers[speaker]?.append(buffer, at: Date().timeIntervalSince(transcript.started))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?("Meeting capture stopped: \(error.localizedDescription)")
            self?.stop()
        }
    }

    private func enqueue(_ chunk: AudioChunk) {
        pending.append(chunk)
        pump()
    }

    private func pump() {
        guard inFlight == nil, !isFinished else { return }
        guard let chunk = pending.first else {
            if stopping { finish() }
            return
        }
        if isSpeechBusy() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.pump() }
            return
        }
        pending.removeFirst()
        inFlight = chunk
        speech.transcribe(buffers: [chunk.buffer], locales: locales, contextualStrings: contextualStrings) {
            [weak self] text, locale in
            guard let self else { return }
            self.inFlight = nil
            var added = false
            for passage in self.passages(chunk, text: text, locale: locale) where self.transcript.add(passage) { added = true }
            if added { self.write() }
            self.pump()
        }
    }

    /// The chunk's text as transcript segments. Call audio is cut at Whisper's segments (a passage can hold more
    /// than one voice), each with a voice print for telling the speakers apart when the meeting ends.
    private func passages(_ chunk: AudioChunk, text: String, locale: String) -> [TranscriptSegment] {
        let samples = Array(UnsafeBufferPointer(start: chunk.buffer.floatChannelData![0], count: Int(chunk.buffer.frameLength)))
        let length = Double(samples.count) / 16000
        func voice(_ a: Double, _ b: Double) -> [Float]? {
            guard chunk.speaker == .others else { return nil }
            let i = max(0, min(samples.count, Int(a * 16000))), j = max(i, min(samples.count, Int(b * 16000)))
            return VoicePrint.embedding(samples[i..<j])
        }
        let timed = speech.lastSegments
        guard chunk.speaker == .others, timed.count > 1 else {
            return [TranscriptSegment(start: chunk.start, speaker: chunk.speaker, text: text, locale: locale,
                                      duration: length, voice: voice(0, length))]
        }
        // Whisper's segments break anywhere, even mid-word; cut only where a sentence ends.
        var sentences: [(start: Double, end: Double, parts: [String])] = []
        for s in timed {
            if let last = sentences.last, !Self.endsSentence(last.parts.last ?? "") {
                sentences[sentences.count - 1].end = s.end
                sentences[sentences.count - 1].parts.append(s.text)
            } else {
                sentences.append((s.start, s.end, [s.text]))
            }
        }
        var out: [TranscriptSegment] = []
        for s in sentences {
            let text = WhisperText.join(s.parts)
            guard !text.isEmpty, !out.contains(where: { $0.text == text }) else { continue }  // Whisper repeating itself
            out.append(TranscriptSegment(start: chunk.start + s.start, speaker: .others, text: text, locale: locale,
                                         duration: s.end - s.start, voice: voice(s.start, s.end)))
        }
        return out.isEmpty ? [TranscriptSegment(start: chunk.start, speaker: chunk.speaker, text: text, locale: locale,
                                                duration: length, voice: voice(0, length))] : out
    }

    /// "…Friday." ends a sentence; "…trailer, 2." doesn't (a decimal number continues in the next segment).
    static func endsSentence(_ text: String) -> Bool {
        let t = text.trimmed
        guard let last = t.last else { return true }
        if "?!…".contains(last) { return true }
        return last == "." && !(t.dropLast().last?.isNumber ?? false)
    }

    /// Who said what among the other participants: voices grouped into "Speaker 1", "Speaker 2"…, named where the
    /// call app showed who was speaking (or the call had one other person).
    private func identifySpeakers() {
        callObserver?.stop()
        if let observer = callObserver {
            let me = NSFullUserName()
            transcript.participants = observer.participants.filter { !SpeakerNames.isSame($0, me) }
        }
        transcript.assignSpeakers(observations: callObserver?.observations ?? [])
    }

    private func finish() {
        isFinished = true
        transcript.ended = Date()
        identifySpeakers()
        write()
        // Every meeting gets a summary, even when nothing was transcribed or no AI model is available.
        onStatus?("Writing meeting summary…")
        let model = transcript.segments.isEmpty ? nil : summarizer(transcript.languages)
        let snapshot = transcript
        Task { @MainActor in
            let corpus = await Task.detached(priority: .utility) { MurmurLibrary.topicCorpus() }.value
            let notes = await MeetingSummarizer.notesAlways(snapshot, model: model, corpus: corpus)
            transcript.summary = notes.summary
            transcript.title = notes.title
            write()
            renameAfterTitle()
            onFinished?(fileURL)
        }
    }

    /// Murmur is quitting: stop now and write an offline summary of what was transcribed so far.
    func finishNow() {
        guard !isFinished else { return }
        isFinished = true
        stream?.stopCapture { _ in }
        stream = nil
        transcript.ended = Date()
        identifySpeakers()
        var summary = OfflineSummarizer.summarize(transcript)
        let untranscribed = pending.count + (inFlight == nil ? 0 : 1)
        if untranscribed > 0 {
            summary = "_Murmur quit before \(untranscribed) recorded passage(s) could be transcribed._\n\n" + summary
        }
        transcript.summary = summary
        transcript.title = OfflineSummarizer.title(transcript)
        write()
        renameAfterTitle()
    }

    /// "2026-10-31 14-29 WhatsApp.md" → "2026-10-31 14-29 Gdansk route, shipping partner & cargo.md".
    private func renameAfterTitle() {
        guard let title = transcript.title, !title.isEmpty else { return }
        let target = MurmurLibrary.fileName(date: transcript.started, title: title)
        if (try? FileManager.default.moveItem(at: fileURL, to: target)) != nil { fileURL = target }
    }

    private func write() {
        try? transcript.markdown.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static func pcmBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription,
              let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat?,
              sampleBuffer.numSamples > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(sampleBuffer.numSamples),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
