import AppKit
import ApplicationServices

/// Closes the terminal tab or window a shell ran in, found by its tty.
/// Uses AppleScript (Automation permission) for Terminal and iTerm2; other
/// terminals are left alone.
enum TerminalWindowCloser {
    static func close(tty: String, hostBundle: String?) {
        guard let hostBundle, let script = script(for: hostBundle),
              !NSRunningApplication.runningApplications(withBundleIdentifier: hostBundle).isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = runAppleScript(script, argument: tty)
            // Terminal can't close a single tab from AppleScript; it selects the
            // tab instead and we press ⌘W in it.
            if result == "tab" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { pressCommandW(in: hostBundle) }
            }
        }
    }

    private static func script(for bundle: String) -> String? {
        switch bundle {
        case "com.apple.Terminal":
            return """
            on run argv
              set target to item 1 of argv
              tell application id "com.apple.Terminal"
                repeat with w in windows
                  set n to count of tabs of w
                  repeat with i from 1 to n
                    if tty of tab i of w is target then
                      if n is 1 then
                        close w
                        return "closed"
                      end if
                      set selected of tab i of w to true
                      set index of w to 1
                      activate
                      return "tab"
                    end if
                  end repeat
                end repeat
              end tell
              return "missing"
            end run
            """
        case "com.googlecode.iterm2":
            return """
            on run argv
              set target to item 1 of argv
              tell application id "com.googlecode.iterm2"
                repeat with w in windows
                  repeat with t in tabs of w
                    repeat with s in sessions of t
                      if tty of s is target then
                        close s
                        return "closed"
                      end if
                    end repeat
                  end repeat
                end repeat
              end tell
              return "missing"
            end run
            """
        default:
            return nil
        }
    }

    private static func runAppleScript(_ source: String, argument: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = source.split(separator: "\n").flatMap { ["-e", String($0)] } + [argument]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sends ⌘W to the terminal, but only if it is the frontmost app so the
    /// keystroke can't close something else. Needs Accessibility permission;
    /// asks for it the first time.
    @MainActor
    private static func pressCommandW(in bundle: String) {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let w: CGKeyCode = 13
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: w, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
