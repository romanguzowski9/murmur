import Foundation
import MurmurCore
import SQLite3

/// `murmur-cli import-wispr [--force]`: copies Wispr Flow's dictionary, snippets, dictation history and meeting notes
/// (summaries and transcripts) into Murmur. Reads a snapshot of Wispr's local database and leaves Wispr untouched.
/// Running it again only adds what is new; --force rewrites meeting notes that were imported before.
enum WisprImport {
    static let wisprDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wispr Flow")

    static func run(force: Bool) -> Int32 {
        let snapshot: URL
        do {
            snapshot = try snapshotDatabase()
        } catch {
            print("Can't read Wispr Flow's database: \(error)")
            return 1
        }
        defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }
        guard let db = Database(snapshot) else {
            print("Can't open the Wispr Flow database snapshot")
            return 1
        }
        var config = ConfigStore.load()
        let words = importDictionary(db, into: &config)
        ConfigStore.save(config)
        let dictations = importHistory(db)
        let meetings = importMeetings(db, force: force)
        print("Dictionary: \(words.words) words, \(words.snippets) snippets added")
        print("Dictations: \(dictations) added")
        print("Meetings: \(meetings.written) written, \(meetings.skipped) already imported, \(meetings.summarized) summarized offline (no Wispr summary)")
        return 0
    }

    /// Copies flow.sqlite (and its WAL, if any) so a running Wispr Flow is never locked or modified.
    static func snapshotDatabase() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-wispr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let src = wisprDir.appendingPathComponent("flow.sqlite" + suffix)
            if FileManager.default.fileExists(atPath: src.path) {
                try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent("flow.sqlite" + suffix))
            }
        }
        return dir.appendingPathComponent("flow.sqlite")
    }

    // MARK: Dictionary

    static func importDictionary(_ db: Database, into config: inout MurmurConfig) -> (words: Int, snippets: Int) {
        var words = 0, snippets = 0
        let rows = db.query("SELECT phrase, replacement, isSnippet, isStarred FROM Dictionary WHERE isDeleted = 0 OR isDeleted IS NULL")
        for row in rows {
            let phrase = (row["phrase"] ?? "")?.trimmed ?? ""
            let replacement = (row["replacement"] ?? "")?.trimmed ?? ""
            guard !phrase.isEmpty else { continue }
            if row["isSnippet"] == "1", !replacement.isEmpty {
                // Wispr snippets: say the phrase, get the expansion.
                guard !config.snippets.contains(where: { $0.trigger.lowercased() == phrase.lowercased() }) else { continue }
                config.snippets.append(Snippet(trigger: phrase, expansion: replacement))
                snippets += 1
            } else if !replacement.isEmpty {
                // A correction rule: the phrase as heard is replaced by the replacement.
                if let i = config.dictionary.firstIndex(where: { $0.word == replacement }) {
                    var heard = config.dictionary[i].misspellings ?? []
                    if !heard.contains(phrase) { heard.append(phrase); config.dictionary[i].misspellings = heard }
                } else {
                    config.dictionary.append(DictionaryEntry(word: replacement, misspellings: [phrase]))
                    words += 1
                }
            } else if !config.dictionary.contains(where: { $0.word.lowercased() == phrase.lowercased() }) {
                config.dictionary.append(DictionaryEntry(word: phrase, starred: row["isStarred"] == "1" ? true : nil))
                words += 1
            }
        }
        return (words, snippets)
    }

    // MARK: Dictations

    static let wisprDate: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS xxx"
        return df
    }()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return wisprDate.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    static func locale(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "" }
        return ["pl": "pl-PL", "en": "en-US", "ru": "ru-RU", "de": "de-DE", "uk": "uk-UA"][code] ?? code
    }

    static func importHistory(_ db: Database) -> Int {
        let url = ConfigStore.historyURL
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        // Dictations already imported, plus ones deleted in Murmur (they stay deleted).
        var seen = Set(((try? String(contentsOf: MurmurLibrary.deletedWisprIDsURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init))
        for line in existing.split(separator: "\n") {
            if let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String], let id = json["wisprId"] {
                seen.insert(id)
            }
        }
        let rows = db.query("""
            SELECT transcriptEntityId, asrText, formattedText, editedText, timestamp, app, language, detectedLanguage, status
            FROM History WHERE (isArchived = 0 OR isArchived IS NULL) ORDER BY timestamp
            """)
        let iso = ISO8601DateFormatter()
        var out = Data()
        var added = 0
        for row in rows {
            guard let id = row["transcriptEntityId"] ?? nil, !seen.contains(id), let when = date(row["timestamp"] ?? nil) else { continue }
            let raw = (row["asrText"] ?? nil)?.trimmed ?? ""
            let text = [row["editedText"] ?? nil, row["formattedText"] ?? nil, row["asrText"] ?? nil]
                .compactMap { $0?.trimmed }.first { !$0.isEmpty } ?? ""
            guard !text.isEmpty else { continue }
            let bundle = (row["app"] ?? nil) ?? ""
            let entry: [String: String] = [
                "date": iso.string(from: when), "app": appName(bundle), "bundleId": bundle, "mode": "imported from Wispr Flow",
                "lang": locale((row["detectedLanguage"] ?? nil).flatMap { $0.isEmpty ? nil : $0 } ?? (row["language"] ?? nil)),
                "raw": raw.isEmpty ? text : raw, "text": text, "wisprId": id,
            ]
            guard let line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { continue }
            out.append(line)
            out.append(0x0A)
            added += 1
        }
        guard added > 0 else { return 0 }
        try? FileManager.default.createDirectory(at: ConfigStore.directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            if !existing.isEmpty, !existing.hasSuffix("\n") { handle.write(Data([0x0A])) }
            handle.write(out)
            try? handle.close()
        } else {
            try? out.write(to: url)
        }
        return added
    }

    static func appName(_ bundleId: String) -> String {
        let known = ["net.whatsapp.WhatsApp": "WhatsApp", "com.microsoft.Outlook": "Outlook", "com.microsoft.teams2": "Microsoft Teams",
                     "com.tencent.xinWeChat": "WeChat", "com.anthropic.claudefordesktop": "Claude", "com.google.Chrome": "Chrome",
                     "com.apple.Safari": "Safari", "com.apple.MobileSMS": "Messages", "com.apple.mail": "Mail",
                     "com.microsoft.Word": "Word", "com.microsoft.Excel": "Excel", "com.apple.Notes": "Notes"]
        if let name = known[bundleId] { return name }
        return bundleId.split(separator: ".").last.map(String.init) ?? bundleId
    }

    // MARK: Meetings

    static func importMeetings(_ db: Database, force: Bool) -> (written: Int, skipped: Int, summarized: Int) {
        let deletedMeetings = Set(((try? String(contentsOf: MurmurLibrary.deletedWisprIDsURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init))
        let dir = ConfigStore.meetingsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let rows = db.query("""
            SELECT id, title, createdAt, endedAt, recordedMs, summary, notes, speakerMap, speakerAssignments, participantNames
            FROM Meetings WHERE (isDeleted = 0 OR isDeleted IS NULL) AND (isTourDemo = 0 OR isTourDemo IS NULL)
            """)
        let fileDate = DateFormatter()
        fileDate.dateFormat = "yyyy-MM-dd HH-mm"
        let headerDate = DateFormatter()
        headerDate.dateStyle = .medium
        headerDate.timeStyle = .short
        var written = 0, skipped = 0, summarized = 0

        for row in rows {
            guard let id = row["id"] ?? nil, let started = date(row["createdAt"] ?? nil) else { continue }
            let tag = "(wispr \(id.prefix(8)))"
            // Deleted in Murmur: stays deleted (unless --force).
            if !force, deletedMeetings.contains("meeting:\(id.prefix(8))") { skipped += 1; continue }
            if let old = existing.first(where: { $0.contains(tag) }) {
                if !force { skipped += 1; continue }
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(old))
            }
            let folder = wisprDir.appendingPathComponent("meetings/\(id)")
            let platform = platformName(folder)
            let names = speakerNames(map: row["speakerMap"] ?? nil, assignments: row["speakerAssignments"] ?? nil)
            let lines = transcript(folder, names: names)

            var minutes = 0
            if let ms = (row["recordedMs"] ?? nil).flatMap(Double.init), ms > 0 {
                minutes = Int((ms / 60000).rounded())
            } else if let end = (row["endedAt"] ?? nil).flatMap(Double.init) {
                minutes = max(0, Int((Date(timeIntervalSince1970: end / 1000).timeIntervalSince(started) / 60).rounded()))
            }
            let languages = languagesSpoken(folder)

            var summary = convertSummary((row["summary"] ?? nil) ?? "", names: names)
            if let notes = (row["notes"] ?? nil)?.trimmed, !notes.isEmpty, !notes.hasPrefix("{") {
                summary += "\n\n### My notes\n" + notes
            }
            if summary.trimmed.isEmpty {
                // Wispr never summarized it: make Murmur's offline summary so every meeting has one.
                var t = MeetingTranscript(app: platform, started: started)
                for l in lines {
                    t.add(TranscriptSegment(start: seconds(l.time), speaker: l.speaker == "Me" ? .me : .others, text: l.text,
                                            locale: languages.first ?? ""))
                }
                t.ended = started.addingTimeInterval(Double(minutes) * 60)
                summary = OfflineSummarizer.summarize(t)
                summarized += 1
            }

            let title = ((row["title"] ?? nil)?.trimmed).flatMap { $0.isEmpty ? nil : $0 } ?? "\(platform) meeting"
            var md = "# Meeting — \(platform) — \(headerDate.string(from: started))\n\n"
            md += "Title: \(title)\n\n"
            md += "Duration: \(minutes) min"
            if !languages.isEmpty { md += " · Languages: \(languages.joined(separator: ", "))" }
            md += "\n\n_Imported from Wispr Flow._\n\n"
            md += "## Summary\n\n\(summary.trimmed)\n\n## Transcript\n\n"
            for l in lines { md += "**[\(l.time)] \(l.speaker):** \(l.text)\n\n" }

            let safeTitle = title.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression).prefix(60)
            let url = dir.appendingPathComponent("\(fileDate.string(from: started)) \(safeTitle) \(tag).md")
            if (try? md.write(to: url, atomically: true, encoding: .utf8)) != nil {
                written += 1
                try? FileManager.default.setAttributes([.creationDate: started, .modificationDate: started], ofItemAtPath: url.path)
            }
        }
        return (written, skipped, summarized)
    }

    static func platformName(_ folder: URL) -> String {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("speakers.observations.ndjson"), encoding: .utf8),
              let first = text.split(separator: "\n").first,
              let json = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
              let meta = json["meta"] as? [String: Any], let platform = meta["platform"] as? String
        else { return "Wispr Flow" }
        return ["teams": "Microsoft Teams", "meet": "Google Meet", "zoom": "Zoom", "whatsapp": "WhatsApp",
                "slack": "Slack", "facetime": "FaceTime"][platform.lowercased()] ?? platform.capitalized
    }

    static let selfName = NSFullUserName()

    /// Wispr speaker numbers → names. The user's own voice becomes "Me", as in Murmur's own notes.
    static func speakerNames(map: String?, assignments: String?) -> [String: String] {
        func json(_ s: String?) -> [String: Any] {
            guard let s, let d = s.data(using: .utf8) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        }
        func label(_ name: String, origin: String? = nil) -> String {
            origin == "self" || name.caseInsensitiveCompare(selfName) == .orderedSame ? "Me" : name
        }
        var names: [String: String] = [:]
        let m = json(map)
        let people = m["people"] as? [String: [String: Any]] ?? [:]
        func resolve(_ slots: [String: Any]) -> String? {
            for key in ["user", "mic", "dom", "llm"] {
                if let ref = slots[key] as? String, let p = people[ref], let name = p["name"] as? String {
                    return label(name, origin: p["origin"] as? String)
                }
                if let obj = slots[key] as? [String: Any], let name = obj["name"] as? String {
                    return label(name, origin: key == "mic" ? "self" : nil)
                }
            }
            return nil
        }
        for (id, slots) in m["assignments"] as? [String: [String: Any]] ?? [:] {
            if let name = resolve(slots) { names[id] = name }
        }
        for (id, slots) in json(assignments) as? [String: [String: Any]] ?? [:] where names[id] == nil {
            if let name = resolve(slots) { names[id] = name }
        }
        return names
    }

    struct Line {
        var time: String
        var speaker: String
        var text: String
    }

    /// The refined transcript (or the live one when it was never refined), with consecutive turns merged.
    static func transcript(_ folder: URL, names: [String: String]) -> [Line] {
        let file = ["refined.ndjson", "live.ndjson"].map { folder.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var lines: [Line] = []
        for raw in text.split(separator: "\n") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let body = (json["text"] as? String)?.trimmed, !body.isEmpty else { continue }
            let speaker = json["speaker"] as? [String: Any]
            let id = (speaker?["id"]).map { "\($0)" } ?? "?"
            var name = names[id] ?? (speaker?["name"] as? String) ?? "Speaker \(id)"
            if name.caseInsensitiveCompare(selfName) == .orderedSame { name = "Me" }
            let time = clock(json["timestamp"] as? String ?? "0:00")
            if let last = lines.last, last.speaker == name {
                lines[lines.count - 1].text += " " + body
            } else {
                lines.append(Line(time: time, speaker: name, text: body))
            }
        }
        return lines
    }

    /// "1:02" / "01:02:03" → "00:01:02" / "01:02:03".
    static func clock(_ s: String) -> String {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        let total = parts.reduce(0) { $0 * 60 + $1 }
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    static func seconds(_ clock: String) -> Double {
        Double(clock.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 })
    }

    static func languagesSpoken(_ folder: URL) -> [String] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("native-language-evidence.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var counts: [String: Int] = [:]
        for side in ["mic", "system"] {
            for c in (json[side] as? [String: Any])?["counts"] as? [[String: Any]] ?? [] {
                if let lang = c["language"] as? String { counts[lang, default: 0] += c["count"] as? Int ?? 0 }
            }
        }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }

    /// Replaces Wispr's speaker tokens with names and turns its owned next steps into Murmur task checkboxes.
    static func convertSummary(_ summary: String, names: [String: String]) -> String {
        // Task owners stay "Me" (Murmur's "only mine" filter); in prose the user is named.
        func name(_ id: String) -> String { names[id] ?? "Speaker \(id)" }
        let firstName = selfName.split(separator: " ").first.map(String.init) ?? "Me"
        func prose(_ id: String) -> String { name(id) == "Me" ? firstName : name(id) }
        let token = try? NSRegularExpression(pattern: "<@speaker:(\\d+)>")
        func replaceTokens(_ s: String) -> String {
            guard let token else { return s }
            var out = s
            for m in token.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                guard let r = Range(m.range, in: out), let idr = Range(m.range(at: 1), in: s) else { continue }
                out.replaceSubrange(r, with: prose(String(s[idr])))
            }
            // Other mentions carry their display name: <@person3:n=Anna> → Anna.
            return out.replacingOccurrences(of: "<@[A-Za-z]+\\d*:[^>]*?\\bn=([^>;]+)[^>]*>", with: "$1", options: .regularExpression)
        }
        var result: [String] = []
        var inSteps = false
        for line in summary.components(separatedBy: "\n") {
            let t = line.trimmed
            if t.hasPrefix("#") {
                let h = t.lowercased()
                inSteps = ["kroki", "next step", "шаги", "action", "todo", "to-do", "zadania"].contains { h.contains($0) }
                result.append(replaceTokens(t))
                continue
            }
            // "- (<@speaker:2>) Send the email" → "- [ ] **Name** — Send the email"
            if let m = t.range(of: "^[-*] \\(<@speaker:(\\d+)>(?:, <@speaker:\\d+>)*\\) ", options: .regularExpression) {
                let owners = String(t[m])
                let ids = (token?.matches(in: owners, range: NSRange(owners.startIndex..., in: owners)) ?? [])
                    .compactMap { Range($0.range(at: 1), in: owners).map { name(String(owners[$0])) } }
                result.append("- [ ] **\(ids.joined(separator: ", "))** — \(replaceTokens(String(t[m.upperBound...])))")
            } else if inSteps, t.hasPrefix("- "), !t.hasPrefix("- [") {
                result.append("- [ ] **Team** — \(replaceTokens(String(t.dropFirst(2))))")
            } else {
                result.append(replaceTokens(line))
            }
        }
        return result.joined(separator: "\n")
    }
}

/// Minimal SQLite access for querying the snapshot.
final class Database {
    private var handle: OpaquePointer?

    init?(_ url: URL) {
        // Read-write only so SQLite can replay the copied WAL; this is a private snapshot, never Wispr's own file.
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return nil }
    }

    deinit { sqlite3_close(handle) }

    func query(_ sql: String) -> [[String: String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("SQL error: \(String(cString: sqlite3_errmsg(handle)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String: String?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: String?] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                row[name] = sqlite3_column_text(stmt, i).map { String(cString: $0) }
            }
            rows.append(row)
        }
        return rows
    }
}
