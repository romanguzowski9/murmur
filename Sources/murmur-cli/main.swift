import Foundation
import MurmurCore

// murmur-cli test                         run the formatter rule tests
// murmur-cli format [options] "text"      format one transcript
//   --style formal|casual|veryCasual|excited  --category personal|work|email|ai|developer|other
//   --cleanup none|light|medium|high  --before "text"  --llm (uses ANTHROPIC_API_KEY)

struct Case {
    var name: String
    var raw: String
    var expected: String
    var category: AppCategory = .other
    var style: WritingStyle = .formal
    var cleanup: CleanupLevel = .light
    var before: String? = nil
    var after: String? = nil
}

let dictionary = [
    DictionaryEntry(word: "Wispr", misspellings: ["whisper flow's", "whisper"]),
    DictionaryEntry(word: "Kubernetes", misspellings: ["cooper netties"]),
    DictionaryEntry(word: "Acme Cargo", starred: true),
]
let snippets = [Snippet(trigger: "my calendar link", expansion: "https://cal.com/roman")]

let cases: [Case] = [
    Case(name: "fillers", raw: "um so I think we should uh ship it today",
         expected: "So I think we should ship it today."),
    Case(name: "verbatim keeps fillers", raw: "um so I think we should uh ship it today",
         expected: "um so I think we should uh ship it today", cleanup: .none),
    Case(name: "stutter", raw: "can you can you send the the report",
         expected: "Can you send the report."),
    Case(name: "backtrack number", raw: "let's meet at 2 actually 3",
         expected: "Let's meet at 3."),
    Case(name: "backtrack anchor", raw: "send it to John no wait to Mary",
         expected: "Send it to Mary."),
    Case(name: "backtrack day", raw: "the deadline is Tuesday sorry I meant Wednesday",
         expected: "The deadline is Wednesday."),
    Case(name: "scratch that", raw: "I love this idea. This is terrible scratch that. Let's go",
         expected: "I love this idea. Let's go."),
    Case(name: "soft marker kept", raw: "I think I actually like it",
         expected: "I think I actually like it."),
    Case(name: "list", raw: "My goals for today are one, finish the report, two, call the bank, three, go to the gym.",
         expected: "My goals for today are:\n1. Finish the report\n2. Call the bank\n3. Go to the gym"),
    Case(name: "no false list", raw: "I have one dog and two cats",
         expected: "I have one dog and two cats."),
    Case(name: "no list for times", raw: "we can meet at 1 pm or 2 pm or 3 pm",
         expected: "We can meet at 1 pm or 2 pm or 3 pm."),
    Case(name: "spoken commands", raw: "first line new line second line question mark",
         expected: "First line\nSecond line?"),
    Case(name: "dictionary", raw: "I installed whisper on cooper netties at acme cargo",
         expected: "I installed Wispr on Kubernetes at Acme Cargo."),
    Case(name: "snippet", raw: "you can book time here my calendar link",
         expected: "You can book time here https://cal.com/roman"),
    Case(name: "formal personal", raw: "hey are you free for lunch tomorrow? let's do 12 if that works for you",
         expected: "Hey are you free for lunch tomorrow? Let's do 12 if that works for you.", category: .personal),
    Case(name: "casual", raw: "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you.",
         expected: "Hey are you free for lunch tomorrow? Let's do 12 if that works for you", category: .personal,
         style: .casual),
    Case(name: "very casual", raw: "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you.",
         expected: "hey are you free for lunch tomorrow? let's do 12 if that works for you", category: .personal,
         style: .veryCasual),
    Case(name: "excited", raw: "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you.",
         expected: "Hey! Are you free for lunch tomorrow? Let's do 12 if that works for you!", category: .personal,
         style: .excited),
    Case(name: "email", raw: "hi Alex it was great talking with you today. Looking forward to our next chat. best Mary",
         expected: "Hi Alex,\n\nIt was great talking with you today. Looking forward to our next chat.\n\nBest,\nMary",
         category: .email),
    Case(name: "continue sentence", raw: "And then we left.", expected: " and then we left.",
         before: "We had dinner,"),
    Case(name: "new sentence spacing", raw: "see you soon", expected: " See you soon.", before: "Thanks."),
    Case(name: "polish fillers", raw: "yyy no to wyślij mi eee raport jutro", expected: "No to wyślij mi raport jutro.",
         category: .personal),
    Case(name: "russian fillers", raw: "эм давай встретимся э завтра", expected: "Давай встретимся завтра."),
    Case(name: "russian backtrack", raw: "встреча в среду нет подожди в четверг", expected: "Встреча в четверг."),
]

func makeRequest(_ c: Case) -> DictationRequest {
    DictationRequest(raw: c.raw, category: c.category, style: c.style, cleanup: c.cleanup, dictionary: dictionary,
                     snippets: snippets, language: c.name.hasPrefix("polish") ? "pl" : "en",
                     beforeText: c.before, afterText: c.after)
}

/// Recognizer outputs recorded from the self-test (same audio, three languages) and the language actually spoken.
let languageCases: [(String, String, [RecognitionCandidate])] = [
    ("detect en", "en-US", [
        RecognitionCandidate(locale: "en-US", text: "Hey, can you send me the quarterly report before Friday? I want to review it.", confidence: 0.78),
        RecognitionCandidate(locale: "pl-PL", text: "Can you send me", confidence: 0),
        RecognitionCandidate(locale: "ru-RU", text: "Эй World record my Friday I wanna to you it", confidence: 0),
    ]),
    ("detect pl", "pl-PL", [
        RecognitionCandidate(locale: "en-US", text: "Dressed to team up", confidence: 0.06),
        RecognitionCandidate(locale: "pl-PL", text: "Cześć czy możesz wysłać mi raport kwartalny przed piątkiem chcę go przejrzeć", confidence: 0),
        RecognitionCandidate(locale: "ru-RU", text: "Шесть ты можешь выслать аэропорт к порталу написать кем в Ц", confidence: 0.51),
    ]),
    ("detect ru", "ru-RU", [
        RecognitionCandidate(locale: "ru-RU", text: "Привет можешь прислать мне квартальный отчёт до пятницы я хочу его посмотреть", confidence: 0.97),
        RecognitionCandidate(locale: "en-US", text: "Previous mortgage, please like the bag say yeah Madrid", confidence: 0.14),
        RecognitionCandidate(locale: "pl-PL", text: "Priwiet możesz przesłać mnie", confidence: 0),
    ]),
    ("detect en short", "en-US", [
        RecognitionCandidate(locale: "ru-RU", text: "SoundCloud", confidence: 0.43),
        RecognitionCandidate(locale: "en-US", text: "Sounds good", confidence: 0.96),
        RecognitionCandidate(locale: "pl-PL", text: "", confidence: nil),
    ]),
    ("detect pl short", "pl-PL", [
        RecognitionCandidate(locale: "en-US", text: "Dog Jinky", confidence: 0),
        RecognitionCandidate(locale: "pl-PL", text: "Dobrze dzięki", confidence: 0),
        RecognitionCandidate(locale: "ru-RU", text: "Добрый день", confidence: 0.40),
    ]),
    ("detect ru short", "ru-RU", [
        RecognitionCandidate(locale: "ru-RU", text: "Хорошо спасибо", confidence: 0.97),
        RecognitionCandidate(locale: "en-US", text: "For sure spicy", confidence: 0.35),
        RecognitionCandidate(locale: "pl-PL", text: "", confidence: nil),
    ]),
]

/// (name, field before Murmur's text, Murmur's text, field after, field as edited by the user, expected learned pairs)
let commonWords: Set<String> = ["there", "their", "the", "fix", "to", "yesterday", "pushed", "i", "hey", "team",
                                "we", "meet", "at", "tomorrow", "next", "week", "and", "call"]
let learnerCases: [(String, String, String, String, String, [LearnedCorrection])] = [
    ("learn jargon", "Notes: ", "I pushed the fix to cooper netties yesterday.", "",
     "Notes: I pushed the fix to Kubernetes yesterday.", [LearnedCorrection(from: "cooper netties", to: "Kubernetes")]),
    ("learn name", "", "Call Anna Kowalsky tomorrow.", "",
     "Call Anna Kowalska tomorrow.", [LearnedCorrection(from: "Kowalsky", to: "Kowalska")]),
    ("learn casing", "", "We use wispr at work.", "", "We use Wispr at work.",
     [LearnedCorrection(from: "wispr", to: "Wispr")]),
    ("ignore common word", "", "Put it over their.", "", "Put it over there.", []),
    ("ignore added words", "", "We meet tomorrow.", "", "We meet tomorrow and Kubernetes.", []),
    ("ignore edits outside", "Draft by Bob: ", "We meet tomorrow.", "", "Draft by Robert: We meet tomorrow.", []),
]

/// Stand-in model that records what it was asked.
final class RecordingGenerator: TextGenerator {
    var calls: [(String, String)] = []
    func complete(system: String, user: String) async throws -> String {
        calls.append((system, user))
        return "- notes \(calls.count)"
    }
}

func runTests() async -> Int32 {
    var failed = 0
    var meeting = MeetingTranscript(app: "Teams", started: Date(timeIntervalSince1970: 0))
    meeting.add(TranscriptSegment(start: 1, speaker: .others, text: "We ship the order on Friday", locale: "en-US"))
    let echoKept = meeting.add(TranscriptSegment(start: 2, speaker: .me, text: "we ship the order on Friday", locale: "en-US"))
    for i in 0..<40 {
        meeting.add(TranscriptSegment(start: Double(10 + i), speaker: i % 2 == 0 ? .me : .others,
                                      text: "Point number \(i) about pricing and the Gdansk route.", locale: "en-US"))
    }
    meeting.ended = Date(timeIntervalSince1970: 600)
    let generator = RecordingGenerator()
    let summary = try? await MeetingSummarizer.summarize(meeting, llm: generator, maxChars: 800)
    // 40 lines of ~70 chars at 800 chars per part: several part calls, then one final call with the system prompt.
    if !echoKept, generator.calls.count >= 3, generator.calls.last?.0 == MeetingSummarizer.system, summary != nil,
       meeting.markdown.contains("## Transcript"), meeting.languages == ["en"] {
        print("PASS  meeting echo filter + chunked summary (\(generator.calls.count) model calls)")
    } else {
        failed += 1
        print("FAIL  meeting summary: echoKept=\(echoKept) calls=\(generator.calls.count)")
    }
    for (name, before, inserted, after, edited, expected) in learnerCases {
        let baseline = before + inserted + after
        let got = CorrectionLearner.corrections(baseline: baseline, inserted: inserted,
                                                insertedAt: (before as NSString).length, current: edited) {
            !commonWords.contains($0.lowercased()) || $0.dropFirst().contains(where: \.isUppercase)
        }
        if got == expected {
            print("PASS  \(name)")
        } else {
            failed += 1
            print("FAIL  \(name)\n  expected: \(expected)\n  got:      \(got)")
        }
    }
    var dictionaryCopy = dictionary
    CorrectionLearner.merge([LearnedCorrection(from: "whisper flow", to: "Wispr")], into: &dictionaryCopy)
    if dictionaryCopy.first?.misspellings?.contains("whisper flow") == true, dictionaryCopy.count == dictionary.count {
        print("PASS  merge into existing entry")
    } else {
        failed += 1
        print("FAIL  merge into existing entry: \(dictionaryCopy)")
    }
    for (name, expected, candidates) in languageCases {
        let picked = LanguagePicker.pick(candidates)?.locale ?? ""
        if picked == expected {
            print("PASS  \(name)")
        } else {
            failed += 1
            print("FAIL  \(name)\n  expected: \(expected)\n  got:      \(picked)")
        }
    }
    for c in cases {
        let result = await Pipeline.dictate(makeRequest(c), llm: nil)
        if result.text == c.expected {
            print("PASS  \(c.name)")
        } else {
            failed += 1
            print("FAIL  \(c.name)\n  expected: \(c.expected.debugDescription)\n  got:      \(result.text.debugDescription)")
        }
    }
    let builtIn = InputDevice(id: 80, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn)
    let airpods = InputDevice(id: 120, uid: "AA-BB:input", name: "AirPods Pro", transport: .bluetooth)
    let teams = InputDevice(id: 95, uid: "MSTeamsAudioDevice", name: "Microsoft Teams Audio", transport: .virtual)
    let usb = InputDevice(id: 101, uid: "USB-Yeti", name: "Yeti", transport: .usb)
    let micCases: [(String, [InputDevice], String, UInt32?, String?)] = [
        ("mic: headset wins", [builtIn, teams, usb, airpods], "auto", 142, "AirPods Pro"),
        ("mic: follows macOS input", [builtIn, teams, usb], "auto", 80, "MacBook Pro Microphone"),
        ("mic: external over built-in", [builtIn, teams, usb], "auto", nil, "Yeti"),
        ("mic: never a virtual default", [teams, builtIn], "auto", 95, "MacBook Pro Microphone"),
        ("mic: manual choice", [builtIn, airpods], "BuiltInMicrophoneDevice", 120, "MacBook Pro Microphone"),
        ("mic: manual choice unplugged", [builtIn, usb], "AA-BB:input", nil, "Yeti"),
    ]
    for (name, devices, preference, systemDefault, expected) in micCases {
        let got = MicrophonePicker.pick(devices, preference: preference, systemDefault: systemDefault)?.name
        if got == expected {
            print("PASS  \(name)")
        } else {
            failed += 1
            print("FAIL  \(name)\n  expected: \(expected ?? "nil")\n  got:      \(got ?? "nil")")
        }
    }
    // The recognizer's real result stream across two long pauses (recorded with the replay self-test).
    var accumulator = TranscriptAccumulator()
    for partial in ["I", "I need", "I need a quarterly", "I need a quarterly report by Friday",
                    "I need the quarterly report by Friday", "Please", "Please also send the",
                    "Please also send the invoice to the client", "And", "And book a meeting room or Monday",
                    "And book a meeting room for Monday"] {
        accumulator.update(partial)
    }
    let expectedJoined = "I need the quarterly report by Friday. Please also send the invoice to the client. "
        + "And book a meeting room for Monday"
    var revisions = TranscriptAccumulator()
    for partial in ["We should", "We should meet at", "We should meet at the cafe", "We should meet at the café",
                    "We should meet at a café on Monday"] { revisions.update(partial) }
    var paused = TranscriptAccumulator()
    paused.update("muszę wysłać raport do piątku")
    paused.markSentenceEnd()
    paused.update("muszę wysłać raport do piątku proszę też przygotować fakturę")
    let gate = SilenceGate()
    let speech = (0..<10).map { _ in gate.shouldPass(rms: 0.05, duration: 0.02) }
    let pause = (0..<150).map { _ in gate.shouldPass(rms: 0.0005, duration: 0.02) }  // 3 s
    let resumed = gate.shouldPass(rms: 0.05, duration: 0.02)
    let checks: [(String, Bool)] = [
        ("pauses: keep every utterance", accumulator.text == expectedJoined),
        ("pauses: revisions are not restarts", revisions.text == "We should meet at a café on Monday"),
        ("pauses: long pause ends a sentence",
         paused.text == "muszę wysłać raport do piątku. Proszę też przygotować fakturę"),
        ("pauses: gate keeps speech, trims long silence",
         speech.allSatisfy { $0 } && (19...21).contains(pause.filter { $0 }.count) && resumed),
    ]
    for (name, ok) in checks {
        if ok {
            print("PASS  \(name)")
        } else {
            failed += 1
            print("FAIL  \(name): \(accumulator.text) | \(revisions.text) | kept \(pause.filter { $0 }.count)")
        }
    }
    var call = MeetingTranscript(app: "Microsoft Teams", started: Date(timeIntervalSince1970: 0))
    let lines: [(Double, Speaker, String)] = [
        (5, .me, "Thanks for joining. We need to decide on the shipping partner for the Gdansk route."),
        (20, .others, "I compared three quotes. The cheapest is 1200 euros per container but transit takes nine days."),
        (40, .me, "Nine days is too long for the client. Let's go with the second offer at 1400 euros and seven days."),
        (60, .others, "Agreed. I will send the booking confirmation by Friday and update the pricing sheet."),
        (80, .me, "Should we also insure the cargo?"),
        (95, .others, "Dobrze, to ja jeszcze sprawdzę ubezpieczenie cargo do środy."),
        (110, .me, "Can you also ask the client about the delivery window for the Gdansk route?"),
    ]
    for (t, who, text) in lines { call.add(TranscriptSegment(start: t, speaker: who, text: text, locale: "en-US")) }
    call.ended = Date(timeIntervalSince1970: 900)
    let offline = OfflineSummarizer.summarize(call)
    func section(_ title: String) -> String {
        guard let r = offline.range(of: "### " + title) else { return "" }
        let rest = offline[r.upperBound...]
        return String(rest[..<(rest.range(of: "\n### ")?.lowerBound ?? rest.endIndex)])
    }
    var empty = MeetingTranscript(app: "Zoom", started: Date())
    empty.ended = Date()
    let summaryChecks: [(String, Bool)] = [
        ("summary: all sections present", ["Overview", "Key discussion points", "Decisions", "Action items",
                                           "Open questions and blockers"].allSatisfy { offline.contains("### " + $0) }),
        ("summary: decision made", section("Decisions").contains("second offer")),
        ("summary: open questions", section("Open questions and blockers").contains("shipping partner")
            && section("Open questions and blockers").contains("insure the cargo")),
        ("summary: action table with owners and deadlines",
         section("Action items").contains("| Action | Owner | Deadline |")
            && section("Action items").contains("| I will send the booking confirmation by Friday and update the pricing sheet. _(00:01:00)_ | Others | by Friday |")
            && section("Action items").contains("sprawdzę ubezpieczenie cargo do środy. _(00:01:35)_ | Others | do środy |")
            && section("Action items").contains("delivery window for the Gdansk route? _(00:01:50)_ | Others | Not specified |")),
        ("summary: figures kept as context", offline.contains("1200 euros")),
        ("summary: empty meeting still summarized", OfflineSummarizer.summarize(empty).contains("No speech was captured")),
    ] + libraryChecks(call, summary: offline) + (await titleChecks(call)) + speakerChecks()
    for (name, ok) in summaryChecks {
        if ok {
            print("PASS  \(name)")
        } else {
            failed += 1
            print("FAIL  \(name)")
        }
    }
    if summaryChecks.contains(where: { !$0.1 }) || CommandLine.arguments.contains("--show-summary") { print(offline) }
    let total = cases.count + languageCases.count + learnerCases.count + 2 + micCases.count + checks.count
        + summaryChecks.count
    print("\n\(total - failed)/\(total) passed")
    return failed == 0 ? 0 : 1
}

/// Stand-in model that answers with fixed meeting notes.
final class FixedGenerator: TextGenerator {
    let answer: String
    init(_ answer: String) { self.answer = answer }
    func complete(system: String, user: String) async throws -> String { answer }
}

/// Meeting titles: the AI's "Title:" line is split off the summary, the offline title names the topic, and renaming
/// leaves the transcript's speaker names alone.
func titleChecks(_ call: MeetingTranscript) async -> [(String, Bool)] {
    let ai = await MeetingSummarizer.notesAlways(call, model: (FixedGenerator("""
        **Title:** Gdansk shipping partner choice

        ### Overview
        The team compared carriers for the Gdansk route and chose the second offer.
        """), 10_000))
    let offline = OfflineSummarizer.title(call) ?? ""
    let tableTasks = MurmurLibrary.parseTasks("""
        ### Action items
        | Action | Owner | Deadline |
        |:--|:--|:--|
        | Send the booking confirmation | Me | Friday 7 Nov |
        | [x] Check cargo insurance | Not specified. | Not specified. |

        ### Open questions and blockers
        """.components(separatedBy: "\n")).map(\.1)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-title-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("2026-10-30 09-15 Teams.md")
    let md = "# Meeting — Teams — 30 Oct 2026\n\nDuration: 5 min\n\n## Summary\n\nOld\n\n## Transcript\n\n**[00:00:05] Jan Wiśniewski:** Cześć\n"
    try? md.write(to: url, atomically: true, encoding: .utf8)
    MurmurLibrary.rewrite(url, title: "Insurance follow-up", summary: "### Overview\nNew")
    let note = MurmurLibrary.meeting(at: url)
    let email = note.map { Sharing.summaryEmail($0, sender: "Anna Kowalska") } ?? ("", "")
    let emailBody = email.1
    let tableText = Sharing.plainText("""
        ### Action items
        | Action | Owner | Deadline |
        |---|---|---|
        | Send the booking confirmation | Me | Friday 7 Nov |
        | [x] Check cargo insurance | Not specified. | Not specified. |
        """)
    let mailto = Sharing.mailtoURL(subject: "A & B", body: "line 1\nline 2 + more")?.absoluteString ?? ""
    let task = MeetingTask(id: "x#1", meetingID: "x", meetingTitle: "Gdansk route", meetingDate: Date(), line: 1,
                           owner: "Me", text: "Send the booking confirmation", due: nil, done: false)
    let invite = Sharing.calendarInvite(for: [task], start: Date())
    var pl = task
    pl.text = "Sprawdzić ubezpieczenie cargo i wysłać polisę do klienta"
    pl.language = "pl"
    pl.due = "do środy"
    var pl2 = pl
    pl2.text = "ACME: dopytać o dokumenty"
    pl2.owner = "Jan Wiśniewski"
    pl2.due = nil
    let plChat = Sharing.chatMessage([pl, pl2])
    let plMail = Sharing.tasksEmail([pl, pl2], sender: "Anna Kowalska")
    var ru = task
    ru.language = "ru"
    ru.text = "Проверить страховку груза"
    return [
        ("title: AI title line split off", ai.title == "Gdansk shipping partner choice" && ai.summary.hasPrefix("### Overview")),
        ("title: offline title names the topic", offline.contains("Gdansk")),
        ("tasks: AI action table parsed", tableTasks.count == 2 && tableTasks[0].owner == "Me" && tableTasks[0].due == "Friday 7 Nov"
            && tableTasks[1].owner == "Not specified" && tableTasks[1].due == nil && tableTasks[1].done),
        ("share: summary email formatted", email.0.hasPrefix("Meeting summary: Insurance follow-up — ")
            && emailBody.contains("OVERVIEW\nNew") && !emailBody.contains("###") && emailBody.hasPrefix("Hi all,")),
        ("share: Polish chat message", plChat == "Hej, proszę pamiętaj, aby:\n• sprawdzić ubezpieczenie cargo i wysłać polisę do klienta (termin: do środy)\n• ACME: dopytać o dokumenty"),
        ("share: Polish reminder email", plMail.subject == "Przypomnienie: zadania (2)"
            && plMail.body == "Cześć, proszę pamiętajcie, aby:\n\n• sprawdzić ubezpieczenie cargo i wysłać polisę do klienta (termin: do środy)\n• ACME: dopytać o dokumenty (odpowiedzialny: Jan Wiśniewski)\n\nPozdrawiam,\nAnna"),
        ("share: language follows the transcript", Sharing.chatMessage([ru]).hasPrefix("Привет, пожалуйста, не забудь:\n• проверить")
            && Sharing.chatMessage([task]).hasPrefix("Hey, please remember to:\n• send the booking confirmation")),
        ("share: teams link", Sharing.teamsURL(text: "Hej\nA & B")?.absoluteString == "msteams:/l/chat/0/0?users=&message=Hej%0AA%20%26%20B"),
        ("share: action table becomes bullets", tableText.contains("• Send the booking confirmation — Owner: \(NSFullUserName()) — Deadline: Friday 7 Nov")
            && tableText.contains("• Check cargo insurance — Owner: Not specified — Deadline: Not specified (done)")
            && !tableText.contains("|")),
        ("share: source marks and notes removed", Sharing.plainText("_Automatic offline summary._\n- Agreed. _(Me, 00:00:40)_ **Bold**")
            == "• Agreed. Bold"),
        ("share: mailto encodes lines and symbols", mailto.contains("subject=A%20%26%20B") && mailto.contains("%0D%0A")
            && !mailto.contains("+")),
        ("share: calendar invite", invite.contains("SUMMARY:Send the booking confirmation") && invite.contains("DTSTART:")
            && invite.contains("\r\n") && Sharing.meetingStart(for: [task], now: Date(timeIntervalSince1970: 1_793_440_000)) > Date(timeIntervalSince1970: 1_793_440_000)
            && Sharing.calendarInvite(for: [pl, pl2], start: Date()).contains("SUMMARY:Przypomnienie: zadania (2)")),
        ("whisper: window fitted to the audio", WhisperText.audioContext(seconds: 5.7) == 320
            && WhisperText.audioContext(seconds: 1) == 256 && WhisperText.audioContext(seconds: 40) == nil
            && WhisperText.looksTruncated("Thank you.", apple: "Place and The Booking confirmation tn angel Wi-Fi")
            && !WhisperText.looksTruncated("Please send the booking confirmation", apple: "Place and The Booking confirmation")),
        ("whisper: segments joined, repeats dropped",
         WhisperText.join([" Нужно отправить грузовики, сто", "имость 2300 евро.", " Pierwsze zdanie o transporcie.", " Pierwsze zdanie o transporcie."])
            == "Нужно отправить грузовики, стоимость 2300 евро. Pierwsze zdanie o transporcie."),
        ("whisper: invented credits dropped", WhisperText.isHallucination(" Napisy stworzone przez społeczność Amara.org")
            && WhisperText.isHallucination("Dziękuję.") && !WhisperText.isHallucination("Dziękuję, wyślę to jutro.")),
        ("whisper: language picked among the user's", WhisperText.likeliest(["pl": 0.437, "ru": 0.259, "uk": 0.2], among: ["en", "pl", "ru"]) == "pl"
            && WhisperText.likeliest(["de": 0.9, "pl": 0.05], among: ["en", "pl", "ru"]) == nil),
        ("whisper: language to locale", WhisperText.locale("pl", among: ["en-US", "pl-PL", "ru-RU"]) == "pl-PL"),
        ("title: rewrite keeps speaker names", note?.title == "Insurance follow-up" && note?.summary == "### Overview\nNew"
            && note?.transcript.first?.speaker == "Jan Wiśniewski"),
    ]
}

/// Deleted meetings go to the Trash (a recording one stays); Undo moves them back.
func meetingTrashCheck() -> Bool {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-trash-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let done = "# Meeting — Zoom — 1 Nov 2026\n\nDuration: 3 min\n\n## Summary\n\nx\n\n## Transcript\n"
    let live = "# Meeting — Teams — 1 Nov 2026\n\nDuration: 1 min" + MeetingTranscript.unfinishedMarker + "\n\n## Summary\n\n## Transcript\n"
    try? done.write(to: dir.appendingPathComponent("2026-11-01 10-00 Zoom.md"), atomically: true, encoding: .utf8)
    try? live.write(to: dir.appendingPathComponent("2026-11-01 11-00 Teams.md"), atomically: true, encoding: .utf8)
    let moved = MurmurLibrary.trashMeetings(["2026-11-01 10-00 Zoom", "2026-11-01 11-00 Teams"], directory: dir)
    let left = MurmurLibrary.meetings(directory: dir).map(\.id)
    MurmurLibrary.restoreMeetings(moved)
    let back = MurmurLibrary.meetings(directory: dir).map(\.id).sorted()
    return moved.count == 1 && left == ["2026-11-01 11-00 Teams"] && back == ["2026-11-01 10-00 Zoom", "2026-11-01 11-00 Teams"]
}

/// Deleting dictations rewrites history.jsonl without them; Undo appends them back.
func dictationDeleteCheck() -> Bool {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-hist-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let lines = (1...4).map { #"{"date":"2026-10-3\#($0)T10:00:00Z","text":"Dictation \#($0)"}"# }
    try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8)
    let before = MurmurLibrary.dictations(directory: dir)
    let target = Set(before.filter { $0.text == "Dictation 2" || $0.text == "Dictation 4" }.map(\.id))
    let removed = MurmurLibrary.deleteDictations(target, directory: dir)
    let after = MurmurLibrary.dictations(directory: dir).map(\.text).sorted()
    MurmurLibrary.restoreDictations(removed, directory: dir)
    let restored = MurmurLibrary.dictations(directory: dir).map(\.text).sorted()
    return removed.count == 2 && after == ["Dictation 1", "Dictation 3"]
        && restored == ["Dictation 1", "Dictation 2", "Dictation 3", "Dictation 4"]
}

/// The window and the MCP server read notes back from disk: tasks parse with owners and due dates and can be ticked.
func libraryChecks(_ call: MeetingTranscript, summary: String) -> [(String, Bool)] {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-lib-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    var notes = call
    notes.summary = summary
    try? notes.markdown.write(to: dir.appendingPathComponent("2026-10-30 09-15 Microsoft Teams.md"), atomically: true, encoding: .utf8)
    let meeting = MurmurLibrary.meetings(directory: dir).first
    let tasks = meeting?.tasks ?? []
    let friday = tasks.first { $0.text.contains("booking confirmation") }
    var ticked = false
    if let friday, MurmurLibrary.setTask(friday.id, done: true, directory: dir) {
        ticked = MurmurLibrary.meetings(directory: dir).first?.tasks.first { $0.id == friday.id }?.done == true
    }
    return [
        ("library: dictations deleted and restored", dictationDeleteCheck()),
        ("library: meetings trashed and restored", meetingTrashCheck()),
        ("library: meeting parsed", meeting?.app == "Microsoft Teams" && meeting?.minutes == 15 && meeting?.transcript.count == 7),
        ("library: tasks with owner and due date", friday?.owner == "Others" && friday?.due == "by Friday" && tasks.count >= 3),
        ("library: overview extracted", meeting?.overview.contains("15 min meeting") == true),
        ("library: task ticked in the file", ticked),
    ]
}

func runFormat(_ args: [String]) async -> Int32 {
    var style = WritingStyle.formal, category = AppCategory.other, cleanup = CleanupLevel.light
    var before: String?, useLLM = false, text: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        func next() -> String { i += 1; return i < args.count ? args[i] : "" }
        switch a {
        case "--style": style = WritingStyle(rawValue: next()) ?? style
        case "--category": category = AppCategory(rawValue: next()) ?? category
        case "--cleanup": cleanup = CleanupLevel(rawValue: next()) ?? cleanup
        case "--before": before = next()
        case "--llm": useLLM = true
        default: text.append(a)
        }
        i += 1
    }
    var llmConfig = ConfigStore.load().llm
    llmConfig.enabled = true
    let llm: TextGenerator? = useLLM ? ClaudeClient(config: llmConfig) : nil
    if useLLM && llm == nil {
        FileHandle.standardError.write("No API key: set ANTHROPIC_API_KEY or llm.apiKey in config.json\n".data(using: .utf8)!)
        return 2
    }
    let request = DictationRequest(raw: text.joined(separator: " "), category: category, style: style, cleanup: cleanup,
                                   dictionary: dictionary, snippets: snippets, beforeText: before)
    let result = await Pipeline.dictate(request, llm: llm)
    print(result.text)
    if let error = result.error { FileHandle.standardError.write("(fell back to local rules: \(error))\n".data(using: .utf8)!) }
    return 0
}

let args = Array(CommandLine.arguments.dropFirst())
let code: Int32
switch args.first {
case "test": code = await runTests()
case "format": code = await runFormat(Array(args.dropFirst()))
case "titles":
    // Offline titles for saved meetings next to their current titles.
    let all = MurmurLibrary.meetings()
    for note in all.prefix(Int(args.dropFirst().first ?? "") ?? 15) {
        let corpus = OfflineSummarizer.TopicCorpus(texts: all.filter { $0.id != note.id }
            .map { $0.transcript.map(\.text).joined(separator: " ") })
        let t = MeetingTranscript.parse(markdown: note.markdown, started: note.date, ended: note.date)
        print("\(note.title)\n   → \(t.flatMap { OfflineSummarizer.title($0, corpus: corpus) } ?? "-")")
    }
    code = 0
case "email-preview":
    // The email Murmur would open for a meeting's summary (meeting id or its start).
    if let id = args.dropFirst().first, let note = MurmurLibrary.meeting(id: id) {
        let mail = Sharing.summaryEmail(note)
        print("Subject: \(mail.subject)\n\n\(mail.body)")
        if !note.tasks.isEmpty {
            let tasks = Array(note.tasks.prefix(3))
            print("\n---- Tasks email (\(tasks.count) selected) ----\nSubject: \(Sharing.tasksEmail(tasks).subject)\n\n\(Sharing.tasksEmail(tasks).body)")
            print("\n---- WhatsApp / Teams ----\n\(Sharing.chatMessage(tasks))")
            print("\n---- Copied ----\n\(Sharing.taskList(tasks))")
            print("\n---- Calendar ----\n\(Sharing.calendarInvite(for: tasks, start: Sharing.meetingStart(for: tasks)))")
        }
        code = 0
    } else {
        print("usage: murmur-cli email-preview <meeting id>")
        code = 1
    }
case "bench":
    // How long the window's data work takes.
    func time(_ name: String, _ f: () -> Void) {
        let t = Date(); f(); print("\(name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(String(format: "%7.1f", Date().timeIntervalSince(t) * 1000)) ms")
    }
    var meetings: [MeetingNote] = [], dictations: [DictationRecord] = []
    time("load meetings") { meetings = MurmurLibrary.meetings() }
    time("load dictations") { dictations = MurmurLibrary.dictations() }
    let copy = MurmurLibrary.meetings()
    time("compare meetings (==)") { _ = copy == meetings }
    time("overview × all meetings") { _ = meetings.map(\.overview) }
    time("tasks flatten + open") { _ = meetings.flatMap(\.tasks).filter { !$0.done }.count }
    time("group dictations by day") {
        _ = Dictionary(grouping: dictations) { Calendar.current.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
    }
    time("signature (refresh check)") { _ = MurmurLibrary.signature() }
    print("\(meetings.count) meetings, \(dictations.count) dictations")
    code = 0
case "summarize":
    // murmur-cli summarize <note.md>   prints the offline summary of a saved meeting (and what the AI would be sent)
    guard args.count > 1, let note = MurmurLibrary.meeting(at: URL(fileURLWithPath: args[1])),
          let t = MeetingTranscript.parse(markdown: note.markdown, started: note.date,
                                          ended: note.date.addingTimeInterval(Double(note.minutes) * 60)) else {
        print("usage: murmur-cli summarize <note.md>"); code = 2; break
    }
    code = 0
    if args.contains("--prompt") { print(t.plainText); print("\n----") }
    print("\(t.segments.count) lines, \(t.cleanSegments.count) kept for the summary")
    print(OfflineSummarizer.summarize(t))
case "diarize-eval": code = DiarizeEval.run(Array(args.dropFirst()))
case "import-wispr": code = WisprImport.run(force: args.contains("--force"))
default:
    print("usage: murmur-cli test | murmur-cli import-wispr [--force] | murmur-cli format [--style s] [--category c] [--cleanup l] [--before t] [--llm] text")
    code = 1
}
exit(code)

/// Speakers: telling voices apart, naming them from the call app, the AI or the user.
func speakerChecks() -> [(String, Bool)] {
    // Two synthetic "voices": prints scattered around two different centres.
    var rng = SystemRandomNumberGenerator()
    // Voices as they look in call audio: typical values, shifted by about 1.5 deviations, with some variation.
    func print(_ centre: Float) -> [Float] {
        (0..<24).map { d in
            VoicePrint.typicalMean[d] + VoicePrint.typicalDeviation[d]
                * (centre * 0.75 * Float(d % 3 == 0 ? 1 : -1) + Float.random(in: -0.3...0.3, using: &rng))
        }
    }
    var call = MeetingTranscript(app: "Microsoft Teams", started: Date(timeIntervalSince1970: 0))
    let script: [(Double, Speaker, String, Float?)] = [
        (0, .others, "Dzień dobry, zaczynamy od statusu ładunków z Hamburga.", 2),
        (10, .others, "Нужно проверить документы по двум грузам на этой неделе.", -2),
        (20, .me, "Dobrze, Maria, sprawdzę to jeszcze dzisiaj.", nil),
        (30, .others, "Przewoźnik potwierdził, że generator zmieści się na naczepie.", 2),
        (40, .others, "Мы ждём документы от клиента, машины переставили.", -2),
        (50, .others, "Mm-hmm.", nil),
        (60, .others, "마� com", nil),
    ]
    for (t, who, text, centre) in script {
        call.add(TranscriptSegment(start: t, speaker: who, text: text, locale: "pl-PL", duration: 8,
                                   voice: centre.map(print)))
    }
    call.participants = ["Maria Nowak (Acme PL)", "Ilya Petrov", "Anna Kowalska"]
    let observed = [SpeakingObservation(time: 2, names: ["Ilya Petrov"]), SpeakingObservation(time: 33, names: ["Ilya Petrov"]),
                    SpeakingObservation(time: 12, names: ["Maria Nowak (Acme PL)"]),
                    SpeakingObservation(time: 44, names: ["Maria Nowak (Acme PL)"])]
    var named = call
    let names = named.assignSpeakers(observations: observed, me: "Anna Kowalska")
    let labels = named.segments.filter { $0.speaker == .others }.map(\.name)

    // One-to-one call: the only other participant is the voice on the call.
    var whatsapp = MeetingTranscript(app: "WhatsApp", started: Date())
    whatsapp.add(TranscriptSegment(start: 0, speaker: .others, text: "Cześć, dzwonię w sprawie faktury.", locale: "pl-PL", voice: print(1)))
    whatsapp.add(TranscriptSegment(start: 5, speaker: .others, text: "Wyślę ją jutro rano.", locale: "pl-PL", voice: print(1)))
    whatsapp.participants = ["Jan Nowak"]
    whatsapp.assignSpeakers(me: "Anna Kowalska")

    // Markdown keeps labels and participants.
    var round = named
    round.ended = Date(timeIntervalSince1970: 120)
    let parsed = MeetingTranscript.parse(markdown: round.markdown, started: round.started, ended: round.ended!)

    // What Teams exposes: tiles with mute state, a roster, an active-speaker marker; and the user's own controls.
    let teams = CallRoster.read([
        .init(role: "AXGroup", texts: ["Maria Nowak (Acme PL), muted, video is off"]),
        .init(role: "AXGroup", texts: ["Ilya Petrov, speaking"]),
        .init(role: "AXButton", texts: ["Mute (⌘⇧M)"]),
        .init(role: "AXStaticText", texts: ["You are speaking"]),
        .init(role: "AXGroup", texts: ["Peter Szabo (Guest)"], domID: "calling-roster-item-8:orgid:123"),
        .init(role: "AXButton", texts: ["Audio, turn on, currently muted"]),
    ], windowTitles: ["Meeting with Acme | Microsoft Teams"], oneToOne: false)
    let wa = CallRoster.read([], windowTitles: ["Jan Nowak", "WhatsApp"], oneToOne: true)

    let ai = SpeakerNames.extract("### Overview\nText about Speaker 1 and Speaker 10.\n**Speaker names:** Speaker 1 = Maria; Speaker 2 = ?")
    let replaced = SpeakerNames.replace("Speaker 1", with: "Maria", in: "Speaker 1 asked Speaker 10.")

    // Renaming in a saved note: transcript lines and the summary, nothing else.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-speakers-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    var note = call
    note.ended = Date(timeIntervalSince1970: 120)
    note.assignSpeakers(me: "Anna Kowalska")
    note.summary = "### Overview\nSpeaker 2 asked about documents; Speaker 1 confirmed the trailer."
    let url = dir.appendingPathComponent("2026-11-02 10-00 Test.md")
    try? note.markdown.write(to: url, atomically: true, encoding: .utf8)
    MurmurLibrary.renameSpeakers(url, ["Speaker 2": "Maria"])
    let renamed = MurmurLibrary.meeting(at: url)

    return [
        ("speakers: voices grouped and named from the call app",
         names == ["Speaker 1": "Ilya Petrov", "Speaker 2": "Maria Nowak (Acme PL)"]
            && labels.prefix(4) == ["Ilya Petrov", "Maria Nowak (Acme PL)", "Ilya Petrov", "Maria Nowak (Acme PL)"]),
        ("speakers: one-to-one call named from its window", whatsapp.segments.allSatisfy { $0.name == "Jan Nowak" }),
        ("speakers: labels and participants survive the notes file",
         parsed?.participants == call.participants && parsed?.segments.map(\.name) == named.segments.map(\.name)),
        ("speakers: Teams roster, tiles and active speaker read",
         teams.participants == ["Maria Nowak (Acme PL)", "Ilya Petrov", "Peter Szabo"] && teams.speaking == ["Ilya Petrov"]
            && wa.participants == ["Jan Nowak"]),
        ("speakers: AI names line taken off the summary",
         ai.names == ["Speaker 1": "Maria"] && !ai.summary.contains("Speaker names")),
        ("speakers: label replaced as a whole word", replaced == "Maria asked Speaker 10."),
        ("speakers: renamed in transcript and summary",
         renamed?.speakers == ["Speaker 1", "Maria"] && renamed?.summary.contains("Maria asked about documents") == true),
        ("summary input: noise left out",
         !call.plainText.contains("Mm-hmm") && !call.plainText.contains("com") && call.plainText.contains("generator")),
    ]
}
