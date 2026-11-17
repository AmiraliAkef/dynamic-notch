import AppKit
import NotchShared
import ServiceManagement

/// One-click setup for the Claude Code hooks, the zsh hook and the CLI.
@MainActor
enum Installer {
    static var cliPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/notch").path
    }

    // MARK: Claude Code

    static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                               "Notification", "Stop", "SessionEnd", "PermissionRequest"]

    static var claudeHookCommand: String { "'\(cliPath)' claude-hook" }

    static var claudeHooksInstalled: Bool {
        guard let text = try? String(contentsOf: claudeSettingsURL, encoding: .utf8) else { return false }
        return text.contains(claudeHookCommand.replacingOccurrences(of: "/", with: "\\/")) || text.contains(claudeHookCommand)
    }

    /// Whether the installed hooks include `PermissionRequest` (added later,
    /// so older installs need "Reinstall Claude Code hooks").
    static var claudePermissionHookInstalled: Bool {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let groups = (settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] else { return false }
        return groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String) == claudeHookCommand }
        }
    }

    /// Adds our hook to each Claude Code event in ~/.claude/settings.json,
    /// replacing hooks from older installs and keeping everything else.
    static func installClaudeHooks() {
        let url = claudeSettingsURL
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                alert("Couldn't read \(url.path)", "It isn't valid JSON, so it was left alone.")
                return
            }
            settings = parsed
            try? data.write(to: url.appendingPathExtension("dynamicnotch-backup"))
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in claudeEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            // Drop our previous entries (the app may have moved).
            groups = groups.compactMap { group in
                var group = group
                let inner = (group["hooks"] as? [[String: Any]] ?? []).filter {
                    !(($0["command"] as? String)?.contains("notch' claude-hook") ?? false)
                }
                guard !inner.isEmpty else { return nil }
                group["hooks"] = inner
                return group
            }
            // The permission hook waits (up to ~10 min) for an answer from the iPhone;
            // Claude Code's own prompt in the terminal stays usable meanwhile.
            let timeout = event == "PermissionRequest" ? 600 : 5
            var group: [String: Any] = ["hooks": [["type": "command", "command": claudeHookCommand, "timeout": timeout]]]
            if ["PreToolUse", "PostToolUse", "PermissionRequest"].contains(event) { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
        }
        settings["hooks"] = hooks

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: settings,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
            NotchModel.shared.show(Banner(icon: .claude, tint: .claude, title: "Claude Code hooks installed",
                                          subtitle: "Start a new claude session to see it here", duration: 4))
        } catch {
            alert("Couldn't write Claude Code settings", error.localizedDescription)
        }
    }

    // MARK: Shell

    static var shellHookURL: URL { NotchPaths.supportDirectory.appendingPathComponent("notch.zsh") }
    static var zshrcURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc") }
    static let zshrcMarker = "# DynamicNotch shell integration"

    static var shellHookInstalled: Bool {
        (try? String(contentsOf: zshrcURL, encoding: .utf8))?.contains(zshrcMarker) ?? false
    }

    static func installShellHook() {
        guard let bundled = Bundle.main.url(forResource: "notch", withExtension: "zsh") else {
            alert("Shell hook missing", "notch.zsh isn't in the app bundle.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: NotchPaths.supportDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: shellHookURL)
            try FileManager.default.copyItem(at: bundled, to: shellHookURL)

            if !shellHookInstalled {
                let line = "\n\(zshrcMarker)\n[[ -r \"\(shellHookURL.path)\" ]] && source \"\(shellHookURL.path)\"\n"
                if let handle = try? FileHandle(forWritingTo: zshrcURL) {
                    handle.seekToEndOfFile()
                    handle.write(line.data(using: .utf8)!)
                    try handle.close()
                } else {
                    try line.write(to: zshrcURL, atomically: true, encoding: .utf8)
                }
            }
            NotchModel.shared.show(Banner(icon: .symbol("apple.terminal.fill"), tint: .green,
                                          title: "Shell integration installed",
                                          subtitle: "Open a new terminal window", duration: 4))
        } catch {
            alert("Couldn't install the shell hook", error.localizedDescription)
        }
    }

    // MARK: CLI

    /// Symlinks `notch` into /usr/local/bin, or ~/.local/bin if that isn't writable.
    static func installCLI() {
        let fm = FileManager.default
        let candidates = ["/usr/local/bin", fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
        for directory in candidates {
            try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
            guard fm.isWritableFile(atPath: directory) else { continue }
            let link = directory + "/notch"
            try? fm.removeItem(atPath: link)
            do {
                try fm.createSymbolicLink(atPath: link, withDestinationPath: cliPath)
                alert("Installed \(link)", directory.hasSuffix(".local/bin")
                      ? "Make sure ~/.local/bin is on your PATH." : "Try: notch timer 5m")
                return
            } catch {
                continue
            }
        }
        alert("Couldn't install the notch command", "Neither /usr/local/bin nor ~/.local/bin is writable.")
    }

    // MARK: Launch at login

    static var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    static func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            alert("Couldn't change launch at login", error.localizedDescription)
        }
    }

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }
}
