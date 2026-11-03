import AppKit
import Foundation

/// Looks for a newer release on GitHub (the repository is written into Info.plist as `MurmurRepository` by
/// scripts/build_app.sh). Nothing is downloaded or installed: a newer version opens its release page.
enum UpdateChecker {
    struct Release {
        var version: String
        var page: URL
    }

    static var repository: String? {
        (Bundle.main.object(forInfoDictionaryKey: "MurmurRepository") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// "v0.3.0" is newer than "0.2.9".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) where (i < a.count ? a[i] : 0) != (i < b.count ? b[i] : 0) {
            return (i < a.count ? a[i] : 0) > (i < b.count ? b[i] : 0)
        }
        return false
    }

    static func latest(completion: @escaping (Release?) -> Void) {
        guard let repository, let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            return completion(nil)
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let release = (json?["tag_name"] as? String).flatMap { tag in
                (json?["html_url"] as? String).flatMap(URL.init(string:)).map { Release(version: tag, page: $0) }
            }
            DispatchQueue.main.async { completion(release) }
        }.resume()
    }

    /// From the menu: always answers.
    @MainActor
    static func checkNow() {
        latest { release in
            let alert = NSAlert()
            if let release, isNewer(release.version, than: currentVersion) {
                alert.messageText = "Murmur \(release.version) is available"
                alert.informativeText = "You have \(currentVersion). Quit Murmur, then run the install command again "
                    + "(or download the zip from the release page). Your notes and settings are kept."
                alert.addButton(withTitle: "Open release page")
                alert.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
            } else {
                alert.messageText = release == nil ? "Couldn't check for updates" : "Murmur is up to date"
                alert.informativeText = release == nil
                    ? "GitHub didn't answer\(repository == nil ? " (this build doesn't know its repository)" : "")."
                    : "You have the latest version, \(currentVersion)."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    /// At launch, at most once a day: tells the user (through `notify`) only when there is something new.
    static func checkInBackground(notify: @escaping (String) -> Void) {
        let key = "lastUpdateCheck"
        if let last = UserDefaults.standard.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        UserDefaults.standard.set(Date(), forKey: key)
        latest { release in
            guard let release, isNewer(release.version, than: currentVersion) else { return }
            notify("Murmur \(release.version) is available — menu › Check for updates")
        }
    }
}
