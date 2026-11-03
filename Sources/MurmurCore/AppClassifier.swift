import Foundation

/// Maps the frontmost app (and, for browsers, its window title) to a style category,
/// following Wispr's AppType split: personal messaging / work messaging / email / chatbot / developer / other.
public enum AppClassifier {
    static let bundleCategories: [String: AppCategory] = [
        // Personal messaging
        "com.apple.MobileSMS": .personal,
        "net.whatsapp.WhatsApp": .personal,
        "WhatsApp": .personal,
        "ru.keepcoder.Telegram": .personal,
        "org.telegram.desktop": .personal,
        "com.facebook.archon": .personal,
        "com.hnc.Discord": .personal,
        "org.whispersystems.signal-desktop": .personal,
        // Work messaging
        "com.tinyspeck.slackmacgap": .work,
        "com.microsoft.teams": .work,
        "com.microsoft.teams2": .work,
        "us.zoom.xos": .work,
        "com.linear": .work,
        "notion.id": .work,
        "com.clickup.desktop-app": .work,
        // Email
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.readdle.smartemail-Mac": .email,
        "com.superhuman.electron": .email,
        "com.google.Gmail": .email,
        "it.bloop.airmail2": .email,
        // AI chat
        "com.openai.chat": .ai,
        "com.anthropic.claudefordesktop": .ai,
        "ai.perplexity.mac": .ai,
        // Developer
        "com.todesktop.230313mzl4w4u92": .developer, // Cursor
        "com.exafunction.windsurf": .developer,
        "com.microsoft.VSCode": .developer,
        "com.apple.dt.Xcode": .developer,
        "com.apple.Terminal": .developer,
        "com.googlecode.iterm2": .developer,
        "dev.warp.Warp-Stable": .developer,
        "com.mitchellh.ghostty": .developer,
    ]

    static let browserBundles: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "company.thebrowser.dia",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi", "com.openai.atlas",
    ]

    /// Window-title keywords for web apps opened in a browser.
    static let titleKeywords: [(String, AppCategory)] = [
        ("gmail", .email), ("outlook", .email), ("inbox", .email), ("superhuman", .email), ("poczta", .email),
        ("slack", .work), ("microsoft teams", .work), ("linear", .work), ("notion", .work), ("jira", .work),
        ("whatsapp", .personal), ("messenger", .personal), ("telegram", .personal), ("discord", .personal),
        ("chatgpt", .ai), ("claude", .ai), ("gemini", .ai), ("perplexity", .ai),
        ("github", .developer), ("replit", .developer),
    ]

    public static func classify(bundleId: String?, windowTitle: String?) -> AppCategory {
        if let id = bundleId, let category = bundleCategories[id] { return category }
        if let id = bundleId, browserBundles.contains(id) || id.hasPrefix("com.google.Chrome.app") {
            let title = (windowTitle ?? "").lowercased()
            for (keyword, category) in titleKeywords where title.contains(keyword) {
                return category
            }
        }
        return .other
    }
}
