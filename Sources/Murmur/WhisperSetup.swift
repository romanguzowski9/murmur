import AppKit
import Foundation

/// Helps a new user set up local Whisper: whisper.cpp comes from Homebrew, the models from Murmur's menu.
/// Until then Murmur uses Apple's speech recognition, so it works from the first launch.
enum WhisperSetup {
    static let installCommand = "brew install whisper-cpp"

    @MainActor
    static func explainInstall() {
        let hasBrew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].contains { FileManager.default.isExecutableFile(atPath: $0) }
        let alert = NSAlert()
        alert.messageText = "Install whisper.cpp"
        alert.informativeText = hasBrew
            ? "Murmur runs OpenAI's Whisper locally through whisper.cpp. Paste this in Terminal, then restart Murmur:\n\n\(installCommand)"
            : "Murmur runs Whisper locally through whisper.cpp, installed with Homebrew. Install Homebrew from brew.sh "
                + "first, then run in Terminal:\n\n\(installCommand)"
        alert.addButton(withTitle: "Copy command")
        alert.addButton(withTitle: hasBrew ? "Open Terminal" : "Open brew.sh")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(installCommand, forType: .string)
        case .alertSecondButtonReturn:
            if hasBrew {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(installCommand, forType: .string)
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
            } else {
                NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
            }
        default: break
        }
    }

    /// Once, on a Mac without the Whisper models: offers to download them (and explains whisper.cpp if missing).
    @MainActor
    static func suggestOnFirstLaunch(models: [String], engine: String, download: @escaping () -> Void) {
        let key = "offeredWhisperSetup"
        let missing = ModelDownloader.missing(models)
        guard engine == "whisper", !UserDefaults.standard.bool(forKey: key),
              !missing.isEmpty || WhisperServer.program == nil else { return }
        UserDefaults.standard.set(true, forKey: key)
        let alert = NSAlert()
        alert.messageText = "Set up Whisper for better accuracy?"
        alert.informativeText = "Murmur works now with Apple's speech recognition. Local Whisper is more accurate, "
            + "especially when you switch languages. It needs whisper.cpp (Homebrew) and "
            + "\(ModelDownloader.describe(missing)) of models, downloaded once from Hugging Face. "
            + "You can do this later from the Murmur menu › Speech recognition."
        alert.addButton(withTitle: missing.isEmpty ? "Show install command" : "Download models")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !missing.isEmpty { download() }
        if WhisperServer.program == nil { explainInstall() }
    }
}
