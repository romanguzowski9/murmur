import AppKit
import MurmurCore
import SwiftUI

/// What the window needs from the menu-bar app (which owns the config, the recorder and the summarizer).
struct AppActions {
    var config: () -> MurmurConfig
    var updateConfig: ((inout MurmurConfig) -> Void) -> Void
    /// "Teams call · 12 min" while a meeting is being transcribed.
    var meetingStatus: () -> String?
    var toggleMeeting: () -> Void
    var resummarize: (MeetingNote) async -> Void
}

/// Asks for the Claude API key used for AI summaries and formatting; saved in Murmur's config file (readable
/// only by the user). Returns true when a key was saved.
enum ClaudeKey {
    @MainActor @discardableResult
    static func ask(_ actions: AppActions) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Claude API key"
        alert.informativeText = "Murmur sends meeting transcripts to Claude to write the summaries (about $0.04 for an "
            + "hour-long meeting with Sonnet). Create a key at console.anthropic.com → API Keys. It's stored in Murmur's "
            + "config file, readable only by you."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let hasKey = actions.config().llm.resolvedKey != nil
        if hasKey { alert.addButton(withTitle: "Remove key") }
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = hasKey ? "A key is set — paste a new one to replace it" : "sk-ant-api03-…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let key = field.stringValue.trimmed
            guard key.hasPrefix("sk-ant-") else { return false }
            actions.updateConfig { $0.llm.apiKey = key; $0.llm.enabled = true }
            return true
        case .alertThirdButtonReturn:
            actions.updateConfig { $0.llm.apiKey = "" }
            return false
        default:
            return false
        }
    }
}

struct DayGroup: Identifiable {
    var id: Date
    var records: [DictationRecord]
}

enum Section: String, CaseIterable, Identifiable {
    case home = "Home", meetings = "Meetings", tasks = "Tasks", history = "Dictations", dictionary = "Dictionary",
         ask = "Ask Claude"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "house"
        case .meetings: return "person.2.wave.2"
        case .tasks: return "checklist"
        case .history: return "waveform"
        case .dictionary: return "character.book.closed"
        case .ask: return "sparkles"
        }
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var section: Section? = .home
    @Published var meetings: [MeetingNote] = [] { didSet { deriveTasks() } }
    @Published var dictations: [DictationRecord] = [] { didSet { deriveDictations() } }
    // Worked out once per change, not on every redraw.
    @Published private(set) var tasks: [MeetingTask] = []
    @Published private(set) var openTasks: [MeetingTask] = []
    @Published private(set) var dictationDays: [DayGroup] = []
    @Published private(set) var totalWords = 0
    @Published private(set) var wordsThisWeek = 0
    /// The meeting shown on the right.
    @Published var selectedMeeting: String?
    /// Meetings selected in the list (several with ⌘/⇧-click), for deleting together.
    @Published var meetingSelection: Set<String> = []
    @Published var meetingStatus: String?
    @Published var config: MurmurConfig
    /// Meeting the Ask view is focused on (nil = everything).
    @Published var askFocus: String?
    @Published var chat: [ChatMessage] = []
    @Published var busyMeetings: Set<String> = []
    /// Tasks ticked for sharing together (ids).
    @Published var selectedTasks: Set<String> = []
    /// A short confirmation shown at the bottom of the window.
    @Published var toast: String?
    /// "Undo" next to the toast, when the action can be undone.
    @Published var toastUndo: (() -> Void)?
    private var toastHide: DispatchWorkItem?

    func show(_ message: String, undo: (() -> Void)? = nil) {
        toast = message
        toastUndo = undo
        toastHide?.cancel()
        let hide = DispatchWorkItem { [weak self] in
            self?.toast = nil
            self?.toastUndo = nil
        }
        toastHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: hide)
    }

    let actions: AppActions
    private var timer: Timer?

    init(actions: AppActions) {
        self.actions = actions
        config = actions.config()
    }

    private func deriveTasks() {
        tasks = meetings.flatMap(\.tasks)
        openTasks = tasks.filter { !$0.done }
    }

    private func deriveDictations() {
        let cal = Calendar.current
        var days: [DayGroup] = []
        for d in dictations {  // already newest first
            let day = cal.startOfDay(for: d.date)
            if days.last?.id == day { days[days.count - 1].records.append(d) } else { days.append(DayGroup(id: day, records: [d])) }
        }
        dictationDays = days
        let weekStart = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        totalWords = dictations.reduce(0) { $0 + $1.text.wordCount }
        wordsThisWeek = dictations.filter { $0.date > weekStart }.reduce(0) { $0 + $1.text.wordCount }
    }

    /// Fingerprint of the files last loaded; a refresh that finds the same one does nothing.
    private var signature = ""

    /// Reloads notes and dictations from disk, off the main thread, and only when the files changed.
    func reload(force: Bool = false) {
        meetingStatus = actions.meetingStatus()
        let latest = actions.config()
        if latest != config { config = latest }
        let known = force ? "" : signature
        Task.detached(priority: .userInitiated) {
            let current = MurmurLibrary.signature()
            guard current != known else { return }
            let meetings = MurmurLibrary.meetings()
            let dictations = MurmurLibrary.dictations()
            await MainActor.run {
                self.signature = current
                self.meetings = meetings
                self.dictations = dictations
                if self.selectedMeeting == nil, let first = meetings.first?.id {
                    self.selectedMeeting = first
                    self.meetingSelection = [first]
                }
            }
        }
    }

    /// Deletes dictations; Undo (the toast button, or ⌘Z) puts them back.
    func deleteDictations(_ ids: Set<Int>, undoManager: UndoManager? = nil) {
        let removed = MurmurLibrary.deleteDictations(ids)
        guard !removed.isEmpty else { return }
        dictations.removeAll { ids.contains($0.id) }  // at once; the reload renumbers them
        reload(force: true)
        let undo = { [weak self] in
            MurmurLibrary.restoreDictations(removed)
            self?.reload(force: true)
            self?.toast = nil
        }
        undoManager?.registerUndo(withTarget: self) { _ in undo() }
        undoManager?.setActionName(removed.count == 1 ? "Delete Dictation" : "Delete Dictations")
        show(removed.count == 1 ? "Dictation deleted" : "\(removed.count) dictations deleted", undo: undo)
    }

    func startAutoRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    func setTask(_ task: MeetingTask, done: Bool) {
        MurmurLibrary.setTask(task.id, done: done)
        if let m = meetings.firstIndex(where: { $0.id == task.meetingID }), let note = MurmurLibrary.meeting(at: meetings[m].url) {
            meetings[m] = note
        }
    }

    func updateConfig(_ change: (inout MurmurConfig) -> Void) {
        actions.updateConfig(change)
        config = actions.config()
    }

    func open(meeting id: String) {
        selectedMeeting = id
        meetingSelection = [id]
        section = .meetings
    }

    /// Moves meetings to the Trash; Undo (the toast button, or ⌘Z) brings them back.
    func deleteMeetings(_ ids: Set<String>, undoManager: UndoManager? = nil) {
        let recording = meetings.filter { ids.contains($0.id) && $0.inProgress }
        let moved = MurmurLibrary.trashMeetings(ids)
        guard !moved.isEmpty else {
            if !recording.isEmpty { show("A meeting that's still recording can't be deleted") }
            return
        }
        let gone = Set(moved.map { $0.from.deletingPathExtension().lastPathComponent })
        // Show the next meeting down the list.
        let order = meetings.map(\.id)
        let next = order.drop { !gone.contains($0) }.first { !gone.contains($0) } ?? order.last { !gone.contains($0) }
        meetings.removeAll { gone.contains($0.id) }
        selectedMeeting = next
        meetingSelection = next.map { [$0] } ?? []
        reload(force: true)
        let undo = { [weak self] in
            MurmurLibrary.restoreMeetings(moved)
            self?.reload(force: true)
            self?.toast = nil
        }
        undoManager?.registerUndo(withTarget: self) { _ in undo() }
        undoManager?.setActionName(moved.count == 1 ? "Delete Meeting" : "Delete Meetings")
        show((moved.count == 1 ? "Meeting moved to the Trash" : "\(moved.count) meetings moved to the Trash")
             + (recording.isEmpty ? "" : " (the one still recording was kept)"), undo: undo)
    }

    /// Names a speaker throughout a meeting ("Speaker 1" → "Maria"); naming two speakers the same merges them.
    func renameSpeaker(_ note: MeetingNote, _ speaker: String, to name: String, undoManager: UndoManager? = nil) {
        guard let before = try? String(contentsOf: note.url, encoding: .utf8),
              MurmurLibrary.renameSpeakers(note.url, [speaker: name]) else { return }
        reload(force: true)
        let undo = { [weak self] in
            try? before.write(to: note.url, atomically: true, encoding: .utf8)
            self?.reload(force: true)
            self?.toast = nil
        }
        undoManager?.registerUndo(withTarget: self) { _ in undo() }
        undoManager?.setActionName("Name Speaker")
        show("\(speaker) is now \(name)", undo: undo)
    }

    func ask(about id: String?) {
        askFocus = id
        section = .ask
    }
}

// MARK: Window

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let model: LibraryModel
    private var window: NSWindow?

    init(actions: AppActions) {
        model = LibraryModel(actions: actions)
    }

    func show(section: Section? = nil, meeting: String? = nil) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Murmur"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 820, height: 520)
            w.contentView = NSHostingView(rootView: RootView().environmentObject(model))
            w.setFrameAutosaveName("MurmurMain")
            if !w.setFrameUsingName("MurmurMain") { w.center() }
            w.delegate = self
            window = w
        }
        if let meeting { model.open(meeting: meeting) } else if let section { model.section = section }
        model.reload()
        model.startAutoRefresh()
        NSApp.setActivationPolicy(.regular)
        if let icon = NSImage(named: "AppIcon") { NSApp.applicationIconImage = icon }
        window?.makeKeyAndOrderFront(nil)
        // macOS may refuse to activate an app launched in the background; still bring the window up.
        window?.orderFrontRegardless()
        NSApp.activate()
    }

    /// Switches the window through its sections and returns how long each took to update and draw (ms).
    func timeSections(rounds: Int = 2) -> [(String, Double)] {
        var out: [(String, Double)] = []
        let order: [Section] = [.home, .tasks, .meetings, .tasks, .meetings, .history, .dictionary, .home]
        for _ in 0..<rounds {
            for section in order {
                let start = Date()
                model.section = section
                window?.contentView?.layoutSubtreeIfNeeded()
                window?.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                window?.displayIfNeeded()
                out.append((section.rawValue, Date().timeIntervalSince(start) * 1000))
            }
        }
        return out
    }

    func windowWillClose(_ notification: Notification) {
        model.stopAutoRefresh()
        // Back to a menu-bar-only app.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.reload()
    }
}

// MARK: Root

struct RootView: View {
    @EnvironmentObject var model: LibraryModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.section) {
                ForEach(Section.allCases) { s in
                    Label {
                        HStack {
                            Text(s.rawValue)
                            Spacer()
                            if s == .tasks, !model.openTasks.isEmpty {
                                Text("\(model.openTasks.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    } icon: { Image(systemName: s.icon) }
                    .tag(s)
                }
            }
            .safeAreaInset(edge: .bottom) { MeetingStatusBox().padding(10) }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                switch model.section ?? .home {
                case .home: HomeView()
                case .meetings: MeetingsView()
                case .tasks: TasksView()
                case .history: HistoryView()
                case .dictionary: DictionaryView()
                case .ask: AskView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .bottom) {
                if let toast = model.toast {
                    HStack(spacing: 12) {
                        Text(toast)
                        if let undo = model.toastUndo {
                            Button("Undo") { undo() }.buttonStyle(.link)
                        }
                    }
                    .font(.callout).padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Capsule().fill(.regularMaterial))
                        .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.toast)
        }
    }
}

struct MeetingStatusBox: View {
    @EnvironmentObject var model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let status = model.meetingStatus {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(status).font(.caption).lineLimit(1)
                }
                Button("Stop meeting notes") { model.actions.toggleMeeting(); model.reload() }
                    .controlSize(.small)
            } else {
                Text("Meetings are detected automatically.").font(.caption).foregroundStyle(.secondary)
                Button("Start meeting notes") { model.actions.toggleMeeting(); model.reload() }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: Shared pieces

/// View-local state like `@State`, which is a compiler macro this toolchain (Command Line Tools, no Xcode) can't expand.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    final class Storage: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }

    @StateObject private var storage: Storage

    init(wrappedValue: Value) {
        _storage = StateObject(wrappedValue: Storage(wrappedValue))
    }

    var wrappedValue: Value {
        get { storage.value }
        nonmutating set { storage.value = newValue }
    }

    var projectedValue: Binding<Value> { $storage.value }
}

let accent = Color(red: 0.42, green: 0.30, blue: 0.95)

struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .semibold, design: .serif))
                if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 12)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct SearchField: View {
    var prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07)))
    }
}

/// Inline Markdown (bold, italics, links) as styled text. Parsing is slow next to drawing, so each string is parsed
/// once and remembered (views ask again on every redraw).
@MainActor
func inline(_ text: String) -> AttributedString {
    if let cached = inlineCache[text] { return cached }
    let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
    if inlineCache.count > 20_000 { inlineCache.removeAll() }
    inlineCache[text] = parsed
    return parsed
}

@MainActor private var inlineCache: [String: AttributedString] = [:]

func dayTitle(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return "Today" }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
}

/// Renders Murmur's summary Markdown: headings, bullets, tables, notes and paragraphs. Tasks (checkbox bullets and
/// action-items table rows) get working checkboxes, in the same order as `MeetingNote.tasks`.
struct MarkdownView: View {
    var markdown: String
    var tasks: [MeetingTask] = []
    var onToggle: ((MeetingTask, Bool) -> Void)?

    enum Block: Identifiable {
        case line(Int, String, task: Int?)
        case table(Int, header: [String], rows: [(cells: [String], task: Int?)])
        var id: Int {
            switch self {
            case let .line(i, _, _), let .table(i, _, _): return i
            }
        }
    }

    var blocks: [Block] {
        let lines = markdown.components(separatedBy: "\n")
        var order: [Int: Int] = [:]
        for (n, parsed) in MurmurLibrary.parseTasks(lines).enumerated() { order[parsed.0] = n }
        func cells(_ line: String) -> [String] {
            var row = line.trimmed
            if row.hasPrefix("|") { row.removeFirst() }
            if row.hasSuffix("|") { row.removeLast() }
            return row.components(separatedBy: "|").map { $0.trimmed }
        }
        func isSeparator(_ t: String) -> Bool { t.hasPrefix("|") && t.contains("-") && t.allSatisfy { "|-: ".contains($0) } }
        var out: [Block] = []
        var i = 0
        while i < lines.count {
            let t = lines[i].trimmed
            if t.hasPrefix("|"), i + 1 < lines.count, isSeparator(lines[i + 1].trimmed) {
                let start = i
                let header = cells(t)
                var rows: [(cells: [String], task: Int?)] = []
                i += 2
                while i < lines.count, lines[i].trimmed.hasPrefix("|") {
                    rows.append((cells(lines[i]), order[i]))
                    i += 1
                }
                out.append(.table(start, header: header, rows: rows))
                continue
            }
            out.append(.line(i, t, task: order[i]))
            i += 1
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks) { block in
                switch block {
                case let .line(_, line, task): row(line, task: task)
                case let .table(_, header, rows): table(header, rows)
                }
            }
        }
        .textSelection(.enabled)
    }

    func checkbox(_ t: MeetingTask) -> some View {
        Button { onToggle?(t, !t.done) } label: {
            Image(systemName: t.done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(t.done ? accent : .secondary)
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    func table(_ header: [String], _ rows: [(cells: [String], task: Int?)]) -> some View {
        let isTasks = rows.contains { $0.task != nil }
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                if isTasks { Text("") }
                ForEach(Array(header.enumerated()), id: \.offset) { _, h in
                    Text(inline(h)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                GridRow {
                    if let n = r.task, n < tasks.count {
                        let t = tasks[n]
                        checkbox(t)
                        Text(inline(t.text)).strikethrough(t.done).foregroundStyle(t.done ? .secondary : .primary)
                            .frame(maxWidth: 420, alignment: .leading)
                        Text(t.owner).font(.callout.weight(.medium))
                            .foregroundStyle(t.owner == "Not specified" ? .secondary : (t.owner == "Me" ? accent : .primary))
                        Text(t.due ?? "Not specified").font(.callout).foregroundStyle(t.due == nil ? .secondary : Color.orange)
                    } else {
                        if isTasks { Text("") }
                        ForEach(Array(r.cells.enumerated()), id: \.offset) { _, c in Text(inline(c)) }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
    }

    @ViewBuilder
    func row(_ line: String, task: Int?) -> some View {
        if let task, task < tasks.count {
            let t = tasks[task]
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                checkbox(t)
                (Text(t.owner).bold() + Text("  ") + Text(inline(t.text))
                    + Text(t.due.map { "  · due \($0)" } ?? "").foregroundColor(.orange))
                    .strikethrough(t.done)
                    .foregroundStyle(t.done ? .secondary : .primary)
            }
        } else if line.hasPrefix("#") {
            Text(inline(line.drop { $0 == "#" }.trimmed))
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 10)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(accent)
                Text(inline(String(line.dropFirst(2))))
            }
        } else if line.hasPrefix("_"), line.hasSuffix("_") {
            Text(inline(line)).font(.callout).foregroundStyle(.secondary)
        } else if !line.isEmpty {
            Text(inline(line))
        }
    }
}

// MARK: Home

struct HomeView: View {
    @EnvironmentObject var model: LibraryModel

    var firstName: String { NSFullUserName().split(separator: " ").first.map(String.init) ?? "" }
    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    var weekStart: Date { Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "\(greeting), \(firstName)", subtitle: "Hold fn to dictate anywhere · your meetings are noted and summarized automatically")
                    .padding(.horizontal, -28)
                HStack(spacing: 12) {
                    stat("Words dictated", "\(model.wordsThisWeek)", "this week")
                    stat("Dictations", "\(model.dictations.count)", "all time")
                    stat("Meetings", "\(model.meetings.filter { $0.date > weekStart }.count)", "this week")
                    stat("Open tasks", "\(model.openTasks.count)", "from meetings")
                }
                if !model.openTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Open tasks", action: "See all") { model.section = .tasks }
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(model.openTasks.prefix(5)) { TaskRow(task: $0) }
                            }
                        }
                    }
                }
                if !model.meetings.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Recent meetings", action: "See all") { model.section = .meetings }
                        ForEach(model.meetings.prefix(3)) { m in
                            Button { model.open(meeting: m.id) } label: {
                                Card { MeetingRowContent(meeting: m, expanded: true) }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Recent dictations", action: "See all") { model.section = .history }
                    if model.dictations.isEmpty {
                        Text("Nothing yet — hold fn and start talking.").foregroundStyle(.secondary)
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(model.dictations.prefix(6).enumerated()), id: \.element.id) { i, d in
                                if i > 0 { Divider().padding(.vertical, 8) }
                                DictationRow(record: d)
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    func stat(_ title: String, _ value: String, _ note: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(note).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    func sectionTitle(_ title: String, action: String, _ go: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Button(action, action: go).buttonStyle(.link)
        }
    }
}

struct DictationRow: View {
    @EnvironmentObject var model: LibraryModel
    @Environment(\.undoManager) private var undoManager
    var record: DictationRecord
    /// In the Dictations list the row's own buttons stay, plus selection; elsewhere a context menu does it.
    var showButtons = true

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(record.date.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.text)
                Text([record.app, record.language].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if showButtons {
                Button { Paster.copy(record.text); model.show("Copied") } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary).help("Copy")
                Button { model.deleteDictations([record.id], undoManager: undoManager) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary).help("Delete (⌫)")
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy") { Paster.copy(record.text) }
            Button("Delete") { model.deleteDictations([record.id], undoManager: undoManager) }
        }
    }
}

// MARK: Meetings

struct MeetingRowContent: View {
    var meeting: MeetingNote
    var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(meeting.title).font(.headline)
                if meeting.inProgress {
                    Text("LIVE").font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(.red))
                }
                Spacer()
                let open = meeting.tasks.filter { !$0.done }.count
                if open > 0 { Label("\(open)", systemImage: "checklist").font(.caption).foregroundStyle(.secondary) }
            }
            Text("\(meeting.date.formatted(date: .abbreviated, time: .shortened)) · \(meeting.minutes) min"
                 + (meeting.languages.isEmpty ? "" : " · " + meeting.languages.joined(separator: ", ")))
                .font(.caption).foregroundStyle(.secondary)
            if !meeting.overview.isEmpty {
                Text(inline(meeting.overview)).font(.callout).foregroundStyle(.secondary).lineLimit(expanded ? 3 : 2)
            }
        }
    }
}

struct MeetingsView: View {
    @EnvironmentObject var model: LibraryModel
    @Environment(\.undoManager) private var undoManager
    @Local private var query = ""

    var filtered: [MeetingNote] {
        guard !query.isEmpty else { return model.meetings }
        return model.meetings.filter {
            $0.markdown.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SearchField(prompt: "Search meetings", text: $query).padding(12)
                // Click to open; ⌘- or ⇧-click to select several; ⌫ or right-click to delete.
                List(selection: $model.meetingSelection) {
                    ForEach(Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.date) }
                        .sorted { $0.key > $1.key }, id: \.key) { day, notes in
                        SwiftUI.Section(dayTitle(day)) {
                            ForEach(notes) { MeetingRowContent(meeting: $0).padding(.vertical, 4).tag($0.id) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: model.meetingSelection) { _, selection in
                    if selection.count == 1, let id = selection.first, id != model.selectedMeeting { model.selectedMeeting = id }
                }
                .onDeleteCommand { model.deleteMeetings(model.meetingSelection, undoManager: undoManager) }
                .contextMenu(forSelectionType: String.self) { ids in
                    Button(ids.count > 1 ? "Move \(ids.count) Meetings to Trash" : "Move to Trash") {
                        model.deleteMeetings(ids, undoManager: undoManager)
                    }
                    if ids.count == 1, let id = ids.first, let note = model.meetings.first(where: { $0.id == id }) {
                        Divider()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
                        Divider()
                        Button("Move to Trash", role: .destructive) { model.deleteMeetings([note.id], undoManager: undoManager) }
                            .disabled(note.inProgress)
                    }
                }
                .overlay {
                    if filtered.isEmpty {
                        Text(query.isEmpty ? "No meetings yet.\nCalls in Meet, Teams, WhatsApp and Zoom are\ntranscribed automatically."
                             : "No matches").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 320)
            Divider()
            if model.meetingSelection.count > 1 {
                VStack(spacing: 14) {
                    Image(systemName: "doc.on.doc").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("\(model.meetingSelection.count) meetings selected").font(.title3.weight(.semibold))
                    Button(role: .destructive) { model.deleteMeetings(model.meetingSelection, undoManager: undoManager) } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                    Text("or press ⌫").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let id = model.selectedMeeting, let note = model.meetings.first(where: { $0.id == id }) {
                MeetingDetail(note: note).id(note.id)
            } else {
                Text("Select a meeting").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct MeetingDetail: View {
    @EnvironmentObject var model: LibraryModel
    @Environment(\.undoManager) private var undoManager
    var note: MeetingNote
    @Local private var tab = 0
    @Local private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(note.title).font(.system(size: 24, weight: .semibold, design: .serif))
                    if note.inProgress { Text("● recording").font(.caption).foregroundStyle(.red) }
                    Spacer()
                    Button {
                        let mail = Sharing.summaryEmail(note)
                        Share.email(subject: mail.subject, body: mail.body)
                    } label: { Label("Email summary", systemImage: "envelope") }
                        .help("Open a new email with this meeting's summary")
                    Button { model.ask(about: note.id) } label: { Label("Ask Claude", systemImage: "sparkles") }
                    Menu {
                        Button("Rename…") { rename() }
                        Divider()
                        Button("Copy summary") { Paster.copy(note.summary) }
                        Button("Copy transcript") {
                            Paster.copy(note.transcript.map { "[\($0.time)] \($0.speaker): \($0.text)" }.joined(separator: "\n"))
                        }
                        Button("Copy everything (Markdown)") { Paster.copy(note.markdown) }
                        Divider()
                        Button("Regenerate title & summary") { regenerate() }
                            .disabled(note.inProgress || note.transcript.isEmpty)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
                        Button("Open file") { NSWorkspace.shared.open(note.url) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                Text("\(note.date.formatted(date: .complete, time: .shortened)) · \(note.minutes) min · \(note.wordCount) words"
                     + (note.languages.isEmpty ? "" : " · " + note.languages.joined(separator: ", ")))
                    .font(.callout).foregroundStyle(.secondary)
                SpeakersBar(note: note)
                Picker("", selection: $tab) {
                    Text("Summary").tag(0)
                    Text("Transcript (\(note.transcript.count))").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
            }
            .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 12)
            Divider()
            if tab == 0 {
                ScrollView {
                    VStack(alignment: .leading) {
                        if model.busyMeetings.contains(note.id) {
                            ProgressView("Writing a new summary…").padding(.bottom)
                        }
                        if note.summary.contains("Automatic offline summary"), !note.inProgress, !note.transcript.isEmpty {
                            offlineNotice
                        }
                        MarkdownView(markdown: note.summary, tasks: note.tasks) { task, done in model.setTask(task, done: done) }
                    }
                    .padding(28).frame(maxWidth: 820, alignment: .leading)
                }
            } else {
                SearchField(prompt: "Search transcript", text: $query).padding(.horizontal, 28).padding(.vertical, 10)
                TranscriptView(lines: note.transcript.filter {
                    query.isEmpty || $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                })
            }
        }
    }
}

extension MeetingDetail {
    /// The offline summary only picks out sentences; Claude writes real notes (like Wispr Flow's).
    var offlineNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(accent)
            Text(model.actions.config().llm.resolvedKey == nil
                 ? "This summary was made offline. Add a Claude API key for notes with topics, decisions and tasks."
                 : "This summary was made offline. Claude can write it again now.")
                .font(.callout)
            Spacer()
            Button(model.actions.config().llm.resolvedKey == nil ? "Add key & rewrite" : "Rewrite with Claude") {
                if model.actions.config().llm.resolvedKey == nil, !ClaudeKey.ask(model.actions) { return }
                regenerate()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.08)))
        .padding(.bottom, 14)
    }

    func regenerate() {
        model.busyMeetings.insert(note.id)
        Task {
            await model.actions.resummarize(note)
            model.busyMeetings.remove(note.id)
            model.reload()
        }
    }

    func rename() {
        let alert = NSAlert()
        alert.messageText = "Rename meeting"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: note.title)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmed
        guard !title.isEmpty else { return }
        MurmurLibrary.rewrite(note.url, title: title)
        model.reload()
    }
}

/// The other people in a meeting, as chips: click one to give it a name (suggestions come from the call app's
/// participant list) or to say it's the same person as another speaker.
struct SpeakersBar: View {
    @EnvironmentObject var model: LibraryModel
    @Environment(\.undoManager) private var undoManager
    var note: MeetingNote

    var body: some View {
        let speakers = note.speakers
        if !speakers.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "person.2").foregroundStyle(.secondary).help("People in this meeting")
                chip("Me", lines: note.transcript.filter { $0.speaker == "Me" }.count, nameable: false)
                ForEach(speakers, id: \.self) { speaker in
                    Menu {
                        let suggestions = note.participants.filter { p in !speakers.contains { SpeakerNames.isSame($0, p) } }
                        ForEach(suggestions, id: \.self) { p in
                            Button(p) { model.renameSpeaker(note, speaker, to: p, undoManager: undoManager) }
                        }
                        if !suggestions.isEmpty { Divider() }
                        Button("Name…") { askName(speaker) }
                        let others = speakers.filter { $0 != speaker }
                        if !others.isEmpty {
                            Menu("Same person as") {
                                ForEach(others, id: \.self) { o in
                                    Button(o) { model.renameSpeaker(note, speaker, to: o, undoManager: undoManager) }
                                }
                            }
                        }
                    } label: {
                        chip(speaker, lines: note.transcript.filter { $0.speaker == speaker }.count, nameable: true)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Name this speaker")
                }
                if speakers.contains(where: { $0.hasPrefix("Speaker ") || $0 == "Others" }) {
                    Text("Click a speaker to name them").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func chip(_ name: String, lines: Int, nameable: Bool) -> some View {
        HStack(spacing: 4) {
            Text(name).font(.callout.weight(.medium))
            Text("\(lines)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if nameable { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(name == "Me" ? accent.opacity(0.15) : Color.orange.opacity(0.15)))
    }

    private func askName(_ speaker: String) {
        let alert = NSAlert()
        alert.messageText = "Who is \(speaker)?"
        let quotes = note.transcript.filter { $0.speaker == speaker }.sorted { $0.text.count > $1.text.count }.prefix(3)
        alert.informativeText = quotes.map { "[\($0.time)] \(String($0.text.prefix(140)))" }.joined(separator: "\n\n")
        alert.addButton(withTitle: "Name")
        alert.addButton(withTitle: "Cancel")
        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        field.addItems(withObjectValues: note.participants)
        field.completes = true
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmed
        if !name.isEmpty { model.renameSpeaker(note, speaker, to: name, undoManager: undoManager) }
    }
}

struct TranscriptView: View {
    var lines: [TranscriptLine]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    let me = line.speaker == "Me"
                    HStack(alignment: .top, spacing: 12) {
                        Text(line.time).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 62, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.speaker).font(.caption.bold()).foregroundStyle(me ? accent : .orange)
                            Text(line.text).textSelection(.enabled)
                        }
                    }
                }
                if lines.isEmpty { Text("No transcript.").foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 28).padding(.bottom, 28)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

// MARK: Tasks

struct TaskRow: View {
    @EnvironmentObject var model: LibraryModel
    var task: MeetingTask
    var showSource = true
    var selectable = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if selectable {
                Toggle("", isOn: Binding(
                    get: { model.selectedTasks.contains(task.id) },
                    set: { on in
                        if on { model.selectedTasks.insert(task.id) } else { model.selectedTasks.remove(task.id) }
                    }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .help("Select to share several tasks at once")
            }
            Button { model.setTask(task, done: !task.done) } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle").font(.system(size: 15))
                    .foregroundStyle(task.done ? accent : .secondary)
            }.buttonStyle(.plain).help(task.done ? "Mark as not done" : "Mark as done")
            VStack(alignment: .leading, spacing: 3) {
                Text(inline(task.text)).strikethrough(task.done).foregroundStyle(task.done ? .secondary : .primary)
                HStack(spacing: 8) {
                    Text(task.owner).font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill((task.owner == "Me" ? accent : Color.orange).opacity(0.15)))
                    if let due = task.due { Label(due, systemImage: "calendar").font(.caption).foregroundStyle(.orange) }
                    if showSource {
                        Button("\(task.meetingTitle) · \(task.meetingDate.formatted(date: .abbreviated, time: .omitted))") {
                            model.open(meeting: task.meetingID)
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
            }
            Spacer()
            TaskActionButtons(tasks: [task])
        }
    }
}

/// Copy tasks, or hand them to Outlook (email), WhatsApp, Teams or Calendar, filled in and in the language of their
/// meeting's transcript. Nothing is sent: the user picks the recipients and sends.
struct TaskActionButtons: View {
    @EnvironmentObject var model: LibraryModel
    var tasks: [MeetingTask]
    var labels = false

    var body: some View {
        HStack(spacing: labels ? 8 : 2) {
            button("doc.on.doc", "Copy", "Copy to the clipboard") {
                Paster.copy(Sharing.taskList(tasks))
                model.show(tasks.count == 1 ? "Task copied" : "\(tasks.count) tasks copied")
            }
            button("envelope", "Email", "New email with \(tasks.count == 1 ? "this task" : "these tasks")") {
                let mail = Sharing.tasksEmail(tasks)
                Share.email(subject: mail.subject, body: mail.body)
            }
            button("message", "WhatsApp", "New WhatsApp chat with \(tasks.count == 1 ? "this task" : "these tasks")") {
                Share.whatsApp(Sharing.chatMessage(tasks))
                model.show("Message copied — choose a contact in WhatsApp's new chat and paste (⌘V)")
            }
            button("person.2", "Teams", "New Teams chat with \(tasks.count == 1 ? "this task" : "these tasks")") {
                Share.teams(Sharing.chatMessage(tasks))
            }
            button("calendar.badge.plus", "Calendar", "Create a meeting in Calendar") { Share.addToCalendar(tasks) }
        }
        .disabled(tasks.isEmpty)
    }

    @ViewBuilder
    func button(_ icon: String, _ title: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        if labels {
            Button(action: action) { Label(title, systemImage: icon) }.help(help)
        } else {
            Button(action: action) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 26, height: 22)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(help)
        }
    }
}

/// Hands content to the default mail app, WhatsApp, Teams and the default calendar app.
enum Share {
    static func email(subject: String, body: String) {
        guard let url = Sharing.mailtoURL(subject: subject, body: body) else { return }
        NSWorkspace.shared.open(url)
    }

    static func teams(_ text: String) {
        guard let url = Sharing.teamsURL(text: text) else { return }
        NSWorkspace.shared.open(url)
    }

    /// WhatsApp has no link that opens an empty new chat with text, so: copy the message, bring WhatsApp up and press
    /// ⌘N (New Chat); the user picks the contact and pastes. Without the desktop app, WhatsApp Web's picker is used.
    static func whatsApp(_ text: String) {
        Paster.copy(text)
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") else {
            if let url = Sharing.whatsAppURL(text: text, app: false) { NSWorkspace.shared.open(url) }
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { running, _ in
            pressNewChat(in: running, tries: 20)
        }
    }

    private static func pressNewChat(in running: NSRunningApplication?, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "net.whatsapp.WhatsApp"
            guard front else {
                if tries > 0 { pressNewChat(in: running, tries: tries - 1) }
                return
            }
            // Give the window a moment to take focus, then ⌘N.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let source = CGEventSource(stateID: .hidSystemState)
                for down in [true, false] {
                    let key = CGEvent(keyboardEventSource: source, virtualKey: 45, keyDown: down)  // N
                    key?.flags = .maskCommand
                    key?.post(tap: .cghidEventTap)
                }
            }
        }
    }

    static func addToCalendar(_ tasks: [MeetingTask]) {
        let ics = Sharing.calendarInvite(for: tasks, start: Sharing.meetingStart(for: tasks))
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/Invites", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Tasks \(UUID().uuidString.prefix(8)).ics")
        guard (try? ics.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        NSWorkspace.shared.open(url)
    }
}

struct TasksView: View {
    @EnvironmentObject var model: LibraryModel
    @Local private var filter = 0
    @Local private var mineOnly = false

    var shown: [MeetingTask] {
        model.tasks.filter { (filter == 0 ? !$0.done : filter == 1 ? $0.done : true) && (!mineOnly || $0.owner == "Me") }
    }

    var groups: [(key: String, value: [MeetingTask])] {
        Dictionary(grouping: shown, by: \.meetingID)
            .sorted { ($0.value.first?.meetingDate ?? .distantPast) > ($1.value.first?.meetingDate ?? .distantPast) }
    }

    /// Selected tasks in the order they're listed.
    var selected: [MeetingTask] {
        groups.flatMap(\.value).filter { model.selectedTasks.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Tasks", subtitle: "Next actions collected from every meeting summary") {
                HStack {
                    Toggle("Only mine", isOn: $mineOnly).toggleStyle(.checkbox)
                    Picker("", selection: $filter) {
                        Text("Open").tag(0)
                        Text("Done").tag(1)
                        Text("All").tag(2)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
            }
            selectionBar
            ScrollView {
                // Lazy: only the meetings on screen are built (all of them at once took over a second).
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.key) { _, tasks in
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Button { model.open(meeting: tasks[0].meetingID) } label: {
                                        Text("\(tasks[0].meetingTitle) · \(dayTitle(tasks[0].meetingDate))").font(.headline)
                                    }.buttonStyle(.plain)
                                    Spacer()
                                    let all = tasks.allSatisfy { model.selectedTasks.contains($0.id) }
                                    Button(all ? "Deselect" : "Select all") {
                                        if all { model.selectedTasks.subtract(tasks.map(\.id)) } else { model.selectedTasks.formUnion(tasks.map(\.id)) }
                                    }.buttonStyle(.link).font(.caption)
                                }
                                ForEach(tasks) { TaskRow(task: $0, showSource: false, selectable: true) }
                            }
                        }
                    }
                    if shown.isEmpty {
                        Text(filter == 0 ? "No open tasks. 🎉" : "Nothing here.").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 28)
                .frame(maxWidth: 900, alignment: .leading)
            }
        }
    }

    /// Shown while tasks are selected: share them all at once.
    @ViewBuilder
    var selectionBar: some View {
        let tasks = selected
        if !tasks.isEmpty {
            HStack(spacing: 12) {
                Text("\(tasks.count) selected").font(.callout.weight(.semibold))
                TaskActionButtons(tasks: tasks, labels: true)
                Spacer()
                Button("Clear") { model.selectedTasks.removeAll() }.buttonStyle(.link)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(accent.opacity(0.1)))
            .padding(.horizontal, 28).padding(.bottom, 12)
        }
    }
}

// MARK: History

struct HistoryView: View {
    @EnvironmentObject var model: LibraryModel
    @Environment(\.undoManager) private var undoManager
    @Local private var query = ""
    @Local private var selection: Set<Int> = []

    var groups: [DayGroup] {
        guard !query.isEmpty else { return model.dictationDays }
        return model.dictationDays.compactMap { g in
            let hits = g.records.filter {
                $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || $0.app.range(of: query, options: .caseInsensitive) != nil
            }
            return hits.isEmpty ? nil : DayGroup(id: g.id, records: hits)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Dictations", subtitle: "\(model.dictations.count) dictations · \(model.totalWords) words") {
                HStack(spacing: 10) {
                    if !selection.isEmpty {
                        Button(role: .destructive) { delete(selection) } label: {
                            Label("Delete \(selection.count)", systemImage: "trash")
                        }
                        .help("Delete the selected dictations (⌫)")
                    }
                    SearchField(prompt: "Search", text: $query).frame(width: 240)
                }
            }
            List(selection: $selection) {
                ForEach(groups) { group in
                    SwiftUI.Section(dayTitle(group.id)) {
                        ForEach(group.records) { DictationRow(record: $0).padding(.vertical, 4).tag($0.id) }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            // ⌫ / Delete removes the selected dictations (click to select, ⌘ or ⇧ to select several, ⌘A for all).
            .onDeleteCommand { delete(selection) }
            .contextMenu(forSelectionType: Int.self) { ids in
                Button("Copy") {
                    Paster.copy(model.dictations.filter { ids.contains($0.id) }.map(\.text).joined(separator: "\n\n"))
                }
                Button(ids.count > 1 ? "Delete \(ids.count) Dictations" : "Delete") { delete(ids) }
            }
        }
    }

    func delete(_ ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        model.deleteDictations(ids, undoManager: undoManager)
        selection = []
    }
}

// MARK: Dictionary

struct DictionaryView: View {
    @EnvironmentObject var model: LibraryModel
    @Local private var newWord = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Dictionary", subtitle: "Names and terms Murmur listens for. Words you correct after dictating are added automatically.")
            HStack {
                TextField("Add a word or name (e.g. Acme Cargo)", text: $newWord).textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(newWord.trimmed.isEmpty)
            }
            .padding(.horizontal, 28).padding(.bottom, 12)
            List {
                ForEach(model.config.dictionary, id: \.word) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.word).font(.body.weight(.medium))
                                if entry.learned == true {
                                    Text("learned").font(.caption2).padding(.horizontal, 5)
                                        .background(Capsule().fill(accent.opacity(0.15)))
                                }
                            }
                            if let heard = entry.misspellings, !heard.isEmpty {
                                Text("Replaces: " + heard.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button { model.updateConfig { $0.dictionary.removeAll { $0.word == entry.word } } } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless)
                    }.padding(.vertical, 3)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .overlay { if model.config.dictionary.isEmpty { Text("No words yet.").foregroundStyle(.secondary) } }
        }
    }

    func add() {
        let word = newWord.trimmed
        guard !word.isEmpty else { return }
        model.updateConfig { config in
            if !config.dictionary.contains(where: { $0.word == word }) { config.dictionary.append(DictionaryEntry(word: word)) }
        }
        newWord = ""
    }
}

// MARK: Ask Claude

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var role: String
    var text: String
}

struct AskView: View {
    @EnvironmentObject var model: LibraryModel
    @Local private var input = ""
    @Local private var busy = false
    @Local private var apiKey = ""

    var hasKey: Bool { model.config.llm.resolvedKey != nil }
    var focusTitle: String? {
        model.askFocus.flatMap { id in model.meetings.first { $0.id == id } }
            .map { "\($0.title), \($0.date.formatted(date: .abbreviated, time: .shortened))" }
    }

    let suggestions = ["What are my open tasks and who owns them?", "Summarize this week's meetings",
                       "What did we decide about pricing?", "What did I promise to send, and to whom?"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Ask Claude", subtitle: "Claude reads all your meeting notes, transcripts and dictations to answer") {
                if !model.chat.isEmpty { Button("New chat") { model.chat = [] } }
            }
            if let focusTitle {
                HStack {
                    Label("Focused on \(focusTitle)", systemImage: "scope").font(.callout)
                    Button { model.askFocus = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                }
                .foregroundStyle(accent).padding(.horizontal, 28).padding(.bottom, 8)
            }
            if !hasKey { setup } else { conversation }
        }
    }

    var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if model.chat.isEmpty {
                            Text("Try asking").font(.headline).padding(.top, 8)
                            ForEach(suggestions, id: \.self) { s in
                                Button { send(s) } label: {
                                    Text(s).padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                                }.buttonStyle(.plain)
                            }
                        }
                        ForEach(model.chat) { m in
                            if m.role == "user" {
                                HStack {
                                    Spacer(minLength: 120)
                                    Text(m.text).textSelection(.enabled).padding(12)
                                        .background(RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.14)))
                                }
                            } else {
                                MarkdownView(markdown: m.text).padding(.trailing, 60)
                            }
                        }
                        if busy { ProgressView().controlSize(.small).id("busy") }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .frame(maxWidth: 860, alignment: .leading)
                }
                .onChange(of: model.chat) { withAnimation { proxy.scrollTo("end") } }
            }
            Divider()
            HStack(alignment: .bottom) {
                TextField("Ask about your meetings, tasks or dictations…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...6)
                    .onSubmit { send(input) }
                Button { send(input) } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)) }
                    .buttonStyle(.plain).foregroundStyle(accent)
                    .disabled(busy || input.trimmed.isEmpty)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
            .padding(16)
        }
    }

    var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Ask in the Claude app", systemImage: "bubble.left.and.text.bubble.right").font(.headline)
                        Text("Murmur is connected to Claude as the “murmur” tool, so you can ask Claude (desktop app or Claude Code) things like “Using Murmur, what are my open tasks?” — Claude reads your notes directly. Restart Claude once after installing Murmur.")
                            .foregroundStyle(.secondary)
                        Button("Open Claude") {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
                                NSWorkspace.shared.openApplication(at: url, configuration: .init())
                            }
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Or chat right here", systemImage: "key").font(.headline)
                        Text("Paste a Claude API key (console.anthropic.com → API keys). It's stored only in Murmur's config file and also enables AI-written meeting summaries.")
                            .foregroundStyle(.secondary)
                        HStack {
                            SecureField("sk-ant-…", text: $apiKey).textFieldStyle(.roundedBorder)
                            Button("Save") {
                                let key = apiKey.trimmed
                                model.updateConfig { $0.llm.apiKey = key; $0.llm.enabled = true }
                                apiKey = ""
                            }.disabled(apiKey.trimmed.isEmpty)
                        }
                    }
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 12).frame(maxWidth: 760, alignment: .leading)
        }
    }

    func send(_ text: String) {
        let question = text.trimmed
        guard !question.isEmpty, !busy, let key = model.config.llm.resolvedKey else { return }
        input = ""
        model.chat.append(ChatMessage(role: "user", text: question))
        busy = true
        let history = model.chat.map { (role: $0.role, text: $0.text) }
        let focus = model.askFocus
        let modelName = model.config.llm.model
        Task {
            let context = await Task.detached { MurmurLibrary.context(focus: focus) }.value
            let system = """
            You are the assistant inside Murmur, the user's dictation and meeting-notes app. Answer questions using \
            the user's data below: open tasks, meeting summaries, meeting transcripts (speakers "Me" = the user, \
            "Others" = everyone else) and dictations. Transcripts come from speech recognition and contain errors. \
            Mention which meeting (title and date) facts come from; say plainly when the notes don't contain the \
            answer. Reply in the language of the question, using Markdown. Today is \
            \(Date().formatted(date: .complete, time: .shortened)).\
            \(focus.map { "\nThe user is asking about the meeting with id \"\($0)\" in particular." } ?? "")

            \(context)
            """
            do {
                let client = ClaudeClient(apiKey: key, model: modelName, timeout: 180, effort: "medium")
                let answer = try await client.chat(system: system, messages: history, maxTokens: 16_000)
                model.chat.append(ChatMessage(role: "assistant", text: answer))
            } catch {
                model.chat.append(ChatMessage(role: "assistant", text: "_Couldn't reach Claude: \(error)_"))
            }
            busy = false
        }
    }
}
