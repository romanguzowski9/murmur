import AppKit
import ApplicationServices
import MurmurCore

/// Watches the call app while a meeting is recorded, through Accessibility (Murmur is trusted for pasting): who
/// takes part and who the app marks as speaking, every 1.5 s. Read-only; nothing in the call app is touched.
final class CallObserver {
    let bundle: String
    private let pid: pid_t
    private let started: Date
    private let oneToOne: Bool
    private let queue = DispatchQueue(label: "murmur.call-observer", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var seen: [String] = []
    private var heard: [SpeakingObservation] = []

    var participants: [String] { lock.withLock { seen } }
    var observations: [SpeakingObservation] { lock.withLock { heard } }

    static let oneToOneApps: Set<String> = ["net.whatsapp.WhatsApp", "com.apple.FaceTime", "com.apple.mobilephone",
                                             "org.whispersystems.signal-desktop", "ru.keepcoder.Telegram",
                                             "com.facebook.archon", "com.viber.osx"]

    init?(bundle: String, started: Date) {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return nil }
        self.bundle = bundle
        pid = app.processIdentifier
        self.started = started
        oneToOne = Self.oneToOneApps.contains(bundle)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1.5)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        let time = Date().timeIntervalSince(started)
        let (elements, titles) = Self.scan(pid: pid)
        let reading = CallRoster.read(elements, windowTitles: titles, oneToOne: oneToOne)
        lock.withLock {
            for p in reading.participants where !seen.contains(where: { SpeakerNames.isSame($0, p) }) { seen.append(p) }
            if !reading.speaking.isEmpty { heard.append(SpeakingObservation(time: time, names: reading.speaking)) }
        }
    }

    /// The text of the app's windows (up to 6000 elements), and the titles of its small windows (call windows).
    static func scan(pid: pid_t, limit: Int = 6000) -> ([CallRoster.Element], [String]) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
            var v: AnyObject?
            return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
        }
        var elements: [CallRoster.Element] = []
        var titles: [String] = []
        var visited = 0
        func walk(_ e: AXUIElement, depth: Int) {
            visited += 1
            guard visited < limit, depth < 60 else { return }
            let texts = ["AXTitle", "AXDescription", "AXValue", "AXHelp"].compactMap { attr(e, $0) as? String }
                .map(\.trimmed).filter { !$0.isEmpty && $0.count <= 200 }
            let dom = attr(e, "AXDOMIdentifier") as? String
            if !texts.isEmpty || dom != nil {
                elements.append(CallRoster.Element(role: attr(e, "AXRole") as? String ?? "", texts: texts, domID: dom))
            }
            for child in attr(e, "AXChildren") as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
        }
        for window in attr(app, "AXWindows") as? [AXUIElement] ?? [] {
            var size = CGSize.zero
            if let v = attr(window, "AXSize") { AXValueGetValue(v as! AXValue, .cgSize, &size) }
            let first = elements.count
            walk(window, depth: 0)
            // A small window is a call window: its title and its short texts may be the other person's name.
            guard size.width < 700, size.height < 900 else { continue }
            if let title = attr(window, "AXTitle") as? String { titles.append(title) }
            titles += elements[first...].filter { $0.role == "AXStaticText" || $0.role == "AXHeading" }
                .flatMap(\.texts).filter { $0.count <= 40 }
        }
        return (elements, titles)
    }
}
