import Foundation

/// The parts of using Whisper that don't need the server: request settings and checks on what comes back.
public enum WhisperText {
    /// Whisper always encodes a 30-second window (1500 frames, 50 per second); a window fitted to the recording is
    /// several times faster (≈0.5 s instead of ≈1.3 s). It only works with the language given up front, and it must
    /// stay close to the audio's length: a much longer window makes Whisper repeat sentences.
    public static func audioContext(seconds: Double) -> Int? {
        guard seconds < 28 else { return nil }
        let frames = Int(ceil((seconds + 0.3) * 50 / 32)) * 32
        // Below ~5 s of window Whisper starts inventing text ("and I'll see you next time").
        return min(1500, max(256, frames))
    }

    /// Joins Whisper's segments (each starts with its own space; breaks can fall inside a word), dropping a segment
    /// that repeats an earlier one word for word, which is how Whisper hallucinates past the end of the audio.
    public static func join(_ segments: [String]) -> String {
        var seen = Set<String>()
        var out = ""
        for s in segments {
            let key = s.trimmed.lowercased()
            if key.count > 12, seen.contains(key) { continue }
            seen.insert(key)
            out += s.replacingOccurrences(of: "\n", with: "")
        }
        return out.replacingOccurrences(of: "  ", with: " ").trimmed
    }

    /// Text Whisper is known to invent for silence or noise (subtitle credits from its training data).
    public static func isHallucination(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if t.isEmpty { return true }
        let credits = ["amara.org", "субтитр", "napisy stworzone", "napisy wykonane", "редактор субтитров",
                       "subtitles by", "transcribed by", "tłumaczenie i napisy"]
        if credits.contains(where: { t.contains($0) }) { return true }
        let alone = ["dziękuję", "dziękuję za uwagę", "dzięki za uwagę", "dziękuję bardzo", "спасибо",
                     "спасибо за внимание", "продолжение следует", "thank you", "thanks for watching",
                     "thank you for watching", "you", "bye", "do zobaczenia", "до свидания"]
        return alone.contains(t)
    }

    /// Whisper's text looks cut short or invented next to what Apple's recognizer heard in the same audio.
    public static func looksTruncated(_ whisper: String, apple: String) -> Bool {
        let a = apple.wordCount, w = whisper.wordCount
        return a >= 4 && w * 2 < a
    }

    /// The most likely of the user's languages from Whisper's language probabilities, if any is plausible.
    public static func likeliest(_ probabilities: [String: Double], among languages: [String]) -> String? {
        guard let best = languages.max(by: { (probabilities[$0] ?? 0) < (probabilities[$1] ?? 0) }),
              (probabilities[best] ?? 0) >= 0.15 else { return nil }
        return best
    }

    /// Whisper's language code ("pl") as one of the user's locales ("pl-PL").
    public static func locale(_ code: String, among locales: [String]) -> String {
        locales.first { $0.lowercased().hasPrefix(code.lowercased().prefix(2)) } ?? code
    }
}
