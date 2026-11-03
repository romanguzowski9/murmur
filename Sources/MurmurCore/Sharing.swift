import Foundation
import NaturalLanguage

/// Turns meeting notes and tasks into an email, a WhatsApp message or a calendar invite, handed to the user's default
/// apps through URLs (mailto:, whatsapp:) and an .ics file. Nothing is sent: the user reviews and sends it.
public enum Sharing {
    // MARK: Text

    /// Markdown → plain text that reads well in an email or chat: headings in capitals, "•" bullets, task tables as
    /// one bullet per action, and no Markdown marks, timestamps or Murmur's own notes.
    public static func plainText(_ markdown: String, wording w: Wording = .en) -> String {
        var out: [String] = []
        var tableHeader: [String]?
        let lines = markdown.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            let t = raw.trimmed
            if t.hasPrefix("|") {
                if MurmurLibrary.isTableSeparator(t) { continue }
                let cells = MurmurLibrary.tableCells(t)
                if tableHeader == nil, i + 1 < lines.count, MurmurLibrary.isTableSeparator(lines[i + 1].trimmed) {
                    tableHeader = cells
                    continue
                }
                out.append("• " + tableRow(cells, header: tableHeader ?? [], w))
                continue
            }
            tableHeader = nil
            // Murmur's italic notes ("_Automatic offline summary…_", "_Imported from Wispr Flow._") aren't for readers.
            if t.hasPrefix("_"), t.hasSuffix("_"), !t.dropFirst().dropLast().contains("_") { continue }
            if t.hasPrefix("#") {
                if out.last.map({ !$0.isEmpty }) == true { out.append("") }
                out.append(clean(t.drop { $0 == "#" }.trimmed).uppercased())
            } else if let task = MurmurLibrary.task(from: t, line: 0) {
                out.append("• " + taskLine(owner: task.owner, text: task.text, due: task.due, done: task.done, w))
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
                let indent = raw.prefix { $0 == " " }.count >= 2 ? "   " : ""
                out.append(indent + "• " + clean(String(t.dropFirst(2))))
            } else if t.isEmpty {
                if out.last.map({ !$0.isEmpty }) == true { out.append("") }
            } else {
                out.append(clean(t))
            }
        }
        return out.joined(separator: "\n").trimmed
    }

    static func tableRow(_ cells: [String], header: [String], _ w: Wording) -> String {
        guard let columns = MurmurLibrary.taskColumns(header), columns.action < cells.count else {
            return cells.map(clean).joined(separator: " — ")
        }
        var action = cells[columns.action]
        var done = false
        for mark in ["[x]", "[X]", "✅"] where action.hasPrefix(mark) {
            done = true
            action = action.dropFirst(mark.count).trimmed
        }
        let owner = columns.owner.flatMap { $0 < cells.count ? cells[$0] : nil }
        let due = columns.due.flatMap { $0 < cells.count ? cells[$0] : nil }
        return taskLine(owner: owner.flatMap { MurmurLibrary.isUnspecified($0) ? nil : $0 } ?? "Not specified",
                        text: action, due: due.flatMap { MurmurLibrary.isUnspecified($0) ? nil : $0 }, done: done, w)
    }

    /// Readers of an email don't know who "Me" is: the user is named.
    static func ownerText(_ owner: String, _ w: Wording) -> String {
        if owner == "Me" { return NSFullUserName().isEmpty ? owner : NSFullUserName() }
        return owner == "Team" || owner == "Not specified" ? w.notSpecified : owner
    }

    static func taskLine(owner: String, text: String, due: String?, done: Bool, _ w: Wording) -> String {
        "\(clean(text)) — \(w.owner): \(ownerText(owner, w)) — \(w.deadline): \(due.map(clean) ?? w.notSpecified)"
            + (done ? " (\(w.done))" : "")
    }

    /// Strips inline Markdown and Murmur's "_(Me, 00:01:02)_" source marks.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\\s*_\\((?:[^)]*, )?\\d+:\\d\\d:\\d\\d\\)_", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^)]+)\\)", with: "$1 ($2)", options: .regularExpression)
        for mark in ["**", "__", "`"] { t = t.replacingOccurrences(of: mark, with: "") }
        t = t.replacingOccurrences(of: "(?<![\\p{L}\\d])_([^_]+)_(?![\\p{L}\\d])", with: "$1", options: .regularExpression)
        return t.trimmed
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(date: .long, time: .shortened)
    }

    // MARK: Wording

    /// The fixed wording of an email or message, in the language of what it shares.
    public struct Wording {
        var summarySubject, hiAll, summaryIntro, onDate, summaryClosing, regards: String
        var owner, deadline, notSpecified, done: String
        /// Task reminders: to a group (email) and to one person (chat), then labels inside the list.
        var remindAll, remindOne, reminder, tasks, deadlineLower, ownerLower, meeting: String

        public static let en = Wording(
            summarySubject: "Meeting summary", hiAll: "Hi all,", summaryIntro: "Please find below the summary of our meeting",
            onDate: "on", summaryClosing: "Please let me know if I missed or misunderstood anything.", regards: "Best regards,",
            owner: "Owner", deadline: "Deadline", notSpecified: "Not specified", done: "done",
            remindAll: "Hi all, please remember to:", remindOne: "Hey, please remember to:", reminder: "Reminder",
            tasks: "tasks", deadlineLower: "deadline", ownerLower: "owner", meeting: "Meeting")
        public static let pl = Wording(
            summarySubject: "Podsumowanie spotkania", hiAll: "Dzień dobry,", summaryIntro: "Poniżej podsumowanie naszego spotkania",
            onDate: "z dnia", summaryClosing: "Proszę o informację, jeśli coś pominąłem lub źle zrozumiałem.",
            regards: "Pozdrawiam,", owner: "Odpowiedzialny", deadline: "Termin", notSpecified: "Nie określono", done: "zrobione",
            remindAll: "Cześć, proszę pamiętajcie, aby:", remindOne: "Hej, proszę pamiętaj, aby:", reminder: "Przypomnienie",
            tasks: "zadania", deadlineLower: "termin", ownerLower: "odpowiedzialny", meeting: "Spotkanie")
        public static let ru = Wording(
            summarySubject: "Итоги встречи", hiAll: "Добрый день,", summaryIntro: "Ниже краткие итоги нашей встречи",
            onDate: "от", summaryClosing: "Пожалуйста, дайте знать, если я что-то упустил или понял неверно.",
            regards: "С уважением,", owner: "Ответственный", deadline: "Срок", notSpecified: "Не указано", done: "выполнено",
            remindAll: "Привет всем, пожалуйста, не забудьте:", remindOne: "Привет, пожалуйста, не забудь:",
            reminder: "Напоминание", tasks: "задачи", deadlineLower: "срок", ownerLower: "ответственный", meeting: "Встреча")

        static func of(language code: String?) -> Wording {
            switch code?.prefix(2) {
            case "pl": return .pl
            case "ru", "uk", "be": return .ru
            default: return .en
            }
        }

        static func of(text: String) -> Wording {
            let r = NLLanguageRecognizer()
            r.processString(text)
            // Too little text to tell: English.
            guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p >= 0.5 else { return .en }
            return of(language: lang.rawValue)
        }
    }

    static func localeDate(_ date: Date, _ w: Wording, time: Bool) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: w.hiAll == Wording.pl.hiAll ? "pl_PL" : w.hiAll == Wording.ru.hiAll ? "ru_RU" : "en_GB")
        df.dateStyle = .long
        df.timeStyle = time ? .short : .none
        return df.string(from: date)
    }

    // MARK: Meeting summary email

    public static func summaryEmail(_ note: MeetingNote, sender: String = NSFullUserName()) -> (subject: String, body: String) {
        let w = note.languages.first.map { Wording.of(language: $0) } ?? Wording.of(text: note.summary)
        let subject = "\(w.summarySubject): \(note.title) — \(localeDate(note.date, w, time: false))"
        var body = "\(w.hiAll)\n\n\(w.summaryIntro) „\(note.title)” \(w.onDate) \(localeDate(note.date, w, time: true))"
        if w.hiAll == Wording.en.hiAll { body = body.replacingOccurrences(of: "„", with: "“") }
        body += note.minutes > 0 ? " (\(note.minutes) min).\n\n" : ".\n\n"
        body += plainText(note.summary, wording: w)
        body += "\n\n\(w.summaryClosing)\n\n\(w.regards)\n"
        body += sender.split(separator: " ").first.map(String.init) ?? sender
        return (subject, body)
    }

    // MARK: Tasks

    /// The language of the transcripts the tasks came from (the most common one), else of the task text itself.
    public static func wording(for tasks: [MeetingTask]) -> Wording {
        let langs = tasks.map(\.language).filter { !$0.isEmpty }
        if let common = Dictionary(grouping: langs, by: { String($0.prefix(2)) }).max(by: { $0.value.count < $1.value.count })?.key {
            return Wording.of(language: common)
        }
        return Wording.of(text: tasks.map(\.text).joined(separator: ". "))
    }

    /// "wysłać GPS-y (termin: 3 listopada)" — the task read as the end of "please remember to…".
    static func reminderItem(_ task: MeetingTask, _ w: Wording, withOwner: Bool) -> String {
        var text = clean(task.text).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        // Lower-case the first letter ("Wysłać" → "wysłać"), but not acronyms or names ("SEG", "GPS").
        if let first = text.first, first.isUppercase, !(text.dropFirst().first?.isUppercase ?? false),
           !(task.text.split(separator: " ").first.map { $0.count > 1 && $0.allSatisfy(\.isUppercase) } ?? false) {
            text = first.lowercased() + text.dropFirst()
        }
        var extras: [String] = []
        if let due = task.due.map(clean), !due.isEmpty { extras.append("\(w.deadlineLower): \(due)") }
        if withOwner, task.owner != "Me", task.owner != "Team", task.owner != "Not specified" {
            extras.append("\(w.ownerLower): \(task.owner)")
        }
        return "• " + text + (extras.isEmpty ? "" : " (\(extras.joined(separator: ", ")))")
    }

    /// The tasks as a list, one per line, for pasting anywhere.
    public static func taskList(_ tasks: [MeetingTask]) -> String {
        let w = wording(for: tasks)
        return tasks.map { reminderItem($0, w, withOwner: true) }.joined(separator: "\n")
    }

    /// A chat message to one person (WhatsApp, Teams): "Hej, proszę pamiętaj, aby: • …".
    public static func chatMessage(_ tasks: [MeetingTask]) -> String {
        let w = wording(for: tasks)
        return w.remindOne + "\n" + tasks.map { reminderItem($0, w, withOwner: false) }.joined(separator: "\n")
    }

    /// An email to the team: "Cześć, proszę pamiętajcie, aby: • … Pozdrawiam, Anna".
    public static func tasksEmail(_ tasks: [MeetingTask], sender: String = NSFullUserName()) -> (subject: String, body: String) {
        let w = wording(for: tasks)
        let subject = tasks.count == 1
            ? "\(w.reminder): " + String(reminderItem(tasks[0], w, withOwner: false).dropFirst(2).prefix(90))
            : "\(w.reminder): \(w.tasks) (\(tasks.count))"
        var body = w.remindAll + "\n\n" + tasks.map { reminderItem($0, w, withOwner: true) }.joined(separator: "\n")
        body += "\n\n\(w.regards)\n" + (sender.split(separator: " ").first.map(String.init) ?? sender)
        return (subject, body)
    }

    // MARK: URLs

    /// mailto: with subject and body; recipients are left for the user to fill in.
    public static func mailtoURL(subject: String, body: String, to: String = "") -> URL? {
        // Mail apps expect CRLF line breaks and %20 (not "+") for spaces.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?/:;,")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let body = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        return URL(string: "mailto:\(enc(to))?subject=\(enc(subject))&body=\(enc(body))")
    }

    /// A new Teams chat with the message typed in; the user picks who it goes to.
    public static func teamsURL(text: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?/:;,")
        return URL(string: "msteams:/l/chat/0/0?users=&message=\(text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")")
    }

    /// Opens WhatsApp's "send to…" chat picker with the text filled in.
    public static func whatsAppURL(text: String, app: Bool = true) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?/:;,")
        let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: app ? "whatsapp://send?text=\(encoded)" : "https://wa.me/?text=\(encoded)")
    }

    // MARK: Calendar

    /// When to hold a meeting about a task: on its deadline when that is a recognisable date (at 10:00 unless a time
    /// is given), otherwise the next working day at 10:00.
    public static func meetingStart(for tasks: [MeetingTask], now: Date = Date()) -> Date {
        let cal = Calendar.current
        // The earliest recognisable deadline.
        let dates = tasks.compactMap { meetingDeadline($0, now: now) }
        if let first = dates.min() { return first }
        var day = cal.date(byAdding: .day, value: 1, to: now) ?? now
        while cal.isDateInWeekend(day) { day = cal.date(byAdding: .day, value: 1, to: day) ?? day }
        return cal.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
    }

    static func meetingDeadline(_ task: MeetingTask, now: Date) -> Date? {
        let cal = Calendar.current
        if let due = task.due, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: due, range: NSRange(due.startIndex..., in: due)), var date = match.date,
           date > now {
            let comps = cal.dateComponents([.hour, .minute], from: date)
            if comps.hour == 12, comps.minute == 0 { date = cal.date(bySettingHour: 10, minute: 0, second: 0, of: date) ?? date }
            return date
        }
        return nil
    }

    /// One iCalendar event for the tasks (named after the task, or "Przypomnienie: zadania (3)"), listing them in its
    /// notes; opening the file adds it in the default calendar app, which shows it for editing.
    public static func calendarInvite(for tasks: [MeetingTask], start: Date, minutes: Int = 30) -> String {
        let w = wording(for: tasks)
        let title = tasks.count == 1 ? String(clean(tasks[0].text).prefix(120)) : "\(w.reminder): \(w.tasks) (\(tasks.count))"
        var notes = taskList(tasks)
        let meetings = Array(Set(tasks.map { "\($0.meetingTitle), \(localeDate($0.meetingDate, w, time: false))" })).sorted()
        notes += "\n\n\(w.meeting): " + meetings.joined(separator: "; ")
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
        }
        // Lines longer than 75 bytes are folded, as the format requires.
        func fold(_ line: String) -> String {
            var out = "", count = 0
            for ch in line {
                let n = String(ch).utf8.count
                if count + n > 74 { out += "\r\n "; count = 1 }
                out.append(ch)
                count += n
            }
            return out
        }
        let end = start.addingTimeInterval(Double(minutes) * 60)
        let lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Murmur//Meeting tasks//EN", "METHOD:PUBLISH", "BEGIN:VEVENT",
            "UID:\(UUID().uuidString)@murmur.local", "DTSTAMP:\(utc.string(from: Date()))",
            "DTSTART:\(utc.string(from: start))", "DTEND:\(utc.string(from: end))",
            "SUMMARY:\(escape(title))",
            "DESCRIPTION:\(escape(notes))",
            "END:VEVENT", "END:VCALENDAR",
        ]
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }
}
