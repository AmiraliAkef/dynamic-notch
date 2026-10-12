import AppKit
import SQLite3
import SwiftUI

/// A timer running in the Clock app.
struct ClockTimer: Identifiable, Equatable {
    let id: String
    var title: String?
    var duration: TimeInterval
    var endDate: Date?
    var pausedRemaining: TimeInterval?

    var isPaused: Bool { pausedRemaining != nil }

    func remaining(at date: Date = .now) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        return max(0, endDate?.timeIntervalSince(date) ?? 0)
    }

    func progress(at date: Date = .now) -> Double {
        duration > 0 ? 1 - remaining(at: date) / duration : 0
    }
}

/// Mirrors Clock.app timers into the notch.
///
/// There is no API for this: the timer service (mobiletimerd) only talks to
/// Apple-entitled clients. Clock stores timers in a Core Data database in its
/// group container, which we read (read-only) once a second.
@MainActor
final class ClockTimerWatcher: ObservableObject {
    static let shared = ClockTimerWatcher()

    @Published private(set) var timers: [ClockTimer] = []
    @Published private(set) var status: String?
    /// macOS blocks other apps' containers unless we have Full Disk Access.
    @Published private(set) var needsAccess = false

    private var poller: Timer?
    private let reader = ClockDatabaseReader()

    private var model: NotchModel { .shared }

    func start() {
        guard poller == nil, Settings.shared.bool(Settings.Key.clockTimers) else { return }
        poll()
        poller = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { ClockTimerWatcher.shared.poll() }
        }
    }

    func stop() {
        poller?.invalidate()
        poller = nil
        timers = []
        sync()
    }

    private func poll() {
        let reader = self.reader
        Task.detached(priority: .utility) {
            let result = reader.read()
            await MainActor.run {
                let watcher = ClockTimerWatcher.shared
                switch result {
                case .success(let timers):
                    watcher.status = nil
                    watcher.needsAccess = false
                    if timers != watcher.timers {
                        watcher.timers = timers
                        watcher.sync()
                    }
                case .failure(let error):
                    if watcher.status != error.message { NSLog("DynamicNotch: Clock timers: \(error.message)") }
                    watcher.status = error.message
                    watcher.needsAccess = error.permissionDenied
                }
            }
        }
    }

    static func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    private func sync() {
        let ids = Set(timers.map(\.id))
        model.removeAll { source in
            guard case .clockTimer(let id) = source else { return false }
            return !ids.contains(id)
        }
        for timer in timers {
            model.upsert(Activity(source: .clockTimer(timer.id), priority: Priority.timer))
        }
    }
}

struct ClockReadError: Error {
    var message: String
    var permissionDenied = false
}

/// Reads ZMTCDTIMER rows from mobiletimerd's Core Data store.
final class ClockDatabaseReader: @unchecked Sendable {
    static let path = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.mobiletimerd/local.sqlite"

    /// MTTimerState values: 1 stopped, 2 paused, 3 running, 4 firing.
    enum State: Int {
        case stopped = 1, paused = 2, running = 3, firing = 4
    }

    /// Debug: which step of reading Clock's files fails, with errno.
    static func probe() -> [String: String] {
        var out: [String: String] = [:]
        let dir = (path as NSString).deletingLastPathComponent
        for (label, target) in [("dir", dir), ("db", path), ("wal", path + "-wal"), ("shm", path + "-shm")] {
            errno = 0
            let fd = open(target, O_RDONLY)
            out[label] = fd >= 0 ? "ok" : "errno \(errno) \(String(cString: strerror(errno)))"
            if fd >= 0 { close(fd) }
        }
        return out
    }

    func read() -> Result<[ClockTimer], ClockReadError> {
        guard FileManager.default.fileExists(atPath: Self.path) else {
            return .failure(ClockReadError(message: "Clock timer database not found"))
        }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let uri = "file:" + Self.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "?mode=ro"
        let opened = sqlite3_open_v2(uri, &db, flags, nil)
        guard opened == SQLITE_OK else {
            let denied = opened == SQLITE_AUTH || errno == EPERM || errno == EACCES
            sqlite3_close(db)
            return .failure(ClockReadError(message: denied ? "needs Full Disk Access" : "can't open database (\(opened))",
                                           permissionDenied: denied))
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)

        let sql = "SELECT Z_PK, ZSTATE, ZDURATION, ZLASTMODIFIEDDATE, ZTITLE, ZFIRETIME, ZMTID FROM ZMTCDTIMER WHERE ZSTATE IN (2, 3, 4)"
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else {
            let denied = prepared == SQLITE_AUTH || prepared == SQLITE_CANTOPEN || errno == EPERM
            return .failure(ClockReadError(message: denied ? "needs Full Disk Access" : String(cString: sqlite3_errmsg(db)),
                                           permissionDenied: denied))
        }
        defer { sqlite3_finalize(statement) }

        var timers: [ClockTimer] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let pk = sqlite3_column_int64(statement, 0)
            let state = State(rawValue: Int(sqlite3_column_int(statement, 1)))
            let duration = sqlite3_column_double(statement, 2)
            let modified = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3))
            var title = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            if title == "CURRENT_TIMER" || title?.isEmpty == true { title = nil }
            let fireTime = Self.blob(statement, 5).flatMap(ArchiveFields.init)
            let id = Self.blob(statement, 6).map { $0.map { String(format: "%02x", $0) }.joined() } ?? "pk\(pk)"

            var timer = ClockTimer(id: id, title: title, duration: duration)
            switch state {
            case .paused:
                timer.pausedRemaining = fireTime?.interval ?? duration
            case .running, .firing:
                if let date = fireTime?.date {
                    timer.endDate = date
                } else if let modified {
                    timer.endDate = modified + (fireTime?.interval ?? duration)
                }
            default:
                continue
            }
            // A finished timer that Clock hasn't cleaned up yet.
            if state == .running, let end = timer.endDate, end < .now - 2 { continue }
            timers.append(timer)
        }
        return .success(timers)
    }

    private static func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}

/// Pulls the interesting values out of an NSKeyedArchiver plist without
/// needing the private MobileTimer classes.
struct ArchiveFields {
    var className: String?
    var interval: TimeInterval?
    var date: Date?

    init?(_ data: Data) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any],
              let top = plist["$top"] as? [String: Any],
              let rootIndex = Self.uid(top["root"]),
              rootIndex < objects.count,
              let root = objects[rootIndex] as? [String: Any] else { return nil }

        if let classIndex = Self.uid(root["$class"]), let cls = objects[classIndex] as? [String: Any] {
            className = cls["$classname"] as? String
        }
        for (key, value) in root where key != "$class" {
            var resolved: Any? = value
            if let index = Self.uid(value), index < objects.count { resolved = objects[index] }
            if let number = resolved as? Double, key.lowercased().contains("interval") {
                interval = number
            } else if let dict = resolved as? [String: Any], let time = dict["NS.time"] as? Double {
                date = Date(timeIntervalSinceReferenceDate: time)
            } else if let value = resolved as? Date {
                date = value
            }
        }
    }

    /// CFKeyedArchiverUID has no public Swift type; read its integer value.
    private static func uid(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let int = value as? Int { return int }
        let description = String(describing: value)
        guard let range = description.range(of: "value = ") else { return nil }
        return Int(description[range.upperBound...].prefix { $0.isNumber })
    }
}
