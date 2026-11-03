import AudioToolbox
import AVFoundation
import MurmurCore
import Speech

/// Streams the microphone into Apple's speech recognizer (on-device when the locale supports it) and detects the
/// spoken language among the configured ones.
///
/// Apple's speech service serves one recognition stream per process at a time (parallel tasks report
/// "No speech detected"), so detection is sequential: the live pass uses the last detected language, and only when
/// its result does not confidently look like that language is the recorded audio re-run in the other languages.
final class SpeechRecorder {
    struct Diagnostics {
        var candidates: [RecognitionCandidate] = []
        var errors: [String: String] = [:]
        var seconds: [String: Double] = [:]
        /// What Whisper heard, when it was used.
        var whisper: String?
    }

    /// The audio engine lives on its own queue: starting it can block for a second or more while a Bluetooth
    /// headset switches into microphone mode, and that must never freeze the hotkey or the UI.
    private var engine: AVAudioEngine?
    private let audioQueue = DispatchQueue(label: "murmur.speech.audio")
    private var session = 0
    private var recognizers: [String: SFSpeechRecognizer] = [:]
    private var locales: [String] = []
    private var contextualStrings: [String] = []

    private var liveLocale = ""
    private var liveRequest: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var live = RecognitionCandidate(locale: "", text: "", confidence: nil)
    /// Everything recognized while the key is held, across recognizer restarts.
    private var liveText = TranscriptAccumulator()
    private var liveDone = false
    private var liveStarted = Date()

    private let bufferLock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    /// Positions (seconds into the audio sent to the recognizer, which is also `buffers`) of long pauses trimmed
    /// out while recording: sentence breaks.
    private var sentPauses: [Double] = []
    private var sentDuration = 0.0

    private var completion: ((String, String) -> Void)?
    /// Whisper's timed segments for the last `transcribe` (empty when Apple's recognizer answered).
    private(set) var lastSegments: [WhisperServer.Segment] = []
    private var resolving = false
    private var finishTimer: Timer?
    private(set) var diagnostics = Diagnostics()
    /// Run every language even when the first result is confident (self-test).
    var alwaysTryAllLanguages = false
    /// When ready, the final text comes from Whisper, in the language Apple's recognizer settled on (that keeps
    /// Whisper fast); Apple's text is used when Whisper isn't running or returns nothing.
    var whisper: WhisperServer?
    /// Small Whisper model that picks the language before `whisper` transcribes.
    var whisperLanguage: WhisperServer?

    var onPartial: ((String) -> Void)?
    /// Every raw recognizer result of the live pass (text, isFinal); used by the replay self-test.
    var onRawResult: ((String, Bool) -> Void)?

    /// Last detected language; tried first next time.
    private var primaryLocale: String {
        get { UserDefaults.standard.string(forKey: "primaryLocale") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "primaryLocale") }
    }

    static func requestPermissions(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                DispatchQueue.main.async { done(status == .authorized && mic) }
            }
        }
    }

    // MARK: Live

    /// Starts listening. Returns at once; `ready` (main queue) fires when the microphone is live, or `failed`.
    /// - Parameter device: input device to record from; nil uses the system default.
    func start(locales: [String], contextualStrings: [String], device: AudioDeviceID? = nil,
               ready: @escaping () -> Void, failed: @escaping (Error) -> Void) throws {
        try prepare(locales: locales, contextualStrings: contextualStrings)
        let request = makeRequest(liveLocale, partialResults: true)
        liveRequest = request
        let keepAudio = self.locales.count > 1 || whisper?.isReady == true
        session += 1
        let session = self.session
        runLivePass(request)
        audioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.startEngine(device: device, request: request, keepAudio: keepAudio)
                DispatchQueue.main.async { if self.session == session { ready() } }
            } catch {
                DispatchQueue.main.async { if self.session == session { failed(error) } }
            }
        }
    }

    /// Runs on `audioQueue`.
    private func startEngine(device: AudioDeviceID?, request: SFSpeechAudioBufferRecognitionRequest,
                             keepAudio: Bool) throws {
        // A Bluetooth headset reports no usable format until it has switched into microphone (hands-free) mode;
        // wait for it (up to 2 s) instead of recording silence. A fresh engine sees the device's current format.
        var engine = AVAudioEngine()
        var format = Self.configure(engine, device: device)
        var waited = 0
        while (format.sampleRate == 0 || format.channelCount == 0) && waited < 20 {
            usleep(100_000)
            waited += 1
            engine = AVAudioEngine()
            format = Self.configure(engine, device: device)
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Murmur", code: 3, userInfo: [NSLocalizedDescriptionKey: "Microphone isn't ready yet — try again"])
        }
        let gate = SilenceGate()
        gate.onLongPause = { [weak self] in self?.notePause() }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // Long pauses never reach the recognizer, so it keeps one continuous transcript while the key is held.
            guard gate.shouldPass(rms: Self.level(buffer), duration: Self.duration(buffer)) else { return }
            request.append(buffer)
            self?.noteSent(buffer)
            if keepAudio, let copy = Self.copy(buffer) { self?.store(copy) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    private static func configure(_ engine: AVAudioEngine, device: AudioDeviceID?) -> AVAudioFormat {
        let input = engine.inputNode
        if var id = device, let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        return input.outputFormat(forBus: 0)
    }

    /// Stops listening and returns (transcript, locale).
    func stop(_ completion: @escaping (String, String) -> Void) {
        self.completion = completion
        let request = liveRequest
        // End the request only after the engine has stopped, so the last words are delivered.
        stopAudio { request?.endAudio() }
        if liveDone {
            resolve()
        } else {
            finishTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in self?.resolve() }
        }
    }

    func cancel() {
        completion = nil
        resolving = false
        finishTimer?.invalidate()
        stopAudio()
        task?.cancel()
        task = nil
        liveRequest = nil
        bufferLock.lock()
        buffers = []
        sentPauses = []
        sentDuration = 0
        bufferLock.unlock()
    }

    // MARK: Files (self-test)

    /// Streams a file through the live pass at real-time speed, as if spoken into the microphone, then stops.
    func replay(file: URL, locales: [String], completion: @escaping (String, String) -> Void) throws {
        let audio = try Self.readBuffers(file)
        try prepare(locales: locales, contextualStrings: [])
        let request = makeRequest(liveLocale, partialResults: true)
        liveRequest = request
        runLivePass(request)
        var index = 0
        let gate = SilenceGate()
        gate.onLongPause = { [weak self] in self?.notePause() }
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            // Feed whatever is due by now.
            let due = Date().timeIntervalSince(self.liveStarted)
            var fed = audio.prefix(index).reduce(0.0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
            while index < audio.count, fed <= due {
                if gate.shouldPass(rms: Self.level(audio[index]), duration: Self.duration(audio[index])) {
                    request.append(audio[index])
                    self.noteSent(audio[index])
                    self.store(audio[index])
                }
                fed += Double(audio[index].frameLength) / audio[index].format.sampleRate
                index += 1
            }
            if index >= audio.count {
                timer.invalidate()
                self.completion = completion
                request.endAudio()
                self.finishTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in self?.resolve() }
            }
        }
    }

    func recognize(file: URL, locales: [String], contextualStrings: [String] = [],
                   completion: @escaping (String, String) -> Void) {
        do {
            transcribe(buffers: try Self.readBuffers(file), locales: locales, contextualStrings: contextualStrings,
                       completion: completion)
        } catch {
            diagnostics.errors["file"] = "\(error)"
            completion("", "")
        }
    }

    /// Recognizes recorded audio (meeting chunks, self-test files) with language detection.
    func transcribe(buffers audio: [AVAudioPCMBuffer], locales: [String], contextualStrings: [String] = [],
                    completion: @escaping (String, String) -> Void) {
        do {
            try prepare(locales: locales, contextualStrings: contextualStrings)
        } catch {
            completion("", "")
            return
        }
        bufferLock.lock()
        buffers = audio
        sentPauses = []
        sentDuration = 0
        bufferLock.unlock()
        self.completion = completion
        let started = Date()
        recognizeBuffered(liveLocale) { [weak self] candidate in
            guard let self else { return }
            self.diagnostics.seconds[candidate.locale] = Date().timeIntervalSince(started)
            self.live = candidate
            self.liveDone = true
            self.resolve()
        }
    }

    // MARK: Passes

    private func prepare(locales requested: [String], contextualStrings: [String]) throws {
        cancel()
        diagnostics = Diagnostics()
        self.contextualStrings = contextualStrings
        locales = requested.filter { recognizer($0)?.isAvailable == true }
        guard !locales.isEmpty else {
            throw NSError(domain: "Murmur", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Speech recognition unavailable for \(requested.joined(separator: ", "))",
            ])
        }
        liveLocale = locales.contains(primaryLocale) ? primaryLocale : locales[0]
        live = RecognitionCandidate(locale: liveLocale, text: "", confidence: nil)
        liveText = TranscriptAccumulator()
        liveDone = false
        liveStarted = Date()
    }

    private func recognizer(_ locale: String) -> SFSpeechRecognizer? {
        if let r = recognizers[locale] { return r }
        let r = SFSpeechRecognizer(locale: Locale(identifier: locale))
        recognizers[locale] = r
        return r
    }

    private func makeRequest(_ locale: String, partialResults: Bool) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = partialResults
        request.addsPunctuation = true
        request.taskHint = .dictation
        // Dictionary words bias recognition, like Flow's static vocabulary.
        request.contextualStrings = Array(contextualStrings.prefix(100))
        if recognizer(locale)?.supportsOnDeviceRecognition == true { request.requiresOnDeviceRecognition = true }
        return request
    }

    private func runLivePass(_ request: SFSpeechAudioBufferRecognitionRequest) {
        task = recognizer(liveLocale)?.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.liveRequest === request else { return }
                if let result {
                    self.onRawResult?(result.bestTranscription.formattedString, result.isFinal)
                    self.liveText.update(result.bestTranscription.formattedString)
                    if result.isFinal {
                        self.bufferLock.lock()
                        let pauses = self.sentPauses
                        self.bufferLock.unlock()
                        Self.breakSentences(&self.liveText, segments: result.bestTranscription.segments, pauses: pauses)
                    }
                    self.live.text = self.liveText.text
                    self.onPartial?(self.live.text)
                    if result.isFinal {
                        self.live.confidence = Self.confidence(result)
                        self.liveDone = true
                    }
                }
                if let error {
                    self.diagnostics.errors[self.liveLocale] = "\(error)"
                    self.liveDone = true
                }
                if self.liveDone, self.completion != nil {
                    self.diagnostics.seconds[self.liveLocale] = Date().timeIntervalSince(self.liveStarted)
                    self.resolve()
                }
            }
        }
    }

    /// Recognizes the recorded audio in one language.
    private func recognizeBuffered(_ locale: String, _ done: @escaping (RecognitionCandidate) -> Void) {
        // Partial results let the accumulator catch a restart that slips past the pause trimming.
        let request = makeRequest(locale, partialResults: true)
        bufferLock.lock()
        let audio = buffers
        let recordedPauses = sentPauses
        bufferLock.unlock()
        // Note where long pauses fall on the trimmed timeline, to put sentence breaks there.
        let gate = SilenceGate()
        var sent = 0.0
        // Pauses already trimmed while recording, plus any still in this audio (meeting chunks, files).
        var pauses = recordedPauses
        gate.onLongPause = { pauses.append(sent) }
        for buffer in audio where gate.shouldPass(rms: Self.level(buffer), duration: Self.duration(buffer)) {
            request.append(buffer)
            sent += Self.duration(buffer)
        }
        request.endAudio()

        var candidate = RecognitionCandidate(locale: locale, text: "", confidence: nil)
        var accumulated = TranscriptAccumulator()
        var finished = false
        let finish = { [weak self] in
            guard !finished else { return }
            finished = true
            self?.task?.cancel()
            done(candidate)
        }
        let seconds = audio.reduce(0.0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
        let timeout = Timer.scheduledTimer(withTimeInterval: 4 + seconds * 0.5, repeats: false) { _ in finish() }
        task = recognizer(locale)?.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                if let result {
                    accumulated.update(result.bestTranscription.formattedString)
                    if result.isFinal {
                        // Final results carry word timings: words starting before a pause end its sentence.
                        Self.breakSentences(&accumulated, segments: result.bestTranscription.segments, pauses: pauses)
                    }
                    candidate.text = accumulated.text
                    if result.isFinal {
                        candidate.confidence = Self.confidence(result)
                        timeout.invalidate()
                        finish()
                    }
                }
                if let error {
                    self?.diagnostics.errors[locale] = "\(error)"
                    timeout.invalidate()
                    finish()
                }
            }
        }
    }

    private func resolve() {
        guard completion != nil, !resolving else { return }
        resolving = true
        finishTimer?.invalidate()
        task?.cancel()
        let languages = locales.map { String($0.prefix(2)) }
        if locales.count == 1 || (!alwaysTryAllLanguages && LanguagePicker.isConfident(live, among: languages)) {
            finish([live])
            return
        }
        var candidates = [live]
        var queue = locales.filter { $0 != liveLocale }
        func next() {
            guard let locale = queue.first else {
                finish(candidates)
                return
            }
            queue.removeFirst()
            let started = Date()
            recognizeBuffered(locale) { [weak self] candidate in
                self?.diagnostics.seconds[locale] = Date().timeIntervalSince(started)
                candidates.append(candidate)
                next()
            }
        }
        next()
    }

    private func finish(_ candidates: [RecognitionCandidate]) {
        diagnostics.candidates = candidates
        let best = LanguagePicker.pick(candidates) ?? live
        if !best.text.isEmpty { primaryLocale = best.locale }
        let completion = self.completion
        self.completion = nil
        lastSegments = []
        resolving = false
        task = nil
        liveRequest = nil
        bufferLock.lock()
        let audio = buffers
        buffers = []
        sentPauses = []
        sentDuration = 0
        bufferLock.unlock()
        guard let whisper, whisper.isReady, !audio.isEmpty else {
            completion?(best.text, best.locale)
            return
        }
        let locale = best.text.isEmpty ? primaryLocale : best.locale
        let started = Date()
        let languages = locales.map { String($0.prefix(2)) }
        // Apple's language is trusted only when it's sure (enough words, high confidence).
        let sure = LanguagePicker.isConfident(best, among: languages)
        func done(_ result: WhisperServer.Result?) {
            diagnostics.seconds["whisper"] = Date().timeIntervalSince(started)
            diagnostics.whisper = result?.text
            guard let result, !result.text.isEmpty else {
                completion?(best.text, best.locale)
                return
            }
            lastSegments = result.segments
            completion?(result.text, WhisperText.locale(result.language, among: locales))
        }
        func transcribe(in language: String) {
            whisper.transcribe(audio, language: language) { result in
                // Far fewer words than Apple heard: the fitted window misfired; try once with the full one.
                if let result, WhisperText.looksTruncated(result.text, apple: best.text) {
                    whisper.transcribe(audio, language: language, fullWindow: true) { retry in
                        done(retry.map { WhisperText.looksTruncated($0.text, apple: best.text) ? result : $0 } ?? result)
                    }
                } else {
                    done(result)
                }
            }
        }
        // Language: the small Whisper model (≈0.15 s), else Apple's when it's sure, else the large model's own
        // detection (≈2 s slower). The large model then transcribes with a window fitted to the recording.
        if let detector = whisperLanguage, detector.isReady, languages.count > 1 {
            detector.detectLanguage(audio, among: languages) { detected in
                self.diagnostics.errors["whisper-language"] = detected.map { "\($0) (small model)" } ?? "unclear"
                if let detected {
                    transcribe(in: detected)
                } else if sure {
                    transcribe(in: String(locale.prefix(2)))
                } else {
                    whisper.transcribe(audio, language: nil) { done($0) }
                }
            }
        } else if sure || languages.count == 1 {
            diagnostics.errors["whisper-language"] = "from Apple"
            transcribe(in: String(locale.prefix(2)))
        } else {
            diagnostics.errors["whisper-language"] = "detected by the large model"
            whisper.transcribe(audio, language: nil) { result in
                // A language the user doesn't speak means Whisper misheard it: transcribe in Apple's language.
                if let result, !languages.contains(result.language) {
                    transcribe(in: String(locale.prefix(2)))
                } else {
                    done(result)
                }
            }
        }
    }

    private func stopAudio(then: (() -> Void)? = nil) {
        session += 1  // a start still in progress must not report back
        audioQueue.async { [weak self] in
            if let engine = self?.engine {
                if engine.isRunning { engine.stop() }
                engine.inputNode.removeTap(onBus: 0)
                self?.engine = nil
            }
            if let then { DispatchQueue.main.async(execute: then) }
        }
    }

    // MARK: Audio helpers

    private func store(_ buffer: AVAudioPCMBuffer) {
        bufferLock.lock()
        buffers.append(buffer)
        bufferLock.unlock()
    }

    private func noteSent(_ buffer: AVAudioPCMBuffer) {
        bufferLock.lock()
        sentDuration += Self.duration(buffer)
        bufferLock.unlock()
    }

    private func notePause() {
        bufferLock.lock()
        sentPauses.append(sentDuration)
        bufferLock.unlock()
    }

    /// Ends a sentence at each pause, using the word timings of a final result. A pause is noted after the kept
    /// gap, so place it mid-gap; the next sentence starts right after the gap.
    static func breakSentences(_ text: inout TranscriptAccumulator, segments: [SFTranscriptionSegment],
                               pauses: [Double]) {
        let earlier = text.committed.joined(separator: " ").split(separator: " ").count
        for pause in pauses {
            let position = pause - SilenceGate().keepSilence / 2
            // A segment can hold several words ("ship in the order today"), so count words, not segments.
            let words = segments.filter { $0.timestamp < position }.reduce(0) { $0 + $1.substring.split(separator: " ").count }
            text.markSentenceEnd(afterWord: earlier + words)
        }
    }

    static func duration(_ buffer: AVAudioPCMBuffer) -> Double {
        Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
    }

    /// RMS of the first channel.
    static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        if let data = buffer.floatChannelData {
            return SilenceGate.rms(UnsafeBufferPointer(start: data[0], count: frames))
        }
        if let data = buffer.int16ChannelData {
            let samples = UnsafeBufferPointer(start: data[0], count: frames).map { Float($0) / 32768 }
            return samples.withUnsafeBufferPointer { SilenceGate.rms($0) }
        }
        return 1  // unknown format: never treat as silence
    }

    private static func confidence(_ result: SFSpeechRecognitionResult) -> Double? {
        let segments = result.bestTranscription.segments
        guard !segments.isEmpty else { return nil }
        return segments.map { Double($0.confidence) }.reduce(0, +) / Double(segments.count)
    }

    /// The tap reuses its buffer, so keep a copy for the re-run passes.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.format.isInterleaved ? channels : 1
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<(buffer.format.isInterleaved ? 1 : channels) { dst[ch].update(from: src[ch], count: frames * stride) }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<(buffer.format.isInterleaved ? 1 : channels) { dst[ch].update(from: src[ch], count: frames * stride) }
        } else {
            return nil
        }
        return copy
    }

    private static func readBuffers(_ url: URL) throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: url)
        var result: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            result.append(buffer)
        }
        return result
    }
}
