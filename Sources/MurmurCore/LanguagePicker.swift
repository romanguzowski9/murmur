import Foundation
import NaturalLanguage

/// One recognizer's result for the same audio.
public struct RecognitionCandidate {
    public var locale: String
    public var text: String
    /// Mean segment confidence from the recognizer (0...1), or nil when not reported.
    public var confidence: Double?

    public init(locale: String, text: String, confidence: Double?) {
        self.locale = locale
        self.text = text
        self.confidence = confidence
    }

    public var language: String { String(locale.prefix(2)).lowercased() }
}

/// Picks the spoken language when several recognizers (e.g. en/pl/ru) transcribe the same audio in parallel.
/// A recognizer fed the wrong language tends to produce low-confidence text that a language identifier does not
/// attribute to that recognizer's language, so both signals are combined.
public enum LanguagePicker {
    /// Some on-device models (Polish, at least on macOS 27) report 0 for every segment; treat that as unknown.
    static let unknownConfidence = 0.6

    static func effectiveConfidence(_ c: RecognitionCandidate) -> Double? {
        guard let confidence = c.confidence, confidence > 0 else { return nil }
        return confidence
    }

    /// Recognizer confidence + how much the text looks like the recognizer's language + how much of the audio it
    /// covered (a recognizer hearing a foreign language tends to drop most of it).
    public static func score(_ c: RecognitionCandidate, among languages: [String], longest: Int) -> Double {
        guard !c.text.trimmed.isEmpty else { return -1 }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = languages.map { NLLanguage(rawValue: $0) }
        recognizer.processString(c.text)
        let agreement = recognizer.languageHypotheses(withMaximum: languages.count)[NLLanguage(rawValue: c.language)] ?? 0
        let coverage = longest > 0 ? Double(c.text.count) / Double(longest) : 0
        return (effectiveConfidence(c) ?? unknownConfidence) + agreement + 0.3 * coverage
    }

    /// Whether a single result is trustworthy enough to skip trying the other languages.
    public static func isConfident(_ c: RecognitionCandidate, among languages: [String]) -> Bool {
        guard c.text.wordCount >= 3, let confidence = effectiveConfidence(c), confidence >= 0.6 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = languages.map { NLLanguage(rawValue: $0) }
        recognizer.processString(c.text)
        return (recognizer.languageHypotheses(withMaximum: languages.count)[NLLanguage(rawValue: c.language)] ?? 0) >= 0.8
    }

    public static func pick(_ candidates: [RecognitionCandidate]) -> RecognitionCandidate? {
        let languages = Array(Set(candidates.map(\.language)))
        let longest = candidates.map(\.text.count).max() ?? 0
        return candidates.max { score($0, among: languages, longest: longest) < score($1, among: languages, longest: longest) }
    }
}

/// The language of a line of text, for transcripts saved without one per line.
public enum LanguageGuess {
    static let candidates: [NLLanguage] = [.polish, .russian, .english, .ukrainian, .german, .french, .spanish,
                                           .italian, .portuguese, .czech]

    /// Nil when the line is too short or the guess too uncertain.
    public static func of(_ text: String) -> String? {
        guard text.wordCount >= 2 else { return nil }
        let r = NLLanguageRecognizer()
        r.languageConstraints = candidates
        r.processString(text)
        guard let (language, p) = r.languageHypotheses(withMaximum: 1).first, p >= 0.5 else { return nil }
        return language.rawValue
    }
}
