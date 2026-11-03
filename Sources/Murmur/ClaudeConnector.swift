import AppKit
import Foundation

/// Registers Murmur's MCP server (murmur-mcp, inside the app) with the Claude desktop app and Claude Code, so Claude
/// can read meetings, tasks and dictations. Each config file is backed up once before it's first changed.
enum ClaudeConnector {
    static var serverPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/murmur-mcp").path
    }

    static var configs: [(name: String, url: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [("Claude desktop app", home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")),
                ("Claude Code", home.appendingPathComponent(".claude.json"))]
    }

    /// Adds or updates `mcpServers.murmur` in each config that exists (the desktop app's is created if its folder
    /// exists). Returns the apps it connected.
    static func connect() -> (connected: [String], failed: [String]) {
        var connected: [String] = [], failed: [String] = []
        for (name, url) in configs {
            let exists = FileManager.default.fileExists(atPath: url.path)
            guard exists || FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path),
                  name != "Claude Code" || exists else { continue }
            var json: [String: Any] = [:]
            if exists {
                guard let data = try? Data(contentsOf: url),
                      let parsed = (data.isEmpty ? [:] : try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { failed.append(name); continue }
                json = parsed
                let backup = url.appendingPathExtension("murmur-backup")
                if !FileManager.default.fileExists(atPath: backup.path) { try? data.write(to: backup) }
            }
            var servers = json["mcpServers"] as? [String: Any] ?? [:]
            servers["murmur"] = ["type": "stdio", "command": serverPath, "args": [String]()]
            json["mcpServers"] = servers
            guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes]),
                  (try? out.write(to: url, options: .atomic)) != nil else { failed.append(name); continue }
            connected.append(name)
        }
        return (connected, failed)
    }

    @MainActor
    static func connectFromMenu() {
        let result = connect()
        let alert = NSAlert()
        if result.connected.isEmpty && result.failed.isEmpty {
            alert.messageText = "No Claude app found"
            alert.informativeText = "Install the Claude desktop app or Claude Code, then try again."
        } else {
            alert.messageText = result.failed.isEmpty ? "Connected to Claude" : "Partly connected"
            alert.informativeText = (result.connected.isEmpty ? "" : "Added Murmur to: \(result.connected.joined(separator: ", ")). "
                + "Restart Claude, then ask things like \"Using Murmur, what are my open tasks?\"")
                + (result.failed.isEmpty ? "" : "\nCouldn't update: \(result.failed.joined(separator: ", ")) (its config file isn't valid JSON).")
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
