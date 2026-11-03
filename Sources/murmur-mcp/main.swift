import Foundation
import MurmurCore

// A Model Context Protocol server (JSON-RPC over stdio) that lets Claude read Murmur's meeting notes, transcripts,
// tasks and dictations, and tick tasks off. Register it with: murmur-mcp (no arguments).

let df: DateFormatter = {
    let df = DateFormatter()
    df.dateStyle = .medium
    df.timeStyle = .short
    return df
}()

func describe(_ m: MeetingNote) -> String {
    let open = m.tasks.filter { !$0.done }.count
    return "- id: \(m.id) — \(m.title), \(df.string(from: m.date)), \(m.minutes) min"
        + (m.languages.isEmpty ? "" : ", languages: \(m.languages.joined(separator: ", "))")
        + (m.inProgress ? " (recording now)" : "") + ", open tasks: \(open)\n  \(m.overview.prefix(300))"
}

func describe(_ t: MeetingTask) -> String {
    "- [\(t.done ? "x" : " ")] \(t.owner) — \(t.text)\(t.due.map { " — due: \($0)" } ?? "") "
        + "(task_id: \(t.id); meeting: \(t.meetingTitle), \(df.string(from: t.meetingDate)))"
}

let tools: [[String: Any]] = [
    tool("list_meetings", "List recorded meetings (newest first) with date, length, languages, open task count and a short overview.",
         ["limit": ["type": "integer", "description": "Maximum meetings to return (default 20)"],
          "since": ["type": "string", "description": "Only meetings on or after this date, YYYY-MM-DD"]]),
    tool("get_meeting", "Get one meeting's notes: the summary (overview, discussion, decisions, open questions, next actions, context) and optionally the full transcript. Speakers: \"Me\" is the user, \"Others\" is everyone else.",
         ["id": ["type": "string", "description": "Meeting id from list_meetings, or \"latest\""],
          "include_transcript": ["type": "boolean", "description": "Include the full transcript (default true)"]], required: ["id"]),
    tool("search", "Search meeting summaries, transcripts and dictations for words (all must appear in the same line; case and accents ignored).",
         ["query": ["type": "string"], "limit": ["type": "integer", "description": "Default 30"]], required: ["query"]),
    tool("list_tasks", "List next actions from all meeting summaries, with owner, due date and source meeting.",
         ["status": ["type": "string", "enum": ["open", "done", "all"], "description": "Default open"],
          "owner": ["type": "string", "description": "Only tasks for this owner, e.g. \"Me\""]]),
    tool("set_task_done", "Mark a meeting task done (or not done) in its meeting notes.",
         ["task_id": ["type": "string"], "done": ["type": "boolean", "description": "Default true"]], required: ["task_id"]),
    tool("list_dictations", "List the user's dictations (text dictated into apps), newest first.",
         ["limit": ["type": "integer", "description": "Default 50"], "query": ["type": "string", "description": "Only dictations containing this text"],
          "since": ["type": "string", "description": "YYYY-MM-DD"]]),
]

func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
    ["name": name, "description": description,
     "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
}

func sinceDate(_ args: [String: Any]) -> Date? {
    guard let s = args["since"] as? String else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: s)
}

func call(_ name: String, _ args: [String: Any]) throws -> String {
    switch name {
    case "list_meetings":
        var meetings = MurmurLibrary.meetings()
        if let since = sinceDate(args) { meetings = meetings.filter { $0.date >= since } }
        let limit = args["limit"] as? Int ?? 20
        guard !meetings.isEmpty else { return "No meetings recorded." }
        return "\(meetings.count) meeting(s):\n" + meetings.prefix(limit).map(describe).joined(separator: "\n")
    case "get_meeting":
        let id = args["id"] as? String ?? "latest"
        guard let m = id == "latest" ? MurmurLibrary.meetings().first : MurmurLibrary.meeting(id: id) else {
            throw ToolError("No meeting with id \(id). Use list_meetings to see ids.")
        }
        guard args["include_transcript"] as? Bool ?? true else {
            return "# \(m.title) — \(df.string(from: m.date)), \(m.minutes) min (id: \(m.id))\n\n\(m.summary)"
        }
        return m.markdown + "\n\n(meeting id: \(m.id))"
    case "search":
        let hits = MurmurLibrary.search(args["query"] as? String ?? "", limit: args["limit"] as? Int ?? 30)
        guard !hits.isEmpty else { return "No matches." }
        return hits.map { "- [\($0.source) \($0.id) — \($0.title), \(df.string(from: $0.date))] \($0.snippet)" }
            .joined(separator: "\n")
    case "list_tasks":
        let status = args["status"] as? String ?? "open"
        var tasks = MurmurLibrary.tasks().filter { status == "all" || $0.done == (status == "done") }
        if let owner = args["owner"] as? String { tasks = tasks.filter { $0.owner.caseInsensitiveCompare(owner) == .orderedSame } }
        guard !tasks.isEmpty else { return "No \(status == "all" ? "" : status + " ")tasks." }
        return tasks.map(describe).joined(separator: "\n")
    case "set_task_done":
        let id = args["task_id"] as? String ?? ""
        let done = args["done"] as? Bool ?? true
        guard MurmurLibrary.setTask(id, done: done) else { throw ToolError("No task with id \(id).") }
        return "Marked \(done ? "done" : "not done"): \(id)"
    case "list_dictations":
        var records = MurmurLibrary.dictations()
        if let since = sinceDate(args) { records = records.filter { $0.date >= since } }
        if let q = args["query"] as? String, !q.isEmpty {
            records = records.filter { $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        guard !records.isEmpty else { return "No dictations." }
        return records.prefix(args["limit"] as? Int ?? 50)
            .map { "- [\(df.string(from: $0.date)) · \($0.app) · \($0.language)] \($0.text)" }.joined(separator: "\n")
    default:
        throw ToolError("Unknown tool \(name)")
    }
}

struct ToolError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

func send(_ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func handle(_ request: [String: Any]) {
    let id = request["id"]
    let method = request["method"] as? String ?? ""
    let params = request["params"] as? [String: Any] ?? [:]
    func reply(_ result: [String: Any]) { if let id { send(["jsonrpc": "2.0", "id": id, "result": result]) } }
    switch method {
    case "initialize":
        reply(["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
               "capabilities": ["tools": [:]],
               "serverInfo": ["name": "murmur", "version": "0.2.0"],
               "instructions": "Murmur is the user's dictation and meeting-notes app. Use these tools to answer questions about their meetings (summaries, decisions, transcripts), their tasks from meetings, and what they dictated. In transcripts \"Me\" is the user; other people appear by name, or as \"Speaker 1\", \"Speaker 2\"… until named."])
    case "tools/list":
        reply(["tools": tools])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            reply(["content": [["type": "text", "text": try call(name, args)]]])
        } catch let error as ToolError {
            reply(["content": [["type": "text", "text": error.message]], "isError": true])
        } catch {
            reply(["content": [["type": "text", "text": "\(error)"]], "isError": true])
        }
    case "ping":
        reply([:])
    default:
        // Notifications (no id) need no answer; unknown requests get a JSON-RPC error.
        if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]) }
    }
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
    handle(request)
}
