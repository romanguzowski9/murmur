import Foundation

/// Everything the local rules engine needs to format one dictation.
public struct FormatContext {
    public var category: AppCategory
    public var style: WritingStyle
    public var cleanup: CleanupLevel
    public var dictionary: [DictionaryEntry]
    public var snippets: [Snippet]
    /// Two-letter language code of the recognizer ("en", "pl", ...).
    public var language: String

    public init(category: AppCategory = .other, style: WritingStyle = .formal, cleanup: CleanupLevel = .light,
                dictionary: [DictionaryEntry] = [], snippets: [Snippet] = [], language: String = "en") {
        self.category = category
        self.style = style
        self.cleanup = cleanup
        self.dictionary = dictionary
        self.snippets = snippets
        self.language = language
    }

    var keepCase: Set<String> { Set(dictionary.map { $0.word.lowercased() }) }
}

// MARK: - Regex helpers

func regexReplace(_ s: String, _ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive],
                  _ transform: ([String]) -> String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
    let ns = s as NSString
    let result = NSMutableString(string: s)
    for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        result.replaceCharacters(in: m.range, with: transform(groups))
    }
    return result as String
}

func regexReplace(_ s: String, _ pattern: String, template: String,
                  _ options: NSRegularExpression.Options = [.caseInsensitive]) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
    return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                       withTemplate: template)
}

/// Matches a phrase as whole words, tolerating extra spaces/commas between its words.
func phrasePattern(_ phrase: String) -> String {
    let parts = phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
    return "(?<![\\p{L}\\p{N}])" + parts.joined(separator: "[\\s,]+") + "(?![\\p{L}\\p{N}])"
}

extension StringProtocol {
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    public var wordCount: Int { split(whereSeparator: { $0.isWhitespace }).count }
}

/// Swaps text that later rules must not touch (snippet expansions) for private-use placeholders.
public struct Protector {
    public private(set) var values: [String] = []

    public init() {}

    public mutating func protect(_ s: String) -> String {
        values.append(s)
        return "\u{E000}\(values.count - 1)\u{E001}"
    }

    public func restore(_ s: String) -> String {
        regexReplace(s, "\u{E000}(\\d+)\u{E001}", []) { g in
            guard let i = Int(g[1]), i < values.count else { return "" }
            return values[i]
        }
    }
}

// MARK: - Local rules engine

/// Deterministic implementation of the recovered Flow formatting rules. Used on its own when no LLM is configured,
/// and as the fallback when the LLM pass fails.
public enum LocalFormatter {
    public static func format(_ raw: String, _ ctx: FormatContext) -> String {
        var protector = Protector()
        var t = regexReplace(raw, "[ \\t]+", template: " ").trimmed
        t = applySnippets(t, ctx.snippets, &protector)
        t = applyDictionary(t, ctx.dictionary)
        t = applySpokenCommands(t)
        if ctx.cleanup != .none {
            t = applyBacktrack(t)
            t = removeFillers(t)
            t = removeStutters(t)
            t = tidy(t)
            t = formatList(t)
            if ctx.category == .email { t = formatEmail(t) }
            t = applyStyle(t, ctx)
        }
        t = tidy(t)
        return protector.restore(t)
    }

    // MARK: Snippets & dictionary

    public static func applySnippets(_ text: String, _ snippets: [Snippet], _ protector: inout Protector) -> String {
        var t = text
        for snippet in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) where !snippet.trigger.trimmed.isEmpty {
            t = regexReplace(t, phrasePattern(snippet.trigger)) { _ in protector.protect(snippet.expansion) }
        }
        return t
    }

    public static func applyDictionary(_ text: String, _ dictionary: [DictionaryEntry]) -> String {
        var t = text
        for entry in dictionary where !entry.word.trimmed.isEmpty {
            for wrong in entry.misspellings ?? [] where !wrong.trimmed.isEmpty {
                t = regexReplace(t, phrasePattern(wrong)) { _ in entry.word }
            }
            // Enforce the dictionary spelling/casing.
            t = regexReplace(t, phrasePattern(entry.word)) { _ in entry.word }
        }
        return t
    }

    // MARK: Spoken commands

    static let spokenCommands: [(String, String)] = [
        ("new paragraph", "\n\n"), ("nowy akapit", "\n\n"), ("новый абзац", "\n\n"),
        ("new line", "\n"), ("next line", "\n"), ("nowa linia", "\n"), ("nowa linijka", "\n"), ("новая строка", "\n"),
        ("question mark", "? "), ("znak zapytania", "? "), ("вопросительный знак", "? "),
        ("exclamation point", "! "), ("exclamation mark", "! "), ("wykrzyknik", "! "),
        ("full stop", ". "),
    ]

    static func applySpokenCommands(_ text: String) -> String {
        var t = text
        for (phrase, replacement) in spokenCommands {
            t = regexReplace(t, "[ \\t]*[,.]?[ \\t]*" + phrasePattern(phrase) + "[,.]?[ \\t]*") { _ in replacement }
        }
        return t
    }

    // MARK: Backtrack

    static let eraseMarkers = ["scratch that", "delete that", "strike that", "forget that", "skreśl to", "wykreśl to", "зачеркни это", "удали это"]
    static let strongMarkers = ["no wait", "wait no", "sorry I meant", "I meant to say", "correction", "nie czekaj",
                                "poprawka", "нет подожди", "нет, подожди", "поправка"]
    static let softMarkers = ["actually", "or rather", "I mean", "właściwie", "to znaczy", "точнее", "вернее"]

    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "fifteen", "twenty", "thirty", "forty", "fifty", "hundred", "thousand", "half",
        "jeden", "dwa", "trzy", "cztery", "pięć", "sześć", "siedem", "osiem", "dziewięć", "dziesięć",
        "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять", "десять",
    ]
    static let dayWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow", "yesterday",
        "poniedziałek", "wtorek", "środa", "środę", "czwartek", "piątek", "sobota", "sobotę", "niedziela", "niedzielę",
        "dzisiaj", "jutro", "wczoraj",
        "понедельник", "вторник", "среда", "среду", "четверг", "пятница", "пятницу", "суббота", "субботу",
        "воскресенье", "сегодня", "завтра", "вчера",
    ]
    static let monthWords: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november",
        "december",
    ]

    static func normalizeWord(_ w: String) -> String {
        w.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    static func wordClass(_ w: String) -> String? {
        let n = normalizeWord(w)
        if n.range(of: "^\\d+([:.,]\\d+)?(am|pm|h|%)?$", options: .regularExpression) != nil { return "number" }
        if numberWords.contains(n) { return "number" }
        if dayWords.contains(n) { return "day" }
        if monthWords.contains(n) { return "month" }
        return nil
    }

    /// Ranges of whitespace-separated words in `s`, as UTF-16 NSRanges.
    static func wordRanges(_ s: String) -> [NSRange] {
        guard let re = try? NSRegularExpression(pattern: "\\S+") else { return [] }
        return re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).map(\.range)
    }

    static func markerRegex() -> NSRegularExpression? {
        let markers = (eraseMarkers + strongMarkers + softMarkers).sorted { $0.count > $1.count }
        let alternation = markers.map { $0.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "[\\s,]+") }.joined(separator: "|")
        let pattern = "[,;]?\\s*(?<![\\p{L}\\p{N}])(" + alternation + ")(?![\\p{L}\\p{N}])[,.;:!]?\\s*"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func applyBacktrack(_ input: String) -> String {
        guard let re = markerRegex() else { return input }
        var text = input
        var searchFrom = 0
        for _ in 0..<32 {
            let ns = text as NSString
            guard searchFrom < ns.length,
                  let m = re.firstMatch(in: text, range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            else { break }
            let marker = regexReplace(ns.substring(with: m.range(at: 1)).lowercased(), "[\\s,]+", template: " ")
            let left = ns.substring(to: m.range.location)
            let right = ns.substring(from: m.range.location + m.range.length)
            let isErase = eraseMarkers.contains(marker)
            let isStrong = strongMarkers.map { $0.lowercased() }.contains(marker)

            // Start of the sentence the marker sits in.
            let leftNS = left as NSString
            let lastStop = leftNS.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?\n"), options: .backwards)
            let sentenceStart = lastStop.location == NSNotFound ? 0 : lastStop.location + 1

            if isErase {
                let kept = leftNS.substring(to: sentenceStart)
                text = kept + (kept.isEmpty ? "" : " ") + right
                searchFrom = (kept as NSString).length
                continue
            }

            // The correction runs to the end of the clause after the marker.
            let rightNS = right as NSString
            let stop = rightNS.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?\n"))
            let clause = stop.location == NSNotFound ? right : rightNS.substring(to: stop.location)
            let rest = stop.location == NSNotFound ? "" : rightNS.substring(from: stop.location)
            let afterWords = clause.split(whereSeparator: { $0.isWhitespace }).map(String.init)

            let sentence = leftNS.substring(from: sentenceStart)
            let ranges = wordRanges(sentence)
            let leftWords = ranges.map { (sentence as NSString).substring(with: $0) }

            var cut: Int?
            if let first = afterWords.first, !leftWords.isEmpty {
                let firstNorm = normalizeWord(first)
                // 1. The correction repeats an earlier word: "to John, no wait, to Mary".
                for i in stride(from: leftWords.count - 1, through: max(0, leftWords.count - 6), by: -1)
                where normalizeWord(leftWords[i]) == firstNorm {
                    cut = i
                    break
                }
                // 2. Same kind of value: "at 2 actually 3", "Tuesday no wait Wednesday".
                if cut == nil, let cls = wordClass(first), afterWords.count <= 4 {
                    for i in stride(from: leftWords.count - 1, through: max(0, leftWords.count - 3), by: -1)
                    where wordClass(leftWords[i]) == cls {
                        cut = i
                        break
                    }
                }
                // 3. Strong markers replace an equally long tail.
                if cut == nil, isStrong, afterWords.count <= 3, leftWords.count >= afterWords.count {
                    cut = leftWords.count - afterWords.count
                }
            }

            guard let cutIndex = cut else {
                if isStrong {
                    text = left + " " + right
                    searchFrom = (left as NSString).length
                } else {
                    // Soft marker used normally ("I actually like it"): leave it.
                    searchFrom = m.range.location + m.range.length
                }
                continue
            }
            let kept = leftNS.substring(to: sentenceStart + ranges[cutIndex].location)
            text = kept + clause.trimmed + rest
            searchFrom = (kept as NSString).length
        }
        return text
    }

    // MARK: Fillers & stutters

    static let fillerPattern = "(?<![\\p{L}\\p{N}'])(?:u+m+|u+h+m*|e+r+m+|e+r+|a+h+|h+m+|m+h+m+|y{3,}|e{3,}|m{3,}|э+м*|м{3,})"
        + "(?![\\p{L}\\p{N}'])[,.…]*"

    static func removeFillers(_ text: String) -> String {
        regexReplace(text, fillerPattern, template: "")
    }

    static let allowedRepeats: Set<String> = ["that", "had", "is", "very", "so", "no", "bye", "ha", "yeah", "really",
                                              "now", "well", "many", "much", "tak", "nie"]

    static func removeStutters(_ text: String) -> String {
        // Repeated two- or three-word phrases: "can you can you" -> "can you".
        let phrases = regexReplace(text, "(?<![\\p{L}\\p{N}])((?:[\\p{L}']+\\s+){1,2}[\\p{L}']+)(?:[\\s,]+\\1(?![\\p{L}\\p{N}]))+",
                                   template: "$1")
        return regexReplace(phrases, "(?<![\\p{L}\\p{N}])([\\p{L}']+)(?:[\\s,]+\\1(?![\\p{L}\\p{N}]))+") { g in
            allowedRepeats.contains(g[1].lowercased()) ? g[0] : g[1]
        }
    }

    // MARK: Lists

    static let enumeratorValues: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "first": 1, "firstly": 1, "second": 2, "secondly": 2, "third": 3, "thirdly": 3, "fourth": 4, "fifth": 5,
        "jeden": 1, "dwa": 2, "trzy": 3, "cztery": 4, "pięć": 5,
        "один": 1, "два": 2, "три": 3, "четыре": 4, "пять": 5,
        "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9, "10": 10,
    ]
    static let ordinals: Set<String> = ["first", "firstly", "second", "secondly", "third", "thirdly", "fourth", "fifth"]

    struct Enumerator {
        var range: NSRange
        var value: Int
        var punctuated: Bool
    }

    static func formatList(_ text: String) -> String {
        let keys = enumeratorValues.keys.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }
        let units = "(?:am|pm|a\\.m\\.|p\\.m\\.|o'clock|%|percent|minutes?|hours?|days?|weeks?|months?|years?|"
            + "dollars?|euros?|people|times|of|or|and)"
        let pattern = "(?<![\\p{L}\\p{N}])(?:number\\s+)?(" + keys.joined(separator: "|") + ")(?![\\p{L}\\p{N}])"
            + "(?!\\s*" + units + "(?![\\p{L}]))([.):,]?)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        let candidates: [Enumerator] = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let word = ns.substring(with: m.range(at: 1)).lowercased()
            let punctuated = m.range(at: 2).length > 0
            guard let value = enumeratorValues[word] else { return nil }
            if ordinals.contains(word) && !punctuated { return nil }
            return Enumerator(range: m.range, value: value, punctuated: punctuated)
        }

        // Longest run 1, 2, 3, ... in order.
        var best: [Enumerator] = []
        for (i, start) in candidates.enumerated() where start.value == 1 {
            var run = [start]
            for c in candidates[(i + 1)...] where c.value == run.count + 1 {
                run.append(c)
            }
            if run.count > best.count { best = run }
        }
        guard best.count >= 3 || (best.count == 2 && best.allSatisfy(\.punctuated)) else { return text }

        var items: [String] = []
        var tail = ""
        for (i, e) in best.enumerated() {
            let start = e.range.location + e.range.length
            let end = i + 1 < best.count ? best[i + 1].range.location : ns.length
            guard end > start else { return text }
            var item = ns.substring(with: NSRange(location: start, length: end - start))
            if i == best.count - 1, let r = item.range(of: "[.!?](\\s+|\\n)|\\n", options: .regularExpression) {
                tail = String(item[r.upperBound...]).trimmed
                item = String(item[..<r.lowerBound])
            }
            item = regexReplace(item.trimmed, "[\\s,;:.]+(and|i|oraz)?[\\s,;:.]*$", template: "")
            item = item.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.\n"))
            guard !item.isEmpty else { return text }
            items.append(item.prefix(1).uppercased() + item.dropFirst())
        }
        var intro = ns.substring(to: best[0].range.location).trimmed
        intro = intro.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.-"))
        var out = intro.isEmpty ? "" : intro + ":\n"
        out += items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        if !tail.isEmpty { out += "\n\n" + tail }
        return out
    }

    // MARK: Email

    static let greetingPattern = "^((?i:hi|hey|hello|dear|good morning|good afternoon|good evening|cześć|dzień dobry|"
        + "witam|witaj))(?![\\p{L}])[ ,]*([\\p{Lu}][\\p{L}'-]*)?[,.!:]?\\s+"
    static let signOffPattern = "[,.]?\\s+((?i:best regards|kind regards|warm regards|best wishes|many thanks|"
        + "thank you|thanks|best|cheers|regards|sincerely|pozdrawiam|z poważaniem|dzięki))[,.!]?"
        + "(?:\\s+([\\p{Lu}][\\p{L}'-]*(?:\\s+[\\p{Lu}][\\p{L}'-]*)?))?[.!]?\\s*$"

    static func formatEmail(_ text: String) -> String {
        var body = text.trimmed
        var greeting = ""
        var signOff = ""
        if let re = try? NSRegularExpression(pattern: greetingPattern),
           let m = re.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) {
            let ns = body as NSString
            let word = ns.substring(with: m.range(at: 1))
            let name = m.range(at: 2).location == NSNotFound ? "" : " " + ns.substring(with: m.range(at: 2))
            greeting = word.prefix(1).uppercased() + word.dropFirst().lowercased() + name + ","
            body = ns.substring(from: m.range.location + m.range.length)
        }
        if let re = try? NSRegularExpression(pattern: signOffPattern),
           let m = re.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)),
           m.range.location > 0 {
            let ns = body as NSString
            let phrase = ns.substring(with: m.range(at: 1))
            signOff = phrase.prefix(1).uppercased() + phrase.dropFirst().lowercased() + ","
            if m.range(at: 2).location != NSNotFound { signOff += "\n" + ns.substring(with: m.range(at: 2)) }
            body = ns.substring(to: m.range.location)
        }
        guard !greeting.isEmpty || !signOff.isEmpty, !body.trimmed.isEmpty else { return text }
        body = body.trimmed
        body = body.prefix(1).uppercased() + body.dropFirst()
        return [greeting, body, signOff].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: Style

    static func applyStyle(_ text: String, _ ctx: FormatContext) -> String {
        let style = ctx.style
        let isEmail = ctx.category == .email
        let english = ctx.language.hasPrefix("en")
        var lines = text.components(separatedBy: "\n")
        let contentIndices = lines.indices.filter { !lines[$0].trimmed.isEmpty }

        for i in contentIndices {
            var line = lines[i]
            let isList = line.range(of: "^\\s*\\d+\\.\\s", options: .regularExpression) != nil

            if style == .veryCasual {
                line = lowercaseSentenceStarts(line, keep: ctx.keepCase)
                if english { line = regexReplace(line, "(?<![\\p{L}])I(?=['’](m|ll|ve|d)(?![\\p{L}])|(?![\\p{L}'’]))", template: "i", []) }
            } else {
                line = regexReplace(line, "(^\\s*(?:\\d+\\.\\s+)?|[.!?]\\s+)(\\p{Ll})", []) { $0[1] + $0[2].uppercased() }
                if english { line = regexReplace(line, "(?<![\\p{L}])i(?=['’](m|ll|ve|d)(?![\\p{L}])|(?![\\p{L}'’]))", template: "I", []) }
            }

            if !isList && line.wordCount > 2 {
                let lessPunctuation = (style == .casual || style == .veryCasual) && !isEmail
                if lessPunctuation {
                    line = regexReplace(line, "^(\\s*(?i:hey|hi|ok|okay|so|yeah|well|yes|no))[,]\\s", template: "$1 ", [])
                    line = regexReplace(line, "(?<!\\.)\\.\\s*$", template: "", [])
                } else if line.range(of: "[.!?:;,…\u{E001}]\\s*$", options: .regularExpression) == nil {
                    line += "."
                }
            }
            lines[i] = line
        }

        if style == .excited {
            // Greeting gets an exclamation in messages: "Hey, are you..." -> "Hey! Are you..."
            if !isEmail, let first = contentIndices.first {
                lines[first] = regexReplace(lines[first], "^(\\s*(?i:hey|hi|hello|yo))[,.!]?\\s+(\\p{L})", []) {
                    $0[1] + "! " + $0[2].uppercased()
                }
            }
            // Last real sentence ends with "!".
            if let last = contentIndices.last(where: { lines[$0].wordCount > 2 }) {
                lines[last] = regexReplace(lines[last], "(?<!\\.)\\.\\s*$", template: "!", [])
            }
        }
        return lines.joined(separator: "\n")
    }

    static func lowercaseSentenceStarts(_ line: String, keep: Set<String>) -> String {
        regexReplace(line, "(^\\s*(?:\\d+\\.\\s+)?|[.!?]\\s+)(\\p{Lu})([\\p{L}'’]*)", []) { g in
            let word = g[2] + g[3]
            let isAcronym = g[3].contains(where: { $0.isUppercase })
            if isAcronym || keep.contains(word.lowercased()) || word == "I" { return g[0] }
            return g[1] + g[2].lowercased() + g[3]
        }
    }

    // MARK: Tidy

    static func tidy(_ text: String) -> String {
        var t = text
        t = regexReplace(t, "[ \\t]+", template: " ")
        t = regexReplace(t, " *\\n *", template: "\n")
        t = regexReplace(t, "\\n{3,}", template: "\n\n")
        t = regexReplace(t, "[ \\t]+([,.!?;:…])", template: "$1")
        t = regexReplace(t, "[,;:]+(?=[.!?])", template: "")
        t = regexReplace(t, "([!?])\\.+", template: "$1")
        t = regexReplace(t, ",{2,}", template: ",")
        t = regexReplace(t, "(?m)^[ ,.;:]+", template: "")
        return t.trimmed
    }
}

// MARK: - Insertion context

/// Adjusts spacing and casing so the dictated text fits where the cursor is (Flow sends before/after text for this).
public enum ContextJoiner {
    public static func join(_ text: String, before: String?, after: String?, keepCase: Set<String> = []) -> String {
        guard !text.isEmpty else { return text }
        var out = text
        if let before, let last = before.last {
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            if let end = trimmed.last, !trimmed.isEmpty, !".!?:\n".contains(end), !out.contains("\n"),
               end.isLetter || end == "," {
                // Continuing a sentence: lower-case the first word unless it is a name/acronym/"I".
                out = LocalFormatter.regexLowerFirst(out, keep: keepCase)
            }
            if !last.isWhitespace, let first = out.first, first.isLetter || first.isNumber {
                out = " " + out
            }
        }
        if let after, let first = after.first {
            if ".,!?;:".contains(first) {
                out = regexReplace(out, "[.!?]+$", template: "")
            } else if !first.isWhitespace, !out.hasSuffix(" "), !out.hasSuffix("\n") {
                out += " "
            }
        }
        return out
    }
}

extension LocalFormatter {
    static func regexLowerFirst(_ text: String, keep: Set<String>) -> String {
        regexReplace(text, "^(\\p{Lu})([\\p{L}'’]*)", []) { g in
            let word = g[1] + g[2]
            if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") || g[2].contains(where: { $0.isUppercase })
                || keep.contains(word.lowercased()) { return g[0] }
            return g[1].lowercased() + g[2]
        }
    }
}
