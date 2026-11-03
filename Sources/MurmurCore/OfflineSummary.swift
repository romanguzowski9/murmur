import Foundation
import NaturalLanguage

/// A meeting summary built without any language model, so every meeting gets one: it picks out what was discussed,
/// decisions made and still open, next actions with owners and due dates, and figures/dates worth keeping, using
/// cue phrases in English, Polish and Russian.
public enum OfflineSummarizer {
    struct Sentence {
        var speaker: Speaker
        var start: Double
        var text: String
        /// "Me", "Speaker 1", "Maria"…
        var name: String = "Me"
    }

    /// "…, tak?", "…, right?": a spoken habit, not a question anyone has to answer.
    static func isTagQuestion(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "?!. "))
        return ["tak", "prawda", "nie", "dobrze", "wiesz", "rozumiesz", "jasne", "okej", "ok", "right", "okay", "yeah",
                "правильно", "да", "хорошо", "понимаешь", "ладно", "так", "нет", "ага"].contains { t.hasSuffix(" " + $0) || t == $0 }
    }

    // Cue phrases (lower-case). Matching is by substring, so stems cover inflections ("ustalil" → ustaliliśmy/ustalił).
    static let decisionCues = [
        "we decided", "we've decided", "decided to", "let's go with", "we'll go with", "we will go with", "agreed",
        "decision is", "approved", "we'll use", "we will use", "final answer", "settled on", "we chose",
        "zdecydowal", "zdecydowaliśmy", "ustalil", "ustaliliśmy", "decyzja", "zgoda", "idziemy z", "wybieramy",
        "zatwierdz", "postanowil", "postanowiliśmy", "bierzemy",
        "решили", "договорились", "решение", "согласовали", "утвердили", "выбираем", "берём", "остановились на",
    ]
    static let openCues = [
        "need to decide", "have to decide", "should we", "do we", "need to choose", "to be decided", "tbd",
        "open question", "not sure", "undecided", "pending", "we'll see", "depends on", "or should",
        "musimy zdecydować", "trzeba zdecydować", "czy powinniśmy", "do ustalenia", "do decyzji", "nie wiem czy",
        "nie jestem pewien", "nie jestem pewna", "zastanowić się", "otwarte pytanie",
        "нужно решить", "надо решить", "стоит ли", "надо определиться", "под вопросом", "не уверен", "открытый вопрос",
    ]
    static let firstPersonActionCues = [
        "i will", "i'll", "i can send", "i'm going to", "i am going to", "let me", "i'll take", "i will take",
        "zrobię", "wyślę", "przygotuję", "sprawdzę", "zadzwonię", "napiszę", "zajmę się", "ogarnę", "przyślę",
        "я сделаю", "отправлю", "подготовлю", "проверю", "позвоню", "напишу", "займусь", "пришлю",
    ]
    static let requestCues = [
        "can you", "could you", "would you", "please", "you will", "you'll", "your task",
        "możesz", "czy mógłbyś", "czy mogłabyś", "proszę", "zrób", "wyślij", "przygotuj", "sprawdź",
        "можешь", "можете", "пожалуйста", "сделай", "отправь", "подготовь", "проверь",
    ]
    static let teamActionCues = [
        "we need to", "we have to", "we should", "need to", "action item", "follow up", "next step", "to do",
        "musimy", "trzeba", "powinniśmy", "następny krok", "do zrobienia",
        "нужно", "надо", "должны", "следующий шаг",
    ]
    static let dueCues = [
        "today", "tomorrow", "tonight", "this week", "next week", "end of the week", "end of day", "eod", "asap",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "dzisiaj", "dziś", "jutro", "w tym tygodniu", "w przyszłym tygodniu", "do końca", "poniedział", "wtor", "środ",
        "czwart", "piąt", "sobot", "niedziel",
        "сегодня", "завтра", "на этой неделе", "на следующей неделе", "до конца", "понедельник", "вторник", "сред",
        "четверг", "пятниц", "суббот", "воскресен",
    ]
    static let stopwords: Set<String> = Set("""
    the a an and or but if then so to of in on at by for with from as is are was were be been being it its this that \
    these those i you he she we they me him her us them my your our their what which who whom when where why how not \
    no yes do does did done have has had will would can could should shall may might must just also very really \
    about into over than too more most some any all each other such only own same there here now well okay ok yeah \
    like get got go going gonna want need think know let let's i'm it's that's we're you're don't can't i'll we'll \
    one two three four five first second thing things lot bit maybe right sure good great thanks thank please
    i w z na do że to jest się nie tak jak ale co czy o od po za dla przez przy ten ta te tego tej tym są był była \
    było będzie mamy ma mam już jeszcze też tylko bardzo no a oraz lub albo gdy kiedy żeby bo więc może można \
    trzeba musimy jestem jesteś mi mnie nam nas ich jego jej go je tu tam teraz potem dobrze dzięki proszę
    и в во не на что с со как а то это по к но у из за от о же для до вы мы он она они я ты его её их мне нам вас \
    был была было были будет есть так уже ещё тоже только очень да нет или если когда чтобы потому может можно \
    нужно надо там тут сейчас потом хорошо спасибо пожалуйста
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init))

    public static func summarize(_ transcript: MeetingTranscript) -> String {
        let sentences = split(transcript)
        guard !sentences.isEmpty else { return "No speech was captured in this meeting, so there is nothing to summarize." }

        var used = Set<Int>()
        func pick(_ match: (Sentence) -> Bool) -> [Int] {
            sentences.indices.filter { !used.contains($0) && match(sentences[$0]) }
        }

        let decided = Array(pick { contains($0.text, decisionCues) && !$0.text.hasSuffix("?") && $0.text.wordCount >= 5 }.prefix(6))
        used.formUnion(decided)
        // "We need to decide…" is an open decision, not a task; questions only count once actions are taken.
        let undecided = pick { contains($0.text, openCues) && $0.text.wordCount >= 5 }
        used.formUnion(undecided)
        // A decision that also carries a commitment ("Agreed, I'll send…") is listed under both.
        let actions = sentences.indices.filter { i in
            let s = sentences[i]
            guard !undecided.contains(i), !(used.contains(i) && !decided.contains(i)),
                  s.text.wordCount >= 5, !s.text.hasSuffix("?") || contains(s.text, requestCues) else { return false }
            return contains(s.text, firstPersonActionCues) || contains(s.text, requestCues) || contains(s.text, teamActionCues)
        }.prefix(8).map { $0 }
        used.formUnion(actions)
        // Real questions only: long enough to carry content, not "…, tak?"; the user's own first.
        let questions = pick { $0.text.hasSuffix("?") && $0.text.wordCount >= 6 && !isTagQuestion($0.text) }
            .sorted { (sentences[$0].speaker == .me ? 0 : 1, -sentences[$0].text.count) < (sentences[$1].speaker == .me ? 0 : 1, -sentences[$1].text.count) }
            .prefix(6)
        used.formUnion(questions)
        let open = Array(Set(undecided.prefix(4) + questions)).sorted()

        let keywords = topKeywords(sentences, count: 8)
        let discussed = keySentences(sentences, keywords: keywords, excluding: [], count: 6)
        let context = pick { s in
            s.text.range(of: "\\d|€|\\$|zł|pln|eur|usd|руб|%", options: [.regularExpression, .caseInsensitive]) != nil
        }.prefix(6)

        let minutes = Int(((transcript.ended ?? Date()).timeIntervalSince(transcript.started) / 60).rounded())
        var words: [(String, Int)] = []
        for s in transcript.cleanSegments {
            if let i = words.firstIndex(where: { $0.0 == s.name }) { words[i].1 += s.text.wordCount } else { words.append((s.name, s.text.wordCount)) }
        }
        let languages = transcript.languages.prefix(3)
        var md = "_Automatic offline summary (key sentences as spoken) — add a Claude API key for an AI-written one._\n\n"
        md += "### Overview\n"
        md += "\(minutes) min meeting in \(transcript.app)"
        if !languages.isEmpty { md += " (\(languages.joined(separator: ", ")))" }
        md += " with " + words.sorted { $0.1 > $1.1 }.map { "\($0.0) (\($0.1) words)" }.joined(separator: ", ") + "."
        if !keywords.isEmpty { md += " Recurring words: \(keywords.joined(separator: ", "))." }
        md += "\n"
        // Figures and dates go with the discussion points, so the numbers that matter are kept.
        let points = Array(Set(discussed).union(context)).sorted()
        md += "\n### Key discussion points\n" + bullets(points.map { sentences[$0] })
        md += "\n### Decisions\n"
        md += decided.isEmpty ? "No confirmed decisions.\n" : bullets(decided.map { sentences[$0] })
        md += "\n### Action items\n"
        if actions.isEmpty {
            md += "No explicit action items.\n"
        } else {
            md += "| Action | Owner | Deadline |\n|---|---|---|\n"
            for i in actions {
                let s = sentences[i]
                // A request is for the person the speaker was talking with: the last one before them.
                let addressee = sentences[..<i].last { $0.name != s.name }?.name
                let who = owner(s, addressee: addressee)
                func cell(_ t: String) -> String { t.replacingOccurrences(of: "|", with: "/") }
                md += "| \(cell(s.text)) _(\(MeetingTranscript.timestamp(s.start)))_ | \(who) | "
                    + "\(cell(dueDate(s.text) ?? "Not specified")) |\n"
            }
        }
        if !open.isEmpty {
            md += "\n### Open questions and blockers\n" + bullets(open.map { sentences[$0] })
        }
        return md
    }

    /// Spoken filler and common verbs that say nothing about the topic (Polish has no part-of-speech tagger).
    static let titleStopwords: Set<String> = Set("""
    okay okej dobra dobrze słuchaj słuchajcie słuchajmy wiesz wiecie wie wiem znaczy jakby właśnie chyba może jeszcze \
    oni one ono ona on wy ty my ja pan pani panie państwo który która które którzy coś nic ktoś wszystko wszyscy \
    tego temu tym tych tamten tamta tutaj tam taki taka takie jakiś jakaś jakie jaki jest są był była było były \
    mówię mówi mówił mówiła powiem powiedział powiedziała powiedzieli myślę robi robimy zrobić zrobimy będzie będą \
    mamy macie mają musi musimy trzeba można chcę chce chcą wiadomo raczej generalnie naprawdę przecież teraz potem \
    hmm yyy eee aha no nie tak ten ta to że bo ale więc żeby jak czy już też tylko bardzo trochę dużo mało \
    хочу хочет хотим говорю говорит сказал сказала скажу думаю знаю слушай слушайте короче вообще просто ладно \
    давай давайте понял поняла типа значит например кстати вот это этот эта эти тот там тут ну да нет про \
    yeah yes right sure okay well know mean think guess actually basically really thing things stuff something \
    going gonna want wanna said say says told tell talk talking look looking need guys people time today \
    parę kilka końcu początku niech będę będziesz będziemy wdzięczny wdzięczna sprawa sprawy rzecz rzeczy razie \
    dzień dni tydzień tygodnia tygodniu miesiąc miesiąca roku rok godzin godziny minut chwili moment momencie \
    плюс минус неделя неделе недели следующий следующей день дня дней месяц месяца год года время раз дурной \
    week weeks day days month months year years hour hours minute minutes moment next last plus minus \
    prostu ogóle przykład czasami zaraz gdzie ostatnio odpowiedzi wolałbym wolałabym pana panu panem podeślę \
    wyślę wyślij spotkaniu trakcie ogólnie właściwie dokładnie naprawdę вон ребят ребята резко дурно щас сейчас \
    samo sama same dalej chodzi chodziło wiesz rozumiesz mówię właśnie przypadku sposób sposobie strony stronie \
    просто вообще самом деле смысле типа короче именно тоже такой такая такие который которая которые \
    kurwa kurde kurczę cholera jasna zajebiście chuj бля блин блять сука хрен нахрен пипец fuck fucking shit damn
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init))

    /// Polish verb forms (past tense, infinitive, 1st/2nd person plural), which rarely name a topic.
    static func looksLikePolishVerb(_ w: String) -> Bool {
        ["łem", "łam", "łeś", "łaś", "liśmy", "łyśmy", "li", "ły", "ło", "ać", "eć", "ić", "yć", "ąć", "jcie", "acie",
         "ecie", "icie", "amy", "emy", "imy", "ymy", "uję", "uje", "ują", "isz", "esz"].contains { w.hasSuffix($0) }
    }

    struct TitleToken {
        var key: String      // lemma or lower-case word, for counting
        var shown: String    // how it appears in the title
        var isName: Bool
    }

    /// The topic-bearing words of a sentence, in order; nil marks a word that breaks a phrase.
    static func titleTokens(_ text: String) -> [TitleToken?] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let language = recognizer.dominantLanguage ?? .english
        let tagged = NLTagger.availableTagSchemes(for: .word, language: language).contains(.lexicalClass)
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma, .nameType])
        tagger.string = text
        tagger.setLanguage(language, range: text.startIndex..<text.endIndex)
        var out: [TitleToken?] = []
        var first = true
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            defer { first = false }
            let word = String(text[range])
            let lower = word.lowercased()
            let capitalized = word.first?.isUppercase == true && (!first || word.dropFirst().contains(where: \.isUppercase))
            guard lower.count >= 3, !word.allSatisfy(\.isNumber), !stopwords.contains(lower),
                  !titleStopwords.contains(lower), !dueCues.contains(where: { lower.hasPrefix($0) }) else {
                out.append(nil)
                return true
            }
            if tagged {
                let name = tagger.tag(at: range.lowerBound, unit: .word, scheme: .nameType).0
                let isName = name == .personalName || name == .placeName || name == .organizationName
                guard isName || tag == .noun || (tag == .adjective && !first) else {
                    out.append(nil)
                    return true
                }
                let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue.lowercased()
                let key = lemma.flatMap { $0.isEmpty ? nil : $0 } ?? lower
                out.append(TitleToken(key: key, shown: capitalized || isName ? word : lower, isName: isName || capitalized))
            } else {
                guard capitalized || !looksLikePolishVerb(lower) else {
                    out.append(nil)
                    return true
                }
                // No lemmas for Polish: word forms that share a start count together (kontakty/kontaktów, towar/towaru).
                let key = lower.count >= 5 ? String(lower.prefix(5)) : lower
                out.append(TitleToken(key: key, shown: capitalized ? word : lower, isName: capitalized))
            }
            return true
        }
        return out
    }

    /// How many earlier meetings use each word, so words said in every call rank below the ones that name this
    /// meeting's topic.
    public struct TopicCorpus {
        public var documents = 0
        public var frequency: [String: Int] = [:]

        public init(texts: [String] = []) {
            for text in texts {
                documents += 1
                for w in Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)) {
                    frequency[w, default: 0] += 1
                }
            }
        }

        /// 1 for a word no earlier meeting used, near 0 for one every meeting uses.
        func weight(_ word: String) -> Double {
            guard documents >= 5 else { return 1 }
            let df = Double(frequency[word] ?? 0)
            return log((Double(documents) + 1) / (df + 1)) / log(Double(documents) + 1)
        }
    }

    /// A short title from what the meeting was about: its most repeated names and noun phrases, favouring words
    /// that are distinctive against earlier meetings ("Gdansk route, shipping partner & cargo"). Nil when too
    /// little was said to tell.
    public static func title(_ transcript: MeetingTranscript, corpus: TopicCorpus = TopicCorpus()) -> String? {
        let sentences = split(transcript)
        guard sentences.reduce(0, { $0 + $1.text.wordCount }) >= 12 else { return nil }
        var phrases: [String: Int] = [:]
        var words: [String: Int] = [:]
        var names = Set<String>()
        var shown: [String: [String: Int]] = [:]   // key → spellings seen
        var surface: [String: String] = [:]          // key → a lower-case spelling, for the corpus
        for s in sentences {
            let tokens = titleTokens(s.text)
            for (i, token) in tokens.enumerated() {
                guard let t = token else { continue }
                words[t.key, default: 0] += 1
                shown[t.key, default: [:]][t.shown, default: 0] += 1
                surface[t.key] = t.shown.lowercased()
                if t.isName { names.insert(t.key) }
                if i + 1 < tokens.count, let next = tokens[i + 1], next.key != t.key {
                    phrases[t.key + " " + next.key, default: 0] += 1
                }
            }
        }
        func display(_ key: String) -> String {
            key.split(separator: " ").map { k in
                shown[String(k)]?.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? String(k)
            }.joined(separator: " ")
        }
        func weight(_ key: String) -> Double { corpus.weight(surface[key] ?? key) }
        func phraseScore(_ phrase: String, _ n: Int) -> Double {
            let ws = phrase.split(separator: " ").map(String.init)
            return Double(n) * ws.map(weight).reduce(0, +) / Double(ws.count)
        }
        func wordScore(_ key: String, _ n: Int) -> Double { Double(n) * weight(key) * (names.contains(key) ? 0.7 : 1) }

        // Candidates: repeated two-word phrases and words, best first; the title takes up to three that don't overlap.
        let minimum = sentences.count > 30 ? 3 : 2
        var candidates: [(text: String, words: [String], score: Double)] = []
        for (phrase, n) in phrases where n >= 2 {
            let ws = phrase.split(separator: " ").map(String.init)
            candidates.append((phrase, ws, phraseScore(phrase, n) * 1.8))
        }
        for (w, n) in words where n >= minimum && w.count >= 4 {
            candidates.append((w, [w], wordScore(w, n)))
        }
        candidates.sort { ($0.score, $1.text) > ($1.score, $0.text) }
        let best = candidates.first?.score ?? 0
        var parts: [String] = []
        var covered = Set<String>()
        for c in candidates where parts.count < 3 && c.score >= best * 0.25 && c.score > 0.5 {
            guard !c.words.contains(where: covered.contains) else { continue }
            parts.append(display(c.text))
            covered.formUnion(c.words)
        }
        guard !parts.isEmpty else { return nil }
        let title = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " & " + parts.last! : parts[0]
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    static func bullets(_ items: [Sentence]) -> String {
        guard !items.isEmpty else { return "- None identified\n" }
        return items.map { "- \($0.text) _(\($0.name), \(MeetingTranscript.timestamp($0.start)))_\n" }.joined()
    }

    static func split(_ transcript: MeetingTranscript) -> [Sentence] {
        transcript.cleanSegments.flatMap { segment -> [Sentence] in
            var parts: [String] = []
            segment.text.enumerateSubstrings(in: segment.text.startIndex..., options: .bySentences) { s, _, _, _ in
                if let s = s?.trimmed, s.wordCount >= 3 { parts.append(s) }
            }
            if parts.isEmpty, segment.text.wordCount >= 3 { parts = [segment.text.trimmed] }
            return parts.map { Sentence(speaker: segment.speaker, start: segment.start, text: $0, name: segment.name) }
        }
    }

    static func contains(_ text: String, _ cues: [String]) -> Bool {
        let t = " " + text.lowercased() + " "
        return cues.contains { t.contains($0) }
    }

    /// "I will…" belongs to the speaker; "can you…" said to the user to "Me"; a name before "will" to that person.
    /// Otherwise "Not specified" (with several people on the call, "you" could be anyone).
    static func owner(_ s: Sentence, addressee: String? = nil) -> String {
        if let re = try? NSRegularExpression(pattern: "\\b([\\p{Lu}][\\p{Ll}]+) (?:will|is going to|should|ma|musi|должен|сделает)\\b"),
           let m = re.firstMatch(in: s.text, range: NSRange(s.text.startIndex..., in: s.text)),
           let r = Range(m.range(at: 1), in: s.text), !["I", "We", "You", "It", "This", "That"].contains(String(s.text[r])) {
            return String(s.text[r])
        }
        if contains(s.text, firstPersonActionCues) { return s.name }
        if contains(s.text, requestCues), let addressee { return addressee }
        return "Not specified"
    }

    static func dueDate(_ text: String) -> String? {
        let t = text.lowercased()
        // "by Friday", "do środy", "до пятницы", "by 15.11"; a second word only when it is a number ("by March 3").
        if let r = t.range(of: "\\b(by|before|until|do|przed|до|к)\\s+[\\p{L}\\d./-]+(\\s+\\d[\\d./-]*)?", options: .regularExpression),
           contains(String(t[r]), dueCues) || t[r].contains(where: \.isNumber) {
            return String(text[r]).trimmingCharacters(in: .punctuationCharacters)
        }
        for cue in dueCues where t.contains(cue) {
            if let r = t.range(of: "[\\p{L}]*" + NSRegularExpression.escapedPattern(for: cue) + "[\\p{L}]*", options: .regularExpression) {
                return String(text[r])
            }
        }
        return nil
    }

    static func topKeywords(_ sentences: [Sentence], count: Int) -> [String] {
        var freq: [String: Int] = [:]
        for s in sentences {
            for w in s.text.lowercased().split(whereSeparator: { !$0.isLetter }) where w.count >= 4 {
                let word = String(w)
                if !stopwords.contains(word), !titleStopwords.contains(word), !looksLikePolishVerb(word) {
                    freq[word, default: 0] += 1
                }
            }
        }
        return freq.filter { $0.value >= 2 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(count).map(\.key)
    }

    /// The most topic-heavy sentences, in the order they were said.
    static func keySentences(_ sentences: [Sentence], keywords: [String], excluding: Set<Int>, count: Int) -> [Int] {
        let keys = Set(keywords)
        let scored = sentences.indices.filter { !excluding.contains($0) }.map { i -> (Int, Int) in
            let words = sentences[i].text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            return (i, words.filter { keys.contains($0) }.count)
        }
        let top = scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(count).map(\.0)
        return (top.isEmpty ? Array(sentences.indices.prefix(count)) : top).sorted()
    }
}
