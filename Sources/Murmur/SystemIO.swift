import AppKit
import QuartzCore
import ApplicationServices

/// Watches a modifier key for push-to-talk / double-tap hands-free, plus Esc to cancel.
/// Global monitors need Accessibility permission.
final class HotkeyMonitor {
    var onDown: ((_ withControl: Bool) -> Void)?
    var onUp: (() -> Void)?
    var onEscape: (() -> Void)?

    private var monitors: [Any] = []
    private var isDown = false
    private let keyCode: UInt16
    private let flag: NSEvent.ModifierFlags

    init(hotkey: String) {
        switch hotkey {
        case "rightOption": keyCode = 61; flag = .option
        case "rightCommand": keyCode = 54; flag = .command
        case "rightControl": keyCode = 62; flag = .control
        default: keyCode = 63; flag = .function
        }
    }

    func start() {
        let flags: (NSEvent) -> Void = { [weak self] event in self?.handleFlags(event) }
        let keys: (NSEvent) -> Void = { [weak self] event in
            if event.keyCode == 53 { self?.onEscape?() }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) {
            monitors.append(m)
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func handleFlags(_ event: NSEvent) {
        guard event.keyCode == keyCode else { return }
        let down = event.modifierFlags.contains(flag)
        guard down != isDown else { return }
        isDown = down
        if down {
            onDown?(event.modifierFlags.contains(.control) && flag != .control)
        } else {
            onUp?()
        }
    }
}

/// Text-field context of the focused element, read through the Accessibility API
/// (the equivalent of Flow's Context.app + Context.textbox).
struct FocusContext {
    var appName: String?
    var bundleId: String?
    var windowTitle: String?
    var beforeText: String?
    var selectedText: String?
    var afterText: String?
    var element: AXUIElement?
    var cursorLocation: Int?
    var isElectron = false

    static func capture() -> FocusContext {
        var ctx = FocusContext()
        guard let app = NSWorkspace.shared.frontmostApplication else { return ctx }
        ctx.appName = app.localizedName
        ctx.bundleId = app.bundleIdentifier
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Electron apps (Slack, Teams, VS Code, ...) only expose their text fields once asked to.
        ctx.isElectron = isElectron(app)
        if ctx.isElectron {
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        if let window = attribute(appElement, kAXFocusedWindowAttribute) {
            ctx.windowTitle = attribute(window as! AXUIElement, kAXTitleAttribute) as? String
        }
        guard let focused = attribute(appElement, kAXFocusedUIElementAttribute) else { return ctx }
        let element = focused as! AXUIElement
        ctx.element = element
        ctx.selectedText = attribute(element, kAXSelectedTextAttribute) as? String
        if let value = attribute(element, kAXValueAttribute) as? String,
           let rangeRef = attribute(element, kAXSelectedTextRangeAttribute),
           CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) {
                let ns = value as NSString
                let start = max(0, min(range.location, ns.length))
                let end = max(start, min(range.location + range.length, ns.length))
                ctx.cursorLocation = start
                ctx.beforeText = String(ns.substring(to: start).suffix(1000))
                ctx.afterText = String(ns.substring(from: end).prefix(300))
            }
        }
        return ctx
    }

    private static var electronCache: [String: Bool] = [:]

    static func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        if let cached = electronCache[url.path] { return cached }
        let framework = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path
        let result = FileManager.default.fileExists(atPath: framework)
        electronCache[url.path] = result
        return result
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}

enum PasteOutcome {
    case verified    // the text was seen in the field
    case unverified  // pasted, but the field can't be read to confirm
    case failed      // not in the field; left on the clipboard
}

/// Inserts text with a synthetic ⌘V, checks it arrived, and restores the previous clipboard.
enum Paster {
    static func insert(_ text: String, into element: AXUIElement?, allowDirectInsert: Bool, restoreClipboard: Bool,
                       completion: @escaping (PasteOutcome) -> Void) {
        let before = element.flatMap(CorrectionWatcher.value(of:))
        waitForModifiersReleased {
            let pasteboard = NSPasteboard.general
            let saved = snapshot(pasteboard)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            postCommandV()

            func done(_ outcome: PasteOutcome) {
                // Restore late: some apps (Electron chat boxes) read the clipboard asynchronously.
                if outcome != .failed, restoreClipboard, !saved.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        guard pasteboard.string(forType: .string) == text else { return }  // user copied something new
                        pasteboard.clearContents()
                        pasteboard.writeObjects(saved.map { entry in
                            let item = NSPasteboardItem()
                            for (type, data) in entry { item.setData(data, forType: type) }
                            return item
                        })
                    }
                }
                completion(outcome)
            }

            guard let element else { return done(.unverified) }
            // Check twice: some fields update their accessibility value a little late.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let after = CorrectionWatcher.value(of: element) else { return done(.unverified) }
                if landed(text, before: before, after: after) { return done(.verified) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let later = CorrectionWatcher.value(of: element) ?? after
                    if landed(text, before: before, after: later) { return done(.verified) }
                    guard allowDirectInsert else { return done(.failed) }
                    // Native text fields accept direct insertion through Accessibility.
                    AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        let final = CorrectionWatcher.value(of: element) ?? later
                        done(landed(text, before: before, after: final) ? .verified : .failed)
                    }
                }
            }
        }
    }

    static func landed(_ text: String, before: String?, after: String) -> Bool {
        let probe = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !probe.isEmpty, after != before else { return false }
        let count = { (s: String) in s.components(separatedBy: probe).count - 1 }
        return count(after) > count(before ?? "")
    }

    /// ⌘V while fn or another modifier is still held can turn into a different shortcut; wait (up to 1.5 s).
    private static func waitForModifiersReleased(attempt: Int = 0, _ then: @escaping () -> Void) {
        let held: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        if CGEventSource.flagsState(.hidSystemState).intersection(held).isEmpty || attempt >= 30 {
            then()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { waitForModifiersReleased(attempt: attempt + 1, then) }
        }
    }

    /// A full ⌘ press around V: some apps ignore a V event that only carries the Command flag.
    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let command: CGKeyCode = 0x37, v: CGKeyCode = 0x09
        let events: [(CGKeyCode, Bool, CGEventFlags)] = [
            (command, true, .maskCommand), (v, true, .maskCommand), (v, false, .maskCommand), (command, false, []),
        ]
        for (key, down, flags) in events {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { entry[type] = data } }
            return entry
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Small floating pill near the bottom of the screen (Murmur's take on the Flow Bar).
