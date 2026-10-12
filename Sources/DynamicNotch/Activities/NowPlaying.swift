import AppKit
import SwiftUI

struct NowPlaying: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var duration: TimeInterval = 0
    var elapsed: TimeInterval = 0
    /// When `elapsed` was measured.
    var timestamp = Date.now
    var rate: Double = 1
    var isPlaying = false
    var bundleID: String?
    var artwork: NSImage?
    var tint: Color = .white

    var hasContent: Bool { !title.isEmpty }

    func elapsed(at date: Date) -> TimeInterval {
        guard isPlaying else { return elapsed }
        let value = elapsed + date.timeIntervalSince(timestamp) * max(rate, 0)
        return duration > 0 ? min(value, duration) : value
    }

    var appIcon: NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Reads system Now Playing info through the perl-hosted MediaRemote helper.
@MainActor
final class NowPlayingStore: ObservableObject {
    static let shared = NowPlayingStore()

    @Published private(set) var info = NowPlaying()
    @Published private(set) var isAvailable = true

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var artworkKey: String?
    private var hideTask: Task<Void, Never>?
    private var restarts = 0

    private var model: NotchModel { .shared }

    func start() {
        guard process == nil, Settings.shared.bool(Settings.Key.media) else { return }
        guard let helper = Bundle.main.url(forResource: "MediaRemoteHelper", withExtension: "dylib") else {
            NSLog("DynamicNotch: MediaRemoteHelper.dylib missing from bundle")
            isAvailable = false
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", """
            use DynaLoader;
            my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
            my $sym = DynaLoader::dl_find_symbol($lib, "nm_run") or die "nm_run missing";
            DynaLoader::dl_install_xsub("main::run", $sym);
            main::run();
            """, helper.path]
        let stdout = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil  // EOF; avoid spinning
                return
            }
            Task { @MainActor in NowPlayingStore.shared.receive(data) }
        }
        process.terminationHandler = { _ in
            Task { @MainActor in NowPlayingStore.shared.helperExited() }
        }

        do {
            try process.run()
            self.process = process
            input = stdin.fileHandleForWriting
        } catch {
            NSLog("DynamicNotch: can't launch Now Playing helper: \(error)")
            isAvailable = false
        }
    }

    func stop() {
        let process = self.process
        self.process = nil
        process?.terminate()
        info = NowPlaying()
        model.remove(.media)
    }

    private func helperExited() {
        guard process != nil else { return }  // stopped on purpose
        process = nil
        restarts += 1
        guard restarts < 5 else { isAvailable = false; return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double(restarts) * 2))
            self.start()
        }
    }

    // MARK: Commands

    func togglePlayPause() {
        info.isPlaying.toggle()  // feel instant; the helper confirms shortly after
        info.elapsed = info.elapsed(at: .now)
        info.timestamp = .now
        send("toggle")
    }

    func next() { send("next") }
    func previous() { send("previous") }

    func seek(to seconds: TimeInterval) {
        info.elapsed = seconds
        info.timestamp = .now
        send("seek \(seconds)")
    }

    private func send(_ command: String) {
        input?.write((command + "\n").data(using: .utf8)!)
    }

    // MARK: Parsing

    private func receive(_ data: Data) {
        if data.isEmpty { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] {
                apply(object)
            }
        }
    }

    private func apply(_ object: [String: Any]) {
        if let error = object["error"] as? String {
            NSLog("DynamicNotch: Now Playing helper: \(error)")
            return
        }
        restarts = 0

        var next = NowPlaying()
        next.title = object["title"] as? String ?? ""
        next.artist = object["artist"] as? String ?? ""
        next.album = object["album"] as? String ?? ""
        next.duration = object["duration"] as? Double ?? 0
        next.elapsed = object["elapsed"] as? Double ?? 0
        next.rate = object["rate"] as? Double ?? 1
        next.isPlaying = object["playing"] as? Bool ?? false
        // Browsers report a WebKit helper; the parent is the browser itself.
        next.bundleID = object["parentBundle"] as? String ?? object["bundle"] as? String
        if let timestamp = object["timestamp"] as? Double {
            next.timestamp = Date(timeIntervalSince1970: timestamp)
        }

        let key = object["artworkKey"] as? String
        if let base64 = object["artwork"] as? String, let data = Data(base64Encoded: base64),
           let image = NSImage(data: data) {
            next.artwork = image
            next.tint = image.averageColor.map(Color.init(nsColor:)) ?? .white
        } else if key != nil, key == artworkKey {
            next.artwork = info.artwork
            next.tint = info.tint
        }
        artworkKey = key

        guard next != info else { return }
        info = next
        sync()
    }

    private func sync() {
        hideTask?.cancel()
        if info.hasContent && info.isPlaying {
            model.upsert(Activity(source: .media, priority: Priority.media))
        } else if info.hasContent {
            // Paused: linger in the notch a little, like iOS.
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self.model.remove(.media)
            }
        } else {
            model.remove(.media)
        }
    }
}

extension NSImage {
    /// Average color, lightened enough to read on black.
    var averageColor: NSColor? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let color = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                            blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(s * 1.2, 0.9), brightness: max(b, 0.75), alpha: 1)
    }
}
