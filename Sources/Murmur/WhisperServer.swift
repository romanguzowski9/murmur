import AVFoundation
import Foundation
import MurmurCore

/// Runs whisper.cpp's `whisper-server` (installed with Homebrew) with the model kept in memory, and transcribes
/// recorded audio through its local HTTP endpoint. Nothing leaves the Mac.
final class WhisperServer {
    enum State: Equatable {
        case off, missingProgram, missingModel, loading, ready, failed(String)
    }

    /// The app's server; self-tests run their own on another port so they don't disturb it.
    let port: Int
    private(set) var state = State.off {
        didSet { if state != oldValue { DispatchQueue.main.async { self.onStateChange?(self.state) } } }
    }
    var onStateChange: ((State) -> Void)?
    var isReady: Bool { state == .ready }

    private var process: Process?
    private var restarts = 0
    private var stopping = false
    private let modelURL: URL

    init(model: String, port: Int = 8178) {
        modelURL = ConfigStore.modelsDirectory.appendingPathComponent(model)
        self.port = port
    }

    /// Starts the server and waits (running the main run loop) until the model is loaded; for command-line tests.
    static func startAndWait(model: String, port: Int) -> WhisperServer? {
        let server = WhisperServer(model: model, port: port)
        server.start()
        let deadline = Date().addingTimeInterval(90)
        while server.state == .loading, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        return server.isReady ? server : nil
    }

    /// The copy inside Murmur.app (release builds), else one installed with Homebrew.
    static var program: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/whisper-server").path
        return [bundled, "/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
            .map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var modelName: String { modelURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "") }

    func start() {
        guard process == nil else { return }
        guard let program = Self.program else { state = .missingProgram; return }
        guard FileManager.default.fileExists(atPath: modelURL.path) else { state = .missingModel; return }
        stopping = false
        // A server left behind by a crashed Murmur would hold the port.
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        cleanup.arguments = ["-f", "whisper-server.*--port \(port)"]
        try? cleanup.run()
        cleanup.waitUntilExit()

        let p = Process()
        p.executableURL = program
        p.arguments = ["-m", modelURL.path, "--host", "127.0.0.1", "--port", "\(port)", "-l", "auto",
                       "-t", "4", "-sns"]
        let log = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/whisper-server.log")
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        p.standardOutput = try? FileHandle(forWritingTo: log)
        p.standardError = p.standardOutput
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                if self.stopping { self.state = .off; return }
                // Crashed: try again a few times, then stay on Apple's recognizer.
                self.state = .failed("whisper-server stopped")
                if self.restarts < 3 {
                    self.restarts += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.start() }
                }
            }
        }
        do {
            try p.run()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        process = p
        state = .loading
        waitUntilReady(tries: 120)
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
        state = .off
    }

    private func waitUntilReady(tries: Int) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            guard let self, self.process != nil else { return }
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                self.state = .ready
            } else if tries > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { self.waitUntilReady(tries: tries - 1) }
            } else {
                self.state = .failed("the model didn't load")
            }
        }.resume()
    }

    struct Result {
        var text: String
        var language: String
        var seconds: Double
        /// Whisper's segments, timed from the start of the audio (used to tell speakers apart within a passage).
        var segments: [Segment] = []
    }

    struct Segment {
        var start: Double
        var end: Double
        /// As Whisper gave it, leading space included.
        var text: String
    }

    /// Transcribes audio in a known language (fast: the encoder window is fitted to the recording).
    /// `language` nil lets Whisper detect it, which costs about two seconds more.
    /// The most likely of `languages` ("pl", "ru", "en") for the audio; meant for the small model, which answers in
    /// about 0.15 s. Nil when it can't tell.
    func detectLanguage(_ buffers: [AVAudioPCMBuffer], among languages: [String], completion: @escaping (String?) -> Void) {
        guard isReady, let (wav, seconds) = Self.wav(buffers), seconds >= 0.3 else { return completion(nil) }
        post(wav: wav, fields: ["response_format": "verbose_json", "language": "auto", "detect_language": "true"],
             timeout: 5) { json in
            let probabilities = (json?["language_probabilities"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            completion(WhisperText.likeliest(probabilities, among: languages))
        }
    }

    /// Sends a WAV file and form fields to the server; the JSON answer (or nil) comes back on the main queue.
    private func post(wav: Data, fields: [String: String], timeout: TimeInterval,
                      completion: @escaping ([String: Any]?) -> Void) {
        let boundary = "murmur-\(UUID().uuidString)"
        var body = Data()
        for (k, v) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        URLSession.shared.uploadTask(with: request, from: body) { data, response, _ in
            let json = (response as? HTTPURLResponse)?.statusCode == 200
                ? data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } : nil
            DispatchQueue.main.async { completion(json) }
        }.resume()
    }

    /// No initial prompt is sent: in tests, dictionary words as a prompt made Polish worse (Whisper copies the
    /// prompt's style); Murmur's dictionary rules fix spellings afterwards instead.
    /// `fullWindow` skips the fitted window (slower, for a second try).
    func transcribe(_ buffers: [AVAudioPCMBuffer], language: String?, fullWindow: Bool = false,
                    completion: @escaping (Result?) -> Void) {
        guard isReady, let (wav, seconds) = Self.wav(buffers), seconds >= 0.3 else { return completion(nil) }
        var fields = ["response_format": "verbose_json", "temperature": "0", "best_of": "1",
                      "language": language ?? "auto"]
        if language != nil, !fullWindow, let ctx = WhisperText.audioContext(seconds: seconds) { fields["audio_ctx"] = "\(ctx)" }

        let started = Date()
        post(wav: wav, fields: fields, timeout: 8 + seconds * 0.6) { json in
            guard let json else { return completion(nil) }
            let raw = json["segments"] as? [[String: Any]]
            let segments = raw?.compactMap { $0["text"] as? String }
            let text = segments.map(WhisperText.join) ?? WhisperText.join([json["text"] as? String ?? ""])
            let lang = Self.languageCode(json["language"] as? String) ?? language ?? ""
            let timed = (raw ?? []).compactMap { s -> Segment? in
                guard let t = s["text"] as? String, let a = (s["start"] as? NSNumber)?.doubleValue,
                      let b = (s["end"] as? NSNumber)?.doubleValue, b > a else { return nil }
                // Raw text: a segment can end mid-word, so its leading space is what separates words.
                let clean = WhisperText.join([t])
                return clean.isEmpty || WhisperText.isHallucination(clean) ? nil : Segment(start: a, end: b, text: t)
            }
            completion(Result(text: WhisperText.isHallucination(text) ? "" : text, language: lang,
                              seconds: Date().timeIntervalSince(started), segments: timed))
        }
    }

    /// "polish" → "pl".
    static func languageCode(_ name: String?) -> String? {
        guard let name = name?.lowercased(), !name.isEmpty else { return nil }
        if name.count == 2 { return name }
        return ["polish": "pl", "russian": "ru", "english": "en", "german": "de", "french": "fr", "spanish": "es",
                "ukrainian": "uk", "italian": "it", "portuguese": "pt", "dutch": "nl", "czech": "cs",
                "belarusian": "be", "chinese": "zh"][name] ?? String(name.prefix(2))
    }

    /// Converts captured buffers (any rate and channel count) to 16 kHz mono 16-bit WAV, Whisper's input format.
    static func wav(_ buffers: [AVAudioPCMBuffer]) -> (Data, Double)? {
        guard let first = buffers.first,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: first.format, to: target) else { return nil }
        var samples: [Float] = []
        for buffer in buffers where buffer.format == first.format {
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { continue }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if let channel = out.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            }
        }
        // Nothing above the noise floor: don't let Whisper invent words for silence.
        let window = 320
        var loudest: Float = 0
        var i = 0
        while i < samples.count {
            let slice = samples[i..<min(samples.count, i + window)]
            loudest = max(loudest, sqrt(slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)))
            i += window
        }
        guard !samples.isEmpty, loudest > 0.004 else { return nil }
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var header = Data()
        func put<T>(_ value: T) { var v = value; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        header.append("RIFF".data(using: .ascii)!)
        put(UInt32(36 + pcm.count).littleEndian)
        header.append("WAVEfmt ".data(using: .ascii)!)
        put(UInt32(16).littleEndian)
        put(UInt16(1).littleEndian)        // PCM
        put(UInt16(1).littleEndian)        // mono
        put(UInt32(16_000).littleEndian)
        put(UInt32(32_000).littleEndian)   // byte rate
        put(UInt16(2).littleEndian)        // block align
        put(UInt16(16).littleEndian)       // bits per sample
        header.append("data".data(using: .ascii)!)
        put(UInt32(pcm.count).littleEndian)
        return (header + pcm, Double(samples.count) / 16_000)
    }
}
