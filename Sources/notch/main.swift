import CryptoKit
import Foundation
import NotchShared

// `notch` — talks to the running DynamicNotch app.
// Always exits quietly and quickly: it runs inside shell and Claude Code hooks.

let usage = """
usage:
  notch timer <duration> [label]      start a timer (25m, 90s, 1h30m, 5:00)
  notch timer pause|resume|cancel     control the most recent timer
  notch stopwatch start|stop|reset
  notch notify <title> [subtitle] [--icon <sf-symbol>] [--seconds <n>]
  notch claude-hook                   read a Claude Code hook event from stdin
  notch send '<json>'                 send a raw message
  notch ping                          exit 0 if the app is running
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(1)
}
args.removeFirst()

/// Environment that tells the app which terminal/editor a hook ran in, so a
/// click on the notch can bring it to the front.
func hostInfo() -> NotchMessage {
    let env = ProcessInfo.processInfo.environment
    var info: NotchMessage = [:]
    if let bundle = env["__CFBundleIdentifier"] { info["hostBundle"] = bundle }
    if let term = env["TERM_PROGRAM"] { info["hostName"] = term }
    return info
}

/// Identifies a tool call across its PermissionRequest and PostToolUse
/// events (Claude Code doesn't pass a tool_use_id to PermissionRequest).
func toolFingerprint(_ event: [String: Any]) -> String {
    var text = event["tool_name"] as? String ?? ""
    if let input = event["tool_input"], JSONSerialization.isValidJSONObject(input),
       let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) {
        text += "\n" + String(decoding: data, as: UTF8.self)
    }
    return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
}

/// The part of a tool call worth showing on a phone: the command, file, URL…
func permissionSummary(tool: String, input: [String: Any], cwd: String) -> (detail: String, note: String?) {
    func string(_ key: String) -> String? {
        (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    func relative(_ path: String) -> String {
        guard !cwd.isEmpty, path.hasPrefix(cwd + "/") else {
            return (path as NSString).abbreviatingWithTildeInPath
        }
        return String(path.dropFirst(cwd.count + 1))
    }
    switch tool {
    case "Bash":
        return (string("command") ?? "", string("description"))
    case "Edit", "MultiEdit", "Write", "Read":
        return (relative(string("file_path") ?? ""), nil)
    case "NotebookEdit":
        return (relative(string("notebook_path") ?? ""), nil)
    case "WebFetch":
        return (string("url") ?? "", nil)
    case "WebSearch":
        return (string("query") ?? "", nil)
    case "Glob", "Grep":
        let pattern = string("pattern") ?? ""
        return (string("path").map { "\(pattern) in \(relative($0))" } ?? pattern, nil)
    case "Agent", "Task":
        return (string("description") ?? string("prompt") ?? "", string("subagent_type"))
    default:
        guard JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]) else { return ("", nil) }
        return (String(decoding: data, as: UTF8.self), nil)
    }
}

/// PermissionRequest: asks the app to show the request on the iPhone and
/// waits for the answer. Claude Code shows its usual prompt in the terminal
/// meanwhile, so answering there still works; the app then lets this go.
/// Exits without output (Claude Code's normal prompt decides) whenever
/// there's no answer.
func answerPermission(_ event: [String: Any]) -> Never {
    let tool = event["tool_name"] as? String ?? ""
    // These need a typed answer (updatedInput), which the phone can't give.
    guard !tool.isEmpty, !["AskUserQuestion", "ExitPlanMode"].contains(tool) else { exit(0) }
    let cwd = event["cwd"] as? String ?? ""
    let suggestions = event["permission_suggestions"] as? [Any] ?? []
    let (detail, note) = permissionSummary(tool: tool, input: event["tool_input"] as? [String: Any] ?? [:], cwd: cwd)

    var message = hostInfo()
    message["kind"] = "permission"
    message["reply"] = true
    message["session"] = event["session_id"] as? String ?? ""
    message["cwd"] = cwd
    message["tool"] = tool
    message["detail"] = String(detail.prefix(2000))
    if let note { message["note"] = String(note.prefix(300)) }
    message["fingerprint"] = toolFingerprint(event)
    message["canAlwaysAllow"] = !suggestions.isEmpty

    // Claude Code's hook timeout is 600 s (set by the installer).
    guard let reply = NotchClient.request(message, timeout: 585),
          let decision = reply["decision"] as? String else { exit(0) }

    var result: [String: Any]
    switch decision {
    case "allow":
        result = ["behavior": "allow"]
    case "always":
        result = ["behavior": "allow"]
        if !suggestions.isEmpty { result["updatedPermissions"] = suggestions }
    case "deny":
        result = ["behavior": "deny", "message": "The user denied this from their iPhone."]
    default:
        exit(0)
    }
    let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": result]]
    if let data = try? JSONSerialization.data(withJSONObject: output) {
        FileHandle.standardOutput.write(data)
    }
    exit(0)
}

func send(_ message: NotchMessage) -> Never {
    NotchClient.send(message)
    exit(0)
}

switch command {
case "timer":
    guard let first = args.first else { print(usage); exit(1) }
    if ["pause", "resume", "cancel", "stop"].contains(first) {
        send(["kind": "timer", "action": first == "stop" ? "cancel" : first])
    }
    guard let seconds = parseDuration(first) else {
        FileHandle.standardError.write("notch: can't read duration '\(first)'\n".data(using: .utf8)!)
        exit(1)
    }
    var message: NotchMessage = ["kind": "timer", "action": "start", "duration": seconds]
    if args.count > 1 { message["label"] = args.dropFirst().joined(separator: " ") }
    send(message)

case "stopwatch":
    send(["kind": "stopwatch", "action": args.first ?? "start"])

case "notify":
    var message: NotchMessage = ["kind": "notify"]
    var positional: [String] = []
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--icon" where i + 1 < args.count:
            message["icon"] = args[i + 1]; i += 2
        case "--seconds" where i + 1 < args.count:
            message["seconds"] = Double(args[i + 1]) ?? 4; i += 2
        default:
            positional.append(args[i]); i += 1
        }
    }
    guard let title = positional.first else { print(usage); exit(1) }
    message["title"] = title
    if positional.count > 1 { message["subtitle"] = positional[1] }
    send(message)

case "claude-hook":
    // Claude Code passes the event as JSON on stdin.
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }
    if event["hook_event_name"] as? String == "PermissionRequest" {
        answerPermission(event)
    }
    var message = hostInfo()
    message["kind"] = "claude"
    message["event"] = event["hook_event_name"] ?? "unknown"
    for (from, to) in [("session_id", "session"), ("cwd", "cwd"), ("message", "message"),
                       ("notification_type", "notificationType"), ("tool_name", "tool"), ("prompt", "prompt")] {
        if let value = event[from] as? String { message[to] = value }
    }
    if event["hook_event_name"] as? String == "PostToolUse" {
        message["fingerprint"] = toolFingerprint(event)
    }
    send(message)

case "send":
    guard let json = args.first?.data(using: .utf8),
          let message = (try? JSONSerialization.jsonObject(with: json)) as? NotchMessage else {
        FileHandle.standardError.write("notch: invalid JSON\n".data(using: .utf8)!)
        exit(1)
    }
    send(message)

case "ping":
    exit(NotchClient.send(["kind": "ping"]) ? 0 : 1)

case "-h", "--help", "help":
    print(usage)

default:
    print(usage)
    exit(1)
}
