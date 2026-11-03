import Foundation

/// Writing styles: Formal, Casual, Very casual and Excited.
public enum WritingStyle: String, Codable, CaseIterable {
    case formal      // Caps + punctuation
    case casual      // Caps + less punctuation
    case veryCasual  // No caps + less punctuation
    case excited     // More exclamations

    public var title: String {
        switch self {
        case .formal: return "Formal."
        case .casual: return "Casual"
        case .veryCasual: return "very casual"
        case .excited: return "Excited!"
        }
    }
}

/// Auto Cleanup level (Wispr's EditingStrength: VERBATIM / LIGHT / MEDIUM / HEAVY).
public enum CleanupLevel: String, Codable, CaseIterable {
    case none    // Transcribe exactly what was said
    case light   // Remove filler words, fix grammar
    case medium  // Edit for clarity and conciseness
    case high    // Rewrite for brevity and polish

    public var title: String {
        switch self {
        case .none: return "None (verbatim)"
        case .light: return "Light"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

/// Category of the app being dictated into; selects which style applies.
public enum AppCategory: String, Codable, CaseIterable {
    case personal, work, email, ai, developer, other
}

public struct DictionaryEntry: Codable, Equatable {
    public var word: String
    /// Spoken/misrecognised forms that should be corrected to `word`.
    public var misspellings: [String]?
    public var starred: Bool?
    /// Learned automatically from a correction the user made.
    public var learned: Bool?

    public init(word: String, misspellings: [String]? = nil, starred: Bool? = nil, learned: Bool? = nil) {
        self.word = word
        self.misspellings = misspellings
        self.starred = starred
        self.learned = learned
    }
}

public struct Snippet: Codable, Equatable {
    public var trigger: String
    public var expansion: String

    public init(trigger: String, expansion: String) {
        self.trigger = trigger
        self.expansion = expansion
    }
}

public struct StyleConfig: Codable, Equatable {
    public var personal: WritingStyle = .casual
    public var work: WritingStyle = .formal
    public var email: WritingStyle = .formal
    public var other: WritingStyle = .formal

    public init() {}

    public func style(for category: AppCategory) -> WritingStyle {
        switch category {
        case .personal: return personal
        case .work: return work
        case .email: return email
        case .ai, .developer, .other: return other
        }
    }

    public mutating func set(_ style: WritingStyle, for category: AppCategory) {
        switch category {
        case .personal: personal = style
        case .work: work = style
        case .email: email = style
        case .ai, .developer, .other: other = style
        }
    }
}

public struct LLMConfig: Codable, Equatable {
    public var enabled: Bool = true
    public var model: String = "claude-sonnet-5-5"
    /// Falls back to the ANTHROPIC_API_KEY environment variable when empty.
    public var apiKey: String = ""
    public var timeoutSeconds: Double = 12

    public init() {}

    /// Missing fields take their defaults, so a hand-written `{"apiKey": "…"}` (e.g. from the installer) works.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LLMConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? d.apiKey
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
    }

    public var resolvedKey: String? {
        if !apiKey.isEmpty { return apiKey }
        let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        return env.isEmpty ? nil : env
    }
}

public struct MeetingConfig: Codable, Equatable {
    /// Notice calls in any app that uses the microphone (Teams, Meet, WhatsApp, Phone, Zoom…).
    public var autoDetect: Bool = true
    /// Write a summary when the meeting ends.
    public var summarize: Bool = true
    /// Open the notes when the summary is ready.
    public var openWhenReady: Bool = true
    /// When a call is detected, ask "Record meeting?" instead of starting at once.
    public var askBeforeRecording: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MeetingConfig()
        autoDetect = try c.decodeIfPresent(Bool.self, forKey: .autoDetect) ?? d.autoDetect
        summarize = try c.decodeIfPresent(Bool.self, forKey: .summarize) ?? d.summarize
        openWhenReady = try c.decodeIfPresent(Bool.self, forKey: .openWhenReady) ?? d.openWhenReady
        askBeforeRecording = try c.decodeIfPresent(Bool.self, forKey: .askBeforeRecording) ?? d.askBeforeRecording
    }
}

public struct MurmurConfig: Codable, Equatable {
    /// Languages you speak, e.g. ["en-US", "pl-PL", "ru-RU"]. With more than one, each dictation is recognized in
    /// all of them in parallel and the best match is kept (automatic language detection).
    public var languages: [String] = ["en-US"]
    /// Push-to-talk key: fn, rightOption, rightCommand or rightControl.
    public var hotkey: String = "fn"
    public var cleanup: CleanupLevel = .light
    public var styles = StyleConfig()
    public var dictionary: [DictionaryEntry] = []
    public var snippets: [Snippet] = []
    public var llm = LLMConfig()
    public var playSounds: Bool = true
    public var restoreClipboard: Bool = true
    /// Learn words you correct after dictating.
    public var autoLearnDictionary: Bool = true
    public var meetings = MeetingConfig()
    /// "auto" (prefer a connected headset, then an external mic, then built-in) or a device UID.
    public var microphone: String = MicrophonePicker.automatic
    /// "whisper" (local whisper.cpp, falls back to Apple) or "apple" (macOS speech recognition only).
    public var speechEngine: String = "whisper"
    /// Whisper model file in Murmur's Models folder.
    public var whisperModel: String = "ggml-large-v3-turbo.bin"
    /// Small Whisper model that only detects the language (fast), so the large one can transcribe with a fitted window.
    public var whisperLanguageModel: String = "ggml-base.bin"

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case languages, hotkey, cleanup, styles, dictionary, snippets, llm, playSounds, restoreClipboard
        case autoLearnDictionary, meetings, microphone, speechEngine, whisperModel, whisperLanguageModel
        case locale // pre-0.2 single-language setting, read only
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(languages, forKey: .languages)
        try c.encode(hotkey, forKey: .hotkey)
        try c.encode(cleanup, forKey: .cleanup)
        try c.encode(styles, forKey: .styles)
        try c.encode(dictionary, forKey: .dictionary)
        try c.encode(snippets, forKey: .snippets)
        try c.encode(llm, forKey: .llm)
        try c.encode(playSounds, forKey: .playSounds)
        try c.encode(restoreClipboard, forKey: .restoreClipboard)
        try c.encode(autoLearnDictionary, forKey: .autoLearnDictionary)
        try c.encode(meetings, forKey: .meetings)
        try c.encode(microphone, forKey: .microphone)
        try c.encode(speechEngine, forKey: .speechEngine)
        try c.encode(whisperModel, forKey: .whisperModel)
        try c.encode(whisperLanguageModel, forKey: .whisperLanguageModel)
    }

    // Every key is optional so hand-edited config files keep working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MurmurConfig()
        if let languages = try c.decodeIfPresent([String].self, forKey: .languages), !languages.isEmpty {
            self.languages = languages
        } else if let locale = try c.decodeIfPresent(String.self, forKey: .locale) {
            languages = [locale]
        } else {
            languages = d.languages
        }
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        cleanup = try c.decodeIfPresent(CleanupLevel.self, forKey: .cleanup) ?? d.cleanup
        styles = try c.decodeIfPresent(StyleConfig.self, forKey: .styles) ?? d.styles
        dictionary = try c.decodeIfPresent([DictionaryEntry].self, forKey: .dictionary) ?? d.dictionary
        snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? d.snippets
        llm = try c.decodeIfPresent(LLMConfig.self, forKey: .llm) ?? d.llm
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? d.playSounds
        restoreClipboard = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? d.restoreClipboard
        autoLearnDictionary = try c.decodeIfPresent(Bool.self, forKey: .autoLearnDictionary) ?? d.autoLearnDictionary
        meetings = try c.decodeIfPresent(MeetingConfig.self, forKey: .meetings) ?? d.meetings
        microphone = try c.decodeIfPresent(String.self, forKey: .microphone) ?? d.microphone
        speechEngine = try c.decodeIfPresent(String.self, forKey: .speechEngine) ?? d.speechEngine
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? d.whisperModel
        whisperLanguageModel = try c.decodeIfPresent(String.self, forKey: .whisperLanguageModel) ?? d.whisperLanguageModel
    }
}

public enum ConfigStore {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Murmur", isDirectory: true)
    }

    public static var configURL: URL { directory.appendingPathComponent("config.json") }
    public static var historyURL: URL { directory.appendingPathComponent("history.jsonl") }
    public static var meetingsDirectory: URL { directory.appendingPathComponent("Meetings", isDirectory: true) }
    public static var modelsDirectory: URL { directory.appendingPathComponent("Models", isDirectory: true) }

    public static func load() -> MurmurConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(MurmurConfig.self, from: data) else {
            let config = MurmurConfig()
            save(config)
            return config
        }
        return config
    }

    public static func save(_ config: MurmurConfig) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: configURL, options: .atomic)
        // The file may hold an API key.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }
}
