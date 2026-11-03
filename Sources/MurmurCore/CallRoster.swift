import Foundation

/// Reads who is on a call, and who is speaking, from the text a call app exposes to Accessibility — as meeting
/// note-takers do: Teams video tiles ("Maria Nowak, muted"), its roster items
/// ("calling-roster-item-…"), active-speaker markers ("…, speaking"), and the name on a one-to-one call window
/// (WhatsApp, FaceTime).
public enum CallRoster {
    /// One accessibility element's text.
    public struct Element {
        public var role: String
        public var texts: [String]
        public var domID: String?
        public init(role: String, texts: [String], domID: String? = nil) {
            self.role = role
            self.texts = texts
            self.domID = domID
        }
    }

    public struct Reading: Equatable {
        public var participants: [String] = []
        public var speaking: [String] = []
        public init() {}
    }

    static let speakingMarkers = ["is speaking", "speaking", "active speaker", "mówi", "говорит", "spricht", "parle",
                                  "está hablando"]
    static let statusWords: Set<String> = [
        "muted", "unmuted", "mute", "unmute", "speaking", "is speaking", "active speaker", "video", "video off",
        "video on", "video is off", "camera", "camera off", "microphone", "mic", "mic off", "share", "chat", "more",
        "raise", "raise hand", "react", "reactions", "leave", "end call", "hang up", "participants", "people",
        "roster", "meeting", "call", "calling", "ringing", "connecting", "reconnecting", "you", "me", "host",
        "organizer", "guest", "presenter", "attendee", "in this meeting", "in the lobby", "options", "settings",
        "view", "apps", "whatsapp", "facetime", "microsoft teams", "teams", "zoom", "google meet", "slack",
        "end-to-end encrypted", "encrypted", "wyciszony", "wyciszona", "mikrofon", "kamera", "rozmowa", "połączenie",
        "dzwonienie", "łączenie", "zakończ", "звонок", "вызов", "микрофон", "камера", "pinned", "spotlighted",
        "hand raised", "add people", "invite", "search", "close", "minimize", "zoom in", "full screen", "audio",
        "speaker", "headphones", "on hold", "join", "lobby", "waiting", "recording", "transcription"]

    /// Removes "(You)", "(Guest)", "(Organizer)", "(External)"… and trims.
    static func cleanName(_ s: String) -> String {
        s.replacingOccurrences(of: "\\((you|ty|guest|gość|host|organizer|organizator|external|unverified|presenter)\\)",
                               with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".:-–")))
    }

    /// A person's name: 2–60 characters, up to five words, mostly letters, not a control or status label.
    public static func looksLikeName(_ raw: String) -> Bool {
        let s = cleanName(raw)
        guard (2...60).contains(s.count), s.split(separator: " ").count <= 5 else { return false }
        let lower = s.lowercased()
        if statusWords.contains(lower) || speakingMarkers.contains(where: { lower.contains($0) }) { return false }
        if lower.hasPrefix("you ") || lower.hasPrefix("your ") || lower.contains("http") || lower.contains("@") { return false }
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        guard letters >= 2, digits == 0, Double(letters) / Double(s.count) > 0.7 else { return false }
        // "НЕ ИСПОЛЬЗУЙТЕ ПЕРЕВОДЫ" is a shout in a chat, not a name.
        if s.split(separator: " ").count > 1, s == s.uppercased(), s != s.lowercased() { return false }
        // Names start with a capital letter (in any script).
        return s.first.map { $0.isUppercase } ?? false
    }

    /// The name in a label like "Maria Nowak, muted, video off" or "Maria Nowak is speaking".
    static func name(in text: String) -> String? {
        var t = text
        for m in [" is speaking", " mówi", " говорит", " spricht"] {
            if let r = t.range(of: m, options: .caseInsensitive) { t = String(t[..<r.lowerBound]) }
        }
        return t.components(separatedBy: CharacterSet(charactersIn: ",;|·•\n")).map(cleanName).first(where: looksLikeName)
    }

    /// Interprets one scan of the call app. `oneToOne`: the app's calls are usually with one person (WhatsApp,
    /// FaceTime, Phone), so a name-like window title is the other person.
    public static func read(_ elements: [Element], windowTitles: [String], oneToOne: Bool) -> Reading {
        var reading = Reading()
        func add(_ name: String, speaking: Bool = false) {
            let n = cleanName(name)
            if !reading.participants.contains(where: { SpeakerNames.isSame($0, n) }) { reading.participants.append(n) }
            if speaking, !reading.speaking.contains(where: { SpeakerNames.isSame($0, n) }) { reading.speaking.append(n) }
        }
        for e in elements {
            let id = e.domID?.lowercased() ?? ""
            let rosterItem = id.hasPrefix("calling-roster-item-") || id.hasPrefix("roster-item") || id.hasPrefix("participant-")
            for text in e.texts where text.count <= 120 && !text.contains("\n") {
                let lower = text.lowercased()
                if lower.contains("you are speaking") || lower.contains("jesteś wyciszony") { continue }
                // Chat lists (a muted WhatsApp group: "Message from Maryna, …, Muted") are not call tiles.
                if ["message from", "wiadomość od", "сообщение от", "double tap", "received in", "sent to"]
                    .contains(where: lower.contains) { continue }
                let isSpeaking = speakingMarkers.contains { m in
                    lower.range(of: "(^|[ ,;])" + NSRegularExpression.escapedPattern(for: m) + "($|[ ,;.])",
                                options: .regularExpression) != nil
                }
                let isTile = lower.contains("muted") || lower.contains("unmuted") || lower.contains("wyciszon")
                    || lower.contains("video is off") || lower.contains("camera off")
                guard rosterItem || isSpeaking || isTile, let name = name(in: text) else { continue }
                add(name, speaking: isSpeaking)
            }
        }
        if oneToOne {
            for title in windowTitles {
                let n = cleanName(title)
                if looksLikeName(n) { add(n) }
            }
        }
        return reading
    }
}
