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
    var message = hostInfo()
    message["kind"] = "claude"
    message["event"] = event["hook_event_name"] ?? "unknown"
    for (from, to) in [("session_id", "session"), ("cwd", "cwd"), ("message", "message"),
                       ("notification_type", "notificationType"), ("tool_name", "tool"), ("prompt", "prompt")] {
        if let value = event[from] as? String { message[to] = value }
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
