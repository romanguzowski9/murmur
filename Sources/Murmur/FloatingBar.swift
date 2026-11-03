import AppKit
import SwiftUI

/// Where the bar sits: the middle of the left edge, the bottom centre, or the middle of the right edge.
/// Drag it and it snaps to the nearest.
enum BarAnchor: String, CaseIterable {
    case left, center, right

    var alignment: Alignment {
        switch self {
        case .left: return .leading
        case .center: return .bottom
        case .right: return .trailing
        }
    }
}

enum BarAction {
    case toggleMeeting, voiceNote, dictate, pasteLast, openMurmur, stopRecording, cancelRecording
}

struct MeetingBadge: Equatable {
    var name: String
    var started: Date
}

final class BarModel: ObservableObject {
    enum Mode: Equatable {
        case idle
        /// Dictation or a voice note in progress; `stoppable` shows a stop button (hands-free, voice notes).
        case recording(title: String, stoppable: Bool)
        case working(String)
        case message(String)
        /// "Record meeting?" for a call that just started.
        case prompt(app: String, bundle: String?)
    }

    @Published var mode: Mode = .idle
    /// The idle bar is hovered: show the quick menu.
    @Published var expanded = false
    @Published var showIdle = true
    @Published var anchor: BarAnchor
    @Published var meeting: MeetingBadge?
    @Published var dragging = false
    /// The button under the pointer, highlighted (tracked by the bar itself, so it works while Murmur is inactive).
    @Published var hoveredItem: String?
    /// Each button's frame in the hosting view, for finding the one under the pointer.
    var itemFrames: [String: CGRect] = [:]
    var lastDragEnd = Date.distantPast
    /// A click that is really the end of a drag must not trigger the button under the pointer.
    var clicksAllowed: Bool { !dragging && Date().timeIntervalSince(lastDragEnd) > 0.3 }

    /// The pill's frame in the hosting view (top-left origin), for hit-testing the mouse.
    var pillFrame: CGRect = .zero
    var onAction: ((BarAction) -> Void)?
    var onPromptAnswer: ((Bool) -> Void)?
    /// The pill changed size or place (e.g. the menu opened): re-check the pointer.
    var onFrameChange: (() -> Void)?

    init(anchor: BarAnchor) {
        self.anchor = anchor
    }
}

/// Murmur's floating bar: a small pill at one of three spots at the bottom of the screen. It shows recording and
/// status, asks "Record meeting?" when a call starts, and opens a quick menu on hover. It never takes focus from
/// the app you're typing in, and clicks pass through everywhere except the pill itself.
final class Overlay {
    let model: BarModel
    private let panel: NSPanel
    private let hosting: BarHostingView
    private static let size = NSSize(width: 620, height: 130)
    private var generation = 0
    private var monitors: [Any] = []
    private var collapse: DispatchWorkItem?
    private var promptTimeout: DispatchWorkItem?

    var showIdle: Bool {
        get { model.showIdle }
        set { model.showIdle = newValue; updateVisibility() }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "barAnchor").flatMap(BarAnchor.init(rawValue:)) ?? .center
        model = BarModel(anchor: saved)
        model.showIdle = UserDefaults.standard.object(forKey: "barShowIdle") as? Bool ?? true
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hosting = BarHostingView(rootView: BarView(model: model))
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = hosting

        model.onPromptAnswer = { [weak self] yes in self?.answerPrompt(yes) }
        model.onFrameChange = { [weak self] in self?.track() }
        place(animated: false)
        updateVisibility()

        // Hover and click-through: the panel takes the mouse only while it's over the pill.
        for mask: NSEvent.EventTypeMask in [.mouseMoved, .leftMouseDragged] {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.track() }) {
                monitors.append(m)
            }
            if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.track(); return e }) {
                monitors.append(m)
            }
        }
        // Press and move anywhere on the pill (buttons included) moves the bar. Handled before the view sees the
        // events, so the buttons' own mouse tracking can't swallow the drag.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp], handler: {
            [weak self] event in self?.handleMouse(event) ?? event
        }) {
            monitors.append(m)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.place(animated: false) }
    }

    // MARK: States

    /// A message (permissions, errors, meeting status).
    func show(_ text: String) {
        generation += 1
        model.mode = .message(text)
        updateVisibility()
    }

    /// Dictation in progress: a pulsing dot and "Murmur recording", nothing else.
    func showRecording(_ title: String = "Murmur recording", stoppable: Bool = false) {
        generation += 1
        model.expanded = false
        model.mode = .recording(title: title, stoppable: stoppable)
        updateVisibility()
    }

    /// The key was released and the text is being prepared.
    func showWorking(_ text: String = "Murmur") {
        generation += 1
        model.mode = .working(text)
        updateVisibility()
    }

    /// Asks whether to record a call. No answer within 30 seconds counts as "no".
    func showPrompt(app: String, bundle: String?, answer: @escaping (Bool) -> Void) {
        generation += 1
        pendingAnswer = answer
        model.expanded = false
        model.mode = .prompt(app: app, bundle: bundle)
        updateVisibility()
        promptTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.answerPrompt(false) }
        promptTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
    }

    private var pendingAnswer: ((Bool) -> Void)?

    private func answerPrompt(_ yes: Bool) {
        promptTimeout?.cancel()
        guard let answer = pendingAnswer else { return }
        pendingAnswer = nil
        if case .prompt = model.mode { model.mode = .idle }
        updateVisibility()
        answer(yes)
    }

    /// Back to the idle bar (or out of sight when the idle bar is turned off).
    func hide(after delay: TimeInterval = 0) {
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == shown else { return }
            if case .prompt = self.model.mode { self.answerPrompt(false) }
            self.model.mode = .idle
            self.updateVisibility()
        }
    }

    /// Moves the bar to one of its three spots.
    func move(to anchor: BarAnchor) {
        model.anchor = anchor
        UserDefaults.standard.set(anchor.rawValue, forKey: "barAnchor")
        place(animated: true)
    }

    func setMeeting(_ badge: MeetingBadge?) {
        model.meeting = badge
        updateVisibility()
    }

    private func updateVisibility() {
        let visible = model.mode != .idle || model.showIdle || model.meeting != nil
        if visible, !panel.isVisible {
            place(animated: false)
            panel.orderFrontRegardless()
        } else if !visible, panel.isVisible {
            panel.orderOut(nil)
        }
    }

    // MARK: Position

    private var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }

    private func frame(for anchor: BarAnchor) -> NSRect {
        let vf = screen.visibleFrame
        let w = Self.size.width, h = Self.size.height
        switch anchor {
        case .left: return NSRect(x: vf.minX + 2, y: vf.midY - h / 2, width: w, height: h)
        case .center: return NSRect(x: vf.midX - w / 2, y: vf.minY + 6, width: w, height: h)
        case .right: return NSRect(x: vf.maxX - 2 - w, y: vf.midY - h / 2, width: w, height: h)
        }
    }

    /// Where the snap spot is on screen.
    private func point(for anchor: BarAnchor) -> NSPoint {
        let vf = screen.visibleFrame
        switch anchor {
        case .left: return NSPoint(x: vf.minX, y: vf.midY)
        case .center: return NSPoint(x: vf.midX, y: vf.minY)
        case .right: return NSPoint(x: vf.maxX, y: vf.midY)
        }
    }

    private func place(animated: Bool) {
        let target = frame(for: model.anchor)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    /// The pill in screen coordinates.
    private var pillOnScreen: NSRect {
        let f = model.pillFrame
        return NSRect(x: panel.frame.minX + f.minX, y: panel.frame.maxY - f.maxY, width: f.width, height: f.height)
    }

    /// The pill's lower-left corner inside the panel for each spot (the panel is laid out with 6 pt padding).
    private func pillOffset(_ anchor: BarAnchor, size: CGSize) -> CGPoint {
        let w = Self.size.width, h = Self.size.height
        switch anchor {
        case .left: return CGPoint(x: 6, y: (h - size.height) / 2)
        case .center: return CGPoint(x: (w - size.width) / 2, y: 6)
        case .right: return CGPoint(x: w - 6 - size.width, y: (h - size.height) / 2)
        }
    }

    private(set) var debugDragEvents = 0
    private var pressAt: NSPoint?
    /// Where the bar was when the button went down; the drag moves it by the pointer's travel since then.
    private var pressOrigin: NSPoint?

    var debugLog = false

    private func handleMouse(_ event: NSEvent) -> NSEvent? {
        if debugLog { print("    \(event.type.rawValue) window=\(event.window === panel ? "bar" : "\(String(describing: event.window))") mouse=\(NSEvent.mouseLocation) dragging=\(model.dragging)") }
        guard event.window === panel else { return event }
        let mouse = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            pressAt = mouse
            pressOrigin = panel.frame.origin
            return event
        case .leftMouseDragged:
            if let start = pressAt, !model.dragging, hypot(mouse.x - start.x, mouse.y - start.y) > 4 { drag(true) }
            if model.dragging {
                drag(true)
                return nil
            }
            return event
        case .leftMouseUp:
            pressAt = nil
            if model.dragging { drag(false) }
            return event
        default:
            return event
        }
    }

    private func drag(_ moving: Bool) {
        debugDragEvents += 1
        let mouse = NSEvent.mouseLocation
        if moving {
            if !model.dragging {
                model.dragging = true
                model.expanded = false
            }
            // Fast drags arrive as few, merged events: move by the travel since the press, not since the last event.
            if let start = pressAt, let origin = pressOrigin {
                panel.setFrameOrigin(NSPoint(x: origin.x + mouse.x - start.x, y: origin.y + mouse.y - start.y))
            }
            return
        }
        pressOrigin = nil
        model.dragging = false
        model.lastDragEnd = Date()
        // Snap to the nearest spot, keeping the pill where it is until the slide starts.
        let pill = pillOnScreen
        let center = NSPoint(x: pill.midX, y: pill.midY)
        let anchor = BarAnchor.allCases.min { a, b in
            hypot(point(for: a).x - center.x, point(for: a).y - center.y) < hypot(point(for: b).x - center.x, point(for: b).y - center.y)
        } ?? .center
        let old = pillOffset(model.anchor, size: pill.size), new = pillOffset(anchor, size: pill.size)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + old.x - new.x, y: panel.frame.minY + old.y - new.y))
        model.anchor = anchor
        UserDefaults.standard.set(anchor.rawValue, forKey: "barAnchor")
        place(animated: true)
    }

    // MARK: Hover

    var debugPillOnScreen: NSRect { pillOnScreen }
    var debugIgnoresMouse: Bool { panel.ignoresMouseEvents }
    private(set) var debugTrackCount = 0

    private func track() {
        debugTrackCount += 1
        guard panel.isVisible else { return }
        if model.dragging { return }
        let margin: CGFloat = model.mode == .idle && !model.expanded ? -10 : -6
        let inside = pillOnScreen.insetBy(dx: margin, dy: margin).contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
        let hovered = inside ? model.itemFrames.first { $0.value.insetBy(dx: -1, dy: -1).contains(point) }?.key : nil
        if hovered != model.hoveredItem { model.hoveredItem = hovered }
        guard model.mode == .idle else {
            model.expanded = false
            return
        }
        if inside {
            collapse?.cancel()
            collapse = nil
            if !model.expanded { model.expanded = true }
        } else if model.expanded, collapse == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.model.expanded = false
                self?.collapse = nil
            }
            collapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }
}

/// Takes the first click even though the panel never becomes key (so it works without activating Murmur).
final class BarHostingView: NSHostingView<BarView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Views

struct BarView: View {
    @ObservedObject var model: BarModel
    /// Lets the highlight slide from one button to the next.
    @Namespace private var highlight

    var body: some View {
        ZStack(alignment: model.anchor.alignment) {
            Color.clear
            pill
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    model.pillFrame = $0
                    model.onFrameChange?()
                }
                .padding(6)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: model.mode)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: model.expanded)
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: model.hoveredItem)
        .environment(\.colorScheme, .dark)
    }

    func act(_ action: BarAction) {
        guard model.clicksAllowed else { return }
        model.onAction?(action)
    }

    func answer(_ yes: Bool) {
        guard model.clicksAllowed else { return }
        model.onPromptAnswer?(yes)
    }

    @ViewBuilder
    var pill: some View {
        switch model.mode {
        case .idle:
            if model.expanded { quickMenu } else if let meeting = model.meeting { meetingBadge(meeting) } else { restingBar }
        case let .recording(title, stoppable):
            capsule {
                HStack(spacing: 8) {
                    PulsingDot(color: .red)
                    Text(title).font(.system(size: 12, weight: .medium))
                    if stoppable {
                        iconButton("stop.fill", help: "Finish") { act(.stopRecording) }
                        iconButton("xmark", help: "Discard") { act(.cancelRecording) }
                    }
                }
            }
        case let .working(text):
            capsule {
                HStack(spacing: 8) {
                    Circle().fill(Color.secondary).frame(width: 7, height: 7)
                    Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        case let .message(text):
            capsule {
                Text(text).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                    .frame(width: Self.textWidth(text, max: 420))
            }
        case let .prompt(app, bundle):
            capsule {
                HStack(spacing: 10) {
                    AppIcon(bundle: bundle).frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(app).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text("Record meeting?").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Button { answer(true) } label: {
                        HStack(spacing: 5) {
                            Circle().fill(Color.red).frame(width: 7, height: 7)
                            Text("Yes").font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(model.hoveredItem == "prompt.yes" ? 0.3 : 0.16)))
                        .scaleEffect(model.hoveredItem == "prompt.yes" ? 1.05 : 1)
                    }.buttonStyle(.plain)
                    .modifier(Hoverable(id: "prompt.yes", model: model, highlight: nil, radius: 12))
                    Button { answer(false) } label: {
                        Text("No").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(model.hoveredItem == "prompt.no" ? Color.white : Color.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                    }.buttonStyle(.plain)
                    .modifier(Hoverable(id: "prompt.no", model: model, highlight: highlight, radius: 12))
                }
            }
        }
    }

    /// The resting state: a slim capsule that says "I'm here" and opens the menu on hover.
    var restingBar: some View {
        Capsule()
            .fill(Color.black.opacity(0.55))
            .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.5))
            .overlay(HStack(spacing: 3) {
                ForEach(0..<3) { _ in Circle().fill(Color.white.opacity(0.55)).frame(width: 2.5, height: 2.5) }
            })
            .frame(width: 44, height: 11)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
    }

    func meetingBadge(_ meeting: MeetingBadge) -> some View {
        capsule {
            HStack(spacing: 7) {
                PulsingDot(color: .red, size: 6)
                Text(meeting.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Self.elapsed(ctx.date.timeIntervalSince(meeting.started)))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Width that fits the text on one line, up to `max` (then it wraps to two lines).
    static func textWidth(_ text: String, max: CGFloat) -> CGFloat {
        let w = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        return min(max, ceil(w) + 2)
    }

    static func elapsed(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Hover menu: the things you do most, one click away.
    var quickMenu: some View {
        capsule(padding: 6) {
            HStack(spacing: 2) {
                if let meeting = model.meeting {
                    menuItem("stop.circle.fill", "Stop \(Self.elapsed(Date().timeIntervalSince(meeting.started)))", tint: .red) {
                        act(.toggleMeeting)
                    }
                } else {
                    menuItem("record.circle", "Meeting", tint: .red) { act(.toggleMeeting) }
                }
                menuItem("waveform", "Voice note") { act(.voiceNote) }
                menuItem("mic", "Dictate") { act(.dictate) }
                menuItem("doc.on.clipboard", "Paste last") { act(.pasteLast) }
                Rectangle().fill(Color.white.opacity(0.15)).frame(width: 0.5, height: 30).padding(.horizontal, 3)
                menuItem("square.grid.2x2", "Murmur") { act(.openMurmur) }
            }
        }
    }

    func menuItem(_ icon: String, _ title: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        let id = "menu." + icon
        let on = model.hoveredItem == id
        return Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(tint)
                    .scaleEffect(on ? 1.12 : 1)
                Text(title).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
                    .foregroundStyle(.white.opacity(on ? 1 : 0.75))
            }
            .frame(width: 62, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle())
        .modifier(Hoverable(id: id, model: model, highlight: highlight, radius: 12))
    }

    func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        let id = "icon." + icon
        return Button(action: action) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(model.hoveredItem == id ? 0.3 : 0.14)))
                .scaleEffect(model.hoveredItem == id ? 1.12 : 1)
        }
        .buttonStyle(.plain)
        .help(help)
        .modifier(Hoverable(id: id, model: model, highlight: nil, radius: 10))
    }

    func capsule<Content: View>(padding: CGFloat = 0, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, padding > 0 ? padding : 14)
            .padding(.vertical, padding > 0 ? padding : 7)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(0.45)))
            )
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            .foregroundStyle(.white)
    }
}

/// Reports a button's frame to the bar (so it knows what's under the pointer) and, when hovered, draws a soft
/// highlight behind it that slides from button to button.
struct Hoverable: ViewModifier {
    let id: String
    @ObservedObject var model: BarModel
    let highlight: Namespace.ID?
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                if let highlight, model.hoveredItem == id {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color.white.opacity(0.16))
                        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                        .matchedGeometryEffect(id: "highlight", in: highlight)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.itemFrames[id] = $0 }
            .onDisappear {
                model.itemFrames[id] = nil
                if model.hoveredItem == id { model.hoveredItem = nil }
            }
    }
}

struct BarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(configuration.isPressed ? 0.2 : 0.0001)))
    }
}

struct PulsingDot: View {
    var color: Color
    var size: CGFloat = 8

    var body: some View {
        TimelineView(.animation) { ctx in
            let phase = (cos(ctx.date.timeIntervalSinceReferenceDate * .pi / 0.9) + 1) / 2
            Circle().fill(color)
                .frame(width: size, height: size)
                .scaleEffect(0.72 + 0.28 * phase)
                .opacity(0.3 + 0.7 * phase)
        }
        .frame(width: size, height: size)
    }
}

struct AppIcon: View {
    var bundle: String?

    var body: some View {
        if let bundle, let url = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier?.lowercased() == bundle.lowercased() })?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "phone.fill").resizable().scaledToFit().padding(2)
        }
    }
}
