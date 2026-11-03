import Foundation

/// One dictation from history.jsonl.
public struct DictationRecord: Identifiable, Hashable {
    /// Line number in history.jsonl (changes when earlier lines are deleted; reload after deleting).
    public var id: Int
    public var date: Date
    public var app: String
    public var language: String
    public var raw: String
    public var text: String
    /// Set for dictations imported from Wispr Flow (so a deleted one isn't imported again).
    public var wisprID: String?
}

/// A next action from a meeting summary ("- [ ] **Owner** — task — due: date").
public struct MeetingTask: Identifiable, Hashable {
    /// "<meeting id>#<line number>", stable until the summary is rewritten.
    public var id: String
    public var meetingID: String
    public var meetingTitle: String
    public var meetingDate: Date
    public var line: Int
    public var owner: String
    public var text: String
    public var due: String?
    public var done: Bool
    /// Main language of the meeting's transcript ("pl", "ru", "en"; empty when unknown), for messages about the task.
    public var language: String

    public init(id: String, meetingID: String, meetingTitle: String, meetingDate: Date, line: Int, owner: String,
                text: String, due: String?, done: Bool, language: String = "") {
        self.language = language
        self.id = id
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.meetingDate = meetingDate
        self.line = line
        self.owner = owner
        self.text = text
        self.due = due
        self.done = done
    }
}

public struct TranscriptLine: Hashable {
    public var time: String
    public var speaker: String
    public var text: String
}

/// A meeting's Markdown notes, parsed for display.
public struct MeetingNote: Identifiable, Hashable {
    /// File name without ".md".
    public var id: String
    public var url: URL
    public var app: String
    public var date: Date
    public var minutes: Int
    public var languages: [String]
    public var inProgress: Bool
    public var summary: String
    public var transcript: [TranscriptLine]
    public var tasks: [MeetingTask]
    public var markdown: String
    /// From an optional "Title: …" line (imported meetings keep their own titles).
    public var customTitle: String?

    /// People seen in the call app ("Participants: …" line).
    public var participants: [String] = []

    public var title: String { customTitle ?? (app == "Manual" ? "Meeting notes" : "\(app) call") }
    /// The other people in the transcript, in order of first appearance ("Speaker 1", "Maria"…), not "Me".
    public var speakers: [String] {
        var seen: [String] = []
        for l in transcript where l.speaker != "Me" && !seen.contains(l.speaker) { seen.append(l.speaker) }
        return seen
    }
    public var wordCount: Int { transcript.reduce(0) { $0 + $1.text.wordCount } }

    /// The summary's overview paragraph, for previews (worked out once, when the note is read).
    public var overview: String = ""

    static func overview(of summary: String) -> String {
        let lines = summary.components(separatedBy: "\n").map(\.trimmed)
        var out: [String] = []
        var inOverview = !summary.contains("### Overview")
        for line in lines {
            if line.hasPrefix("###") {
                if inOverview, !out.isEmpty { break }
                inOverview = line.lowercased().contains("overview")
                continue
            }
            if inOverview, !line.isEmpty, !line.hasPrefix("_") { out.append(line) }
        }
        return out.joined(separator: " ")
    }
}

/// Reads Murmur's saved dictations and meeting notes (and ticks off meeting tasks), for the window and for Claude.
public enum MurmurLibrary {
    static let fileDate: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH-mm"
        return df
    }()

    public static func dictations(directory: URL = ConfigStore.directory) -> [DictationRecord] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("history.jsonl"), encoding: .utf8)
        else { return [] }
        let iso = ISO8601DateFormatter()
        var records: [DictationRecord] = []
        for (i, line) in text.split(separator: "\n").enumerated() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
                  let body = json["text"], !body.trimmed.isEmpty else { continue }
            records.append(DictationRecord(id: i, date: json["date"].flatMap(iso.date(from:)) ?? .distantPast,
                                           app: json["app"] ?? "", language: json["lang"] ?? "", raw: json["raw"] ?? body,
                                           text: body, wisprID: json["wisprId"]))
        }
        return records.sorted { $0.date > $1.date }
    }

    /// Wispr dictation IDs the user deleted; the Wispr import skips them.
    public static var deletedWisprIDsURL: URL { ConfigStore.directory.appendingPathComponent("deleted-wispr-ids.txt") }

    /// Deletes dictations (by `id`, their line in history.jsonl) and returns the removed lines, for undo.
    @discardableResult
    public static func deleteDictations(_ ids: Set<Int>, directory: URL = ConfigStore.directory) -> [String] {
        let url = directory.appendingPathComponent("history.jsonl")
        guard !ids.isEmpty, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var kept: [Substring] = [], removed: [String] = []
        for (i, line) in text.split(separator: "\n").enumerated() {
            if ids.contains(i) { removed.append(String(line)) } else { kept.append(line) }
        }
        guard !removed.isEmpty else { return [] }
        let body = kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")
        guard (try? body.write(to: url, atomically: true, encoding: .utf8)) != nil else { return [] }
        let wispr = removed.compactMap { line -> String? in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])?["wisprId"]
        }
        if !wispr.isEmpty {
            let list = deletedWisprIDsURL
            let old = (try? String(contentsOf: list, encoding: .utf8)) ?? ""
            try? (old + wispr.map { $0 + "\n" }.joined()).write(to: list, atomically: true, encoding: .utf8)
        }
        return removed
    }

    /// Moves meeting notes to the Trash (recoverable from Finder too) and returns where each went, for undo.
    /// Notes still being recorded are left alone. Deleted Wispr imports are remembered so a re-import skips them.
    @discardableResult
    public static func trashMeetings(_ ids: Set<String>, directory: URL = ConfigStore.meetingsDirectory) -> [(from: URL, to: URL)] {
        var moved: [(URL, URL)] = []
        var wispr: [String] = []
        for id in ids {
            let url = directory.appendingPathComponent(id + ".md")
            if let md = try? String(contentsOf: url, encoding: .utf8), md.contains(MeetingTranscript.unfinishedMarker) { continue }
            var trashed: NSURL?
            guard (try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)) != nil, let to = trashed as URL? else { continue }
            moved.append((url, to))
            if let r = id.range(of: "\\(wispr ([0-9a-f]{8})\\)", options: .regularExpression) {
                wispr.append("meeting:" + id[r].dropFirst(7).dropLast())
            }
        }
        if !wispr.isEmpty {
            let old = (try? String(contentsOf: deletedWisprIDsURL, encoding: .utf8)) ?? ""
            try? (old + wispr.map { $0 + "\n" }.joined()).write(to: deletedWisprIDsURL, atomically: true, encoding: .utf8)
        }
        return moved
    }

    /// Brings trashed meeting notes back (Undo).
    public static func restoreMeetings(_ moved: [(from: URL, to: URL)]) {
        var restored = Set<String>()
        for (from, to) in moved where (try? FileManager.default.moveItem(at: to, to: from)) != nil {
            let id = from.deletingPathExtension().lastPathComponent
            if let r = id.range(of: "\\(wispr ([0-9a-f]{8})\\)", options: .regularExpression) {
                restored.insert("meeting:" + id[r].dropFirst(7).dropLast())
            }
        }
        if !restored.isEmpty, let old = try? String(contentsOf: deletedWisprIDsURL, encoding: .utf8) {
            let rest = old.split(separator: "\n").filter { !restored.contains(String($0)) }
            try? rest.map { $0 + "\n" }.joined().write(to: deletedWisprIDsURL, atomically: true, encoding: .utf8)
        }
    }

    /// Puts deleted dictations back (Undo).
    public static func restoreDictations(_ lines: [String], directory: URL = ConfigStore.directory) {
        guard !lines.isEmpty else { return }
        let url = directory.appendingPathComponent("history.jsonl")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += lines.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        let restored = Set(lines.compactMap { line -> String? in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])?["wisprId"]
        })
        if !restored.isEmpty, let old = try? String(contentsOf: deletedWisprIDsURL, encoding: .utf8) {
            let rest = old.split(separator: "\n").filter { !restored.contains(String($0)) }
            try? rest.map { $0 + "\n" }.joined().write(to: deletedWisprIDsURL, atomically: true, encoding: .utf8)
        }
    }

    /// Cheap fingerprint of Murmur's saved data (file names, sizes, modification times): when it hasn't changed,
    /// there's nothing to reload.
    public static func signature() -> String {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        func describe(_ url: URL) -> String {
            let v = try? url.resourceValues(forKeys: keys)
            return "\(url.lastPathComponent):\(v?.fileSize ?? -1):\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        let notes = (try? fm.contentsOfDirectory(at: ConfigStore.meetingsDirectory, includingPropertiesForKeys: Array(keys))) ?? []
        return ([describe(ConfigStore.historyURL)] + notes.map(describe).sorted()).joined(separator: "|")
    }

    public static func meetings(directory: URL = ConfigStore.meetingsDirectory) -> [MeetingNote] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.compactMap(meeting(at:)).sorted { $0.date > $1.date }
    }

    public static func meeting(id: String, directory: URL = ConfigStore.meetingsDirectory) -> MeetingNote? {
        meetings(directory: directory).first { $0.id == id || $0.id.lowercased().hasPrefix(id.lowercased()) }
    }

    public static func meeting(at url: URL) -> MeetingNote? {
        guard let md = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let id = url.deletingPathExtension().lastPathComponent
        let lines = md.components(separatedBy: "\n")
        guard let first = lines.first, first.hasPrefix("# Meeting — ") else { return nil }
        let app = first.dropFirst("# Meeting — ".count).components(separatedBy: " — ").first ?? "Meeting"
        let date = fileDate.date(from: String(id.prefix(16)))
            ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast

        var minutes = 0
        var languages: [String] = []
        if let info = lines.first(where: { $0.hasPrefix("Duration: ") }) {
            if let r = info.range(of: "\\d+", options: .regularExpression) { minutes = Int(info[r]) ?? 0 }
            if let r = info.range(of: "Languages: [a-z, ]+", options: .regularExpression) {
                languages = info[r].dropFirst("Languages: ".count).split(separator: ",").map { $0.trimmed }
                    .filter { !$0.isEmpty }
            }
        }

        var section = ""
        var summaryLines: [String] = []
        var summaryLineNumbers: [Int] = []
        var transcript: [TranscriptLine] = []
        let speakerLine = try? NSRegularExpression(pattern: "^\\*\\*\\[([\\d:]+)\\] ([^:*]+):\\*\\* (.*)$")
        for (n, line) in lines.enumerated() {
            if line.hasPrefix("## ") {
                section = String(line.dropFirst(3))
                continue
            }
            switch section {
            case "Summary":
                summaryLines.append(line)
                summaryLineNumbers.append(n)
            case "Transcript":
                let ns = line as NSString
                if let m = speakerLine?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                    transcript.append(TranscriptLine(time: ns.substring(with: m.range(at: 1)),
                                                     speaker: ns.substring(with: m.range(at: 2)),
                                                     text: ns.substring(with: m.range(at: 3))))
                }
            default: break
            }
        }
        var note = MeetingNote(id: id, url: url, app: app, date: date, minutes: minutes, languages: languages,
                               inProgress: md.contains(MeetingTranscript.unfinishedMarker),
                               summary: summaryLines.joined(separator: "\n").trimmed, transcript: transcript, tasks: [],
                               markdown: md,
                               customTitle: lines.first { $0.hasPrefix("Title: ") }.map { String($0.dropFirst(7)).trimmed })
        note.overview = MeetingNote.overview(of: note.summary)
        note.participants = lines.first { $0.hasPrefix("Participants: ") }
            .map { $0.dropFirst("Participants: ".count).components(separatedBy: ", ").map(\.trimmed).filter { !$0.isEmpty } } ?? []
        note.tasks = parseTasks(summaryLines).map { i, t in
            let n = summaryLineNumbers[i]
            return MeetingTask(id: "\(id)#\(n)", meetingID: id, meetingTitle: note.title, meetingDate: date, line: n,
                               owner: t.owner, text: t.text, due: t.due, done: t.done,
                               language: languages.first ?? "")
        }
        return note
    }

    public typealias ParsedTask = (owner: String, text: String, due: String?, done: Bool)

    /// The tasks in summary lines, in order, with the index of the line each came from. Two forms are read:
    /// checkbox bullets ("- [ ] **Owner** — task — due: date") and rows of an action-items table
    /// ("| Action | Owner | Deadline |"); a table row is done when its action starts with "[x]".
    public static func parseTasks(_ lines: [String]) -> [(Int, ParsedTask)] {
        var out: [(Int, ParsedTask)] = []
        var table: (action: Int, owner: Int?, due: Int?)?
        var inTable = false
        for (i, line) in lines.enumerated() {
            let t = line.trimmed
            guard t.hasPrefix("|") else {
                inTable = false
                table = nil
                if let task = task(from: line, line: i) { out.append((i, task)) }
                continue
            }
            if isTableSeparator(t) { continue }
            let cells = tableCells(t)
            if !inTable {
                // A header row (followed by a separator) starts a table; it holds tasks when a column names actions.
                inTable = true
                guard i + 1 < lines.count, isTableSeparator(lines[i + 1].trimmed) else { continue }
                table = taskColumns(cells)
                continue
            }
            guard let table, table.action < cells.count else { continue }
            var action = cells[table.action]
            var done = false
            for mark in ["[x]", "[X]", "✅", "☑"] where action.hasPrefix(mark) {
                done = true
                action = action.dropFirst(mark.count).trimmed
            }
            if action.hasPrefix("[ ]") { action = action.dropFirst(3).trimmed }
            if action.hasPrefix("~~"), action.hasSuffix("~~"), action.count > 4 {
                done = true
                action = String(action.dropFirst(2).dropLast(2))
            }
            guard !action.isEmpty, !isUnspecified(action) else { continue }
            let owner = table.owner.flatMap { $0 < cells.count ? cells[$0] : nil }.flatMap { isUnspecified($0) ? nil : $0 }
            let due = table.due.flatMap { $0 < cells.count ? cells[$0] : nil }.flatMap { isUnspecified($0) ? nil : $0 }
            out.append((i, (owner ?? "Not specified", action, due, done)))
        }
        return out
    }

    /// The action, owner and deadline columns of a table header, or nil when it isn't an action-items table.
    static func taskColumns(_ header: [String]) -> (action: Int, owner: Int?, due: Int?)? {
        let lower = header.map { $0.lowercased() }
        func column(_ words: [String]) -> Int? { lower.firstIndex { c in words.contains { c.contains($0) } } }
        guard let action = column(["action", "task", "zadani", "działani", "czynnoś", "действи", "задач", "to-do", "todo"])
        else { return nil }
        return (action, column(["owner", "who", "właściciel", "osoba", "odpowiedzialn", "kto", "ответствен", "владел", "кто", "исполнител"]),
                column(["deadline", "due", "termin", "kiedy", "срок", "дедлайн", "когда", "date", "data"]))
    }

    static func isTableSeparator(_ t: String) -> Bool {
        t.hasPrefix("|") && t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
    }

    static func tableCells(_ t: String) -> [String] {
        var row = t.trimmed
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmed }
    }

    static func isUnspecified(_ s: String) -> Bool {
        let t = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .*_"))
        return ["", "-", "—", "–", "n/a", "none", "not specified", "nie określono", "nieokreślony", "brak", "не указано",
                "не указан", "нет"].contains(t)
    }

    /// Parses "- [ ] **Owner** — task — due: date _(00:01:02)_".
    static func task(from line: String, line n: Int) -> (owner: String, text: String, due: String?, done: Bool)? {
        let t = line.trimmed
        guard t.hasPrefix("- [ ]") || t.lowercased().hasPrefix("- [x]") else { return nil }
        let done = !t.hasPrefix("- [ ]")
        var body = t.dropFirst(5).trimmed
        body = body.replacingOccurrences(of: "\\s*_\\(\\d+:\\d\\d:\\d\\d\\)_$", with: "", options: .regularExpression)
        var owner = ""
        if body.hasPrefix("**"), let end = body.range(of: "**", range: body.index(body.startIndex, offsetBy: 2)..<body.endIndex) {
            owner = String(body[body.index(body.startIndex, offsetBy: 2)..<end.lowerBound])
            body = String(body[end.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " —-:"))
        }
        var due: String?
        if let r = body.range(of: " — due: ", options: .backwards) {
            due = String(body[r.upperBound...]).trimmed
            body = String(body[..<r.lowerBound])
        }
        guard !body.isEmpty else { return nil }
        return (owner.isEmpty ? "Team" : owner, body, due, done)
    }

    public static func tasks(directory: URL = ConfigStore.meetingsDirectory) -> [MeetingTask] {
        meetings(directory: directory).flatMap(\.tasks)
    }

    /// Ticks or unticks a task's checkbox in its meeting notes.
    @discardableResult
    public static func setTask(_ id: String, done: Bool, directory: URL = ConfigStore.meetingsDirectory) -> Bool {
        guard let hash = id.lastIndex(of: "#"), let n = Int(id[id.index(after: hash)...]) else { return false }
        let url = directory.appendingPathComponent(String(id[..<hash]) + ".md")
        guard let md = try? String(contentsOf: url, encoding: .utf8) else { return false }
        var lines = md.components(separatedBy: "\n")
        guard n < lines.count else { return false }
        let line = lines[n]
        if line.trimmed.hasPrefix("|") {
            // Table row: mark the action cell "[x] …".
            var cells = tableCells(line)
            var top = n
            while top > 0, lines[top - 1].trimmed.hasPrefix("|") { top -= 1 }
            guard top < n, let columns = taskColumns(tableCells(lines[top])), columns.action < cells.count else { return false }
            let i = columns.action
            var action = cells[i]
            for mark in ["[x]", "[X]", "[ ]", "✅"] where action.hasPrefix(mark) { action = action.dropFirst(mark.count).trimmed }
            cells[i] = done ? "[x] " + action : action
            lines[n] = "| " + cells.joined(separator: " | ") + " |"
        } else {
            guard task(from: line, line: n) != nil,
                  let r = line.range(of: "- [ ]") ?? line.range(of: "- [x]") ?? line.range(of: "- [X]") else { return false }
            lines[n] = line.replacingCharacters(in: r, with: done ? "- [x]" : "- [ ]")
        }
        return (try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    /// Word frequencies across saved meetings (except `excluding`), for picking distinctive words in offline titles.
    public static func topicCorpus(excluding id: String? = nil) -> OfflineSummarizer.TopicCorpus {
        OfflineSummarizer.TopicCorpus(texts: meetings().filter { $0.id != id }
            .map { $0.transcript.map(\.text).joined(separator: " ") })
    }

    /// Updates a note's "Title:" line and, when given, its summary section, leaving the transcript (and its speaker
    /// names) untouched.
    @discardableResult
    public static func rewrite(_ url: URL, title: String?, summary: String? = nil) -> Bool {
        guard var md = try? String(contentsOf: url, encoding: .utf8) else { return false }
        var lines = md.components(separatedBy: "\n")
        if let title {
            let clean = title.replacingOccurrences(of: "\n", with: " ").trimmed
            if let i = lines.firstIndex(where: { $0.hasPrefix("Title: ") }) {
                lines[i] = "Title: \(clean)"
            } else if let i = lines.firstIndex(where: { $0.hasPrefix("# Meeting — ") }) {
                lines.insert(contentsOf: ["", "Title: \(clean)"], at: i + 1)
            }
        }
        md = lines.joined(separator: "\n")
        if let summary, let start = md.range(of: "## Summary\n") {
            let end = md.range(of: "\n## Transcript", range: start.upperBound..<md.endIndex)?.lowerBound ?? md.endIndex
            md.replaceSubrange(start.upperBound..<end, with: "\n\(summary.trimmed)\n")
        }
        return (try? md.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    /// Names speakers in a note ("Speaker 1" → "Maria"): their transcript lines and every mention in the summary.
    /// Giving two speakers the same name merges them.
    @discardableResult
    public static func renameSpeakers(_ url: URL, _ names: [String: String]) -> Bool {
        let names = names.filter { !$0.value.trimmed.isEmpty && $0.key != $0.value.trimmed && $0.key != "Me" }
        guard !names.isEmpty, var md = try? String(contentsOf: url, encoding: .utf8) else { return names.isEmpty }
        let clean = names.mapValues { $0.replacingOccurrences(of: "[:*\n]", with: " ", options: .regularExpression).trimmed }
        var lines = md.components(separatedBy: "\n")
        var section = ""
        for i in lines.indices {
            if lines[i].hasPrefix("## ") { section = String(lines[i].dropFirst(3)); continue }
            for (label, name) in clean {
                if section == "Transcript", lines[i].hasPrefix("**["), lines[i].contains("] \(label):**") {
                    lines[i] = lines[i].replacingOccurrences(of: "] \(label):**", with: "] \(name):**")
                } else if section == "Summary" {
                    lines[i] = SpeakerNames.replace(label, with: name, in: lines[i])
                }
            }
        }
        md = lines.joined(separator: "\n")
        return (try? md.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    /// A file name for a meeting's notes: "<date> <title>.md", unique in the folder.
    public static func fileName(date: Date, title: String, directory: URL = ConfigStore.meetingsDirectory) -> URL {
        let safe = title.replacingOccurrences(of: "[/:\\\\\n]", with: "-", options: .regularExpression).prefix(70).trimmed
        let base = "\(fileDate.string(from: date)) \(safe)"
        var url = directory.appendingPathComponent(base + ".md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) (\(n)).md")
            n += 1
        }
        return url
    }

    public struct SearchHit: Hashable {
        public var source: String   // "meeting" or "dictation"
        public var id: String
        public var title: String
        public var date: Date
        public var snippet: String
    }

    /// Case- and accent-insensitive search over transcripts, summaries and dictations; every word must match a line.
    public static func search(_ query: String, limit: Int = 30) -> [SearchHit] {
        let terms = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        func matches(_ s: String) -> Bool {
            terms.allSatisfy { s.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        var hits: [SearchHit] = []
        for m in meetings() {
            let lines = m.summary.components(separatedBy: "\n") + m.transcript.map { "[\($0.time)] \($0.speaker): \($0.text)" }
            for line in lines where matches(line) {
                hits.append(SearchHit(source: "meeting", id: m.id, title: m.title, date: m.date, snippet: line.trimmed))
            }
        }
        for d in dictations() where matches(d.text) {
            hits.append(SearchHit(source: "dictation", id: String(d.id), title: "Dictation in \(d.app)", date: d.date,
                                  snippet: d.text))
        }
        return Array(hits.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// Everything Murmur knows, newest first, for answering questions about it: open tasks, every summary, then as
    /// many transcripts and dictations as fit `maxChars`.
    public static func context(focus: String? = nil, maxChars: Int = 250_000) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        var all = meetings()
        if let focus, let i = all.firstIndex(where: { $0.id == focus }) { all.insert(all.remove(at: i), at: 0) }
        let open = all.flatMap(\.tasks).filter { !$0.done }
        var out = "<open_tasks>\n"
        for t in open { out += "- \(t.owner) — \(t.text)\(t.due.map { " — due: \($0)" } ?? "") (from \(t.meetingTitle), \(df.string(from: t.meetingDate)))\n" }
        out += "</open_tasks>\n\n"
        for m in all {
            out += "<meeting id=\"\(m.id)\" title=\"\(m.title)\" date=\"\(df.string(from: m.date))\" minutes=\"\(m.minutes)\">\n"
            out += "<summary>\n\(m.summary)\n</summary>\n</meeting>\n\n"
        }
        for m in all where !m.transcript.isEmpty {
            let body = m.transcript.map { "[\($0.time)] \($0.speaker): \($0.text)" }.joined(separator: "\n")
            let block = "<transcript meeting=\"\(m.id)\">\n\(body)\n</transcript>\n\n"
            if out.count + block.count > maxChars { break }
            out += block
        }
        var recent = "<dictations>\n"
        for d in dictations() {
            let line = "[\(df.string(from: d.date)) · \(d.app)] \(d.text)\n"
            if out.count + recent.count + line.count > maxChars { break }
            recent += line
        }
        return out + recent + "</dictations>"
    }
}
