import AppKit
import ApplicationServices
import MurmurCore

/// After a dictation is pasted, watches that text field for up to two minutes. When the user fixes a dictated word
/// by hand (or accepts a keyboard autocorrection) and the new spelling is unusual, the fix is reported for learning.
final class CorrectionWatcher {
    var onLearned: (([LearnedCorrection]) -> Void)?

    private var timer: Timer?
    private var element: AXUIElement?
    private var inserted = ""
    private var cursorHint = 0
    private var language = "en"
    private var started = Date()
    private var baseline: String?
    private var insertedAt = 0
    private var lastValue = ""
    private var lastEvaluated = ""
    private var stableTicks = 0
    private var learned = Set<LearnedCorrection>()

    func watch(element: AXUIElement, inserted: String, cursorHint: Int, language: String) {
        stop()
        self.element = element
        self.inserted = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cursorHint = cursorHint
        self.language = language.isEmpty ? "en" : language
        started = Date()
        baseline = nil
        lastEvaluated = ""
        stableTicks = 0
        learned = []
        guard !self.inserted.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if baseline != nil, lastValue != lastEvaluated { evaluate(lastValue) }
        element = nil
        baseline = nil
    }

    private func tick() {
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed < 120, let element, let value = Self.value(of: element) else {
            stop()
            return
        }
        guard baseline != nil else {
            // Wait for the paste to land, then remember where the dictated text sits.
            if let location = Self.nearestOccurrence(of: inserted, in: value, near: cursorHint) {
                baseline = value
                insertedAt = location
                lastValue = value
                lastEvaluated = value
            } else if elapsed > 4 {
                stop()  // field can't be read or the text never arrived
            }
            return
        }
        if value != lastValue {
            lastValue = value
            stableTicks = 0
        } else {
            stableTicks += 1
            // Evaluate once typing pauses, so half-typed words aren't learned.
            if stableTicks == 2, value != lastEvaluated { evaluate(value) }
        }
    }

    private func evaluate(_ value: String) {
        lastEvaluated = value
        guard let baseline else { return }
        let found = CorrectionLearner.corrections(baseline: baseline, inserted: inserted, insertedAt: insertedAt,
                                                  current: value) { [language] in Self.isUnusual($0, language: language) }
        let new = found.filter { !learned.contains($0) }
        guard !new.isEmpty else { return }
        learned.formUnion(new)
        onLearned?(new)
    }

    /// Names, jargon and odd casing are worth learning; ordinary dictionary words are not.
    static func isUnusual(_ word: String, language: String) -> Bool {
        if word.contains(where: \.isNumber) || word.dropFirst().contains(where: \.isUppercase) { return true }
        let checker = NSSpellChecker.shared
        guard let lang = checker.availableLanguages.first(where: { $0.hasPrefix(language) }) else {
            return word.first?.isUppercase == true
        }
        let misspelled = checker.checkSpelling(of: word, startingAt: 0, language: lang, wrap: false,
                                               inSpellDocumentWithTag: 0, wordCount: nil)
        return misspelled.location != NSNotFound
    }

    static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func nearestOccurrence(of needle: String, in haystack: String, near hint: Int) -> Int? {
        let ns = haystack as NSString
        var best: Int?
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: needle, options: [], range: search)
            guard r.location != NSNotFound else { break }
            if best == nil || abs(r.location - hint) < abs(best! - hint) { best = r.location }
            let next = r.location + 1
            guard next < ns.length else { break }
            search = NSRange(location: next, length: ns.length - next)
        }
        return best
    }
}
