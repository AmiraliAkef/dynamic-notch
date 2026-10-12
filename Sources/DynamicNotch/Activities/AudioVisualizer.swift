import Accelerate
import AppKit
import CoreAudio
import os

/// Drives the equalizer bars from the audio that is actually playing.
///
/// Uses a Core Audio process tap (macOS 14.2+) on the Now Playing app — or on
/// all system audio if that app's audio process can't be found — and turns the
/// samples into a handful of log-spaced frequency bands. Needs the "System
/// Audio Recording" permission; without it the tap delivers silence and the
/// bars fall back to a canned animation.
@MainActor
final class AudioVisualizer {
    static let shared = AudioVisualizer()

    private var tap: StoppableTap?
    private var target: Target?
    private var stopTask: Task<Void, Never>?
    private var watchdog: Timer?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    /// Set when even a system-wide tap stays silent: permission was denied.
    private var gaveUp = false

    private enum Target: Equatable {
        case app(String)
        case system
    }

    /// Thread-safe snapshot store read by the views every frame.
    nonisolated let levels = LevelStore()

    // MARK: Lifecycle

    func update(playing: Bool, bundleID: String?) {
        guard #available(macOS 14.2, *), Settings.shared.bool(Settings.Key.liveVisualizer) else {
            stop()
            return
        }
        stopTask?.cancel()
        if !playing {
            // Pauses are often brief (seeking, skipping); keep the tap a moment.
            stopTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self.stop()
                self.gaveUp = false
            }
            return
        }
        guard !gaveUp else { return }
        let wanted = bundleID.map(Target.app) ?? .system
        if tap == nil || (target != wanted && target != .system) {
            start(wanted)
        }
    }

    func stop() {
        stopTask?.cancel()
        watchdog?.invalidate()
        watchdog = nil
        tap?.stop()
        tap = nil
        target = nil
        levels.reset()
    }

    @available(macOS 14.2, *)
    private func start(_ wanted: Target) {
        tap?.stop()
        tap = nil
        target = nil

        var resolved = wanted
        var processes: [AudioObjectID] = []
        if case .app(let bundle) = wanted {
            processes = AudioProcesses.matching(bundleID: bundle)
            if processes.isEmpty { resolved = .system }
        }

        let ownProcess = AudioProcesses.object(forPID: getpid()).map { [$0] } ?? []
        let description = resolved == .system
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess)
            : CATapDescription(stereoMixdownOfProcesses: processes)

        do {
            tap = try AudioTap(description: description, levels: levels)
            target = resolved
            listenForDeviceChanges()
            startWatchdog()
        } catch {
            NSLog("DynamicNotch: audio tap failed: \(error)")
            tap = nil
        }
    }

    /// Falls back from an app tap to a system tap when the app's process is
    /// silent (wrong helper process), and gives up when everything is silent.
    private func startWatchdog() {
        watchdog?.invalidate()
        let started = Date.now
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let visualizer = AudioVisualizer.shared
                guard #available(macOS 14.2, *), visualizer.tap != nil else { return }
                let silentFor = Date.now.timeIntervalSince(max(started, visualizer.levels.lastSoundDate))
                guard silentFor > 3, NowPlayingStore.shared.info.isPlaying else { return }
                if visualizer.target == .system {
                    NSLog("DynamicNotch: system audio tap is silent; is System Audio Recording allowed?")
                    visualizer.stop()
                    visualizer.gaveUp = true
                } else {
                    visualizer.start(.system)
                }
            }
        }
    }

    /// The tap's aggregate device is tied to the output device; rebuild it when
    /// the output changes (e.g. AirPods connect).
    private func listenForDeviceChanges() {
        guard deviceListener == nil else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in
                let visualizer = AudioVisualizer.shared
                guard #available(macOS 14.2, *), let target = visualizer.target else { return }
                visualizer.start(target)
            }
        }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }
}

// MARK: - Levels

/// Band levels published from the audio thread, delayed by the output
/// latency so the bars move when you *hear* the sound, not before.
final class LevelStore: @unchecked Sendable {
    static let bandCount = 6

    private struct Frame {
        var time: CFTimeInterval
        var bands: [Float]
    }

    private let lock = OSAllocatedUnfairLock()
    private var frames: [Frame] = []
    private var latency: CFTimeInterval = 0
    private var _lastSound = Date.distantPast

    var lastSoundDate: Date { lock.withLock { _lastSound } }

    func setLatency(_ seconds: CFTimeInterval) {
        lock.withLock { latency = min(max(seconds, 0), 0.5) }
    }

    func push(_ bands: [Float], audible: Bool) {
        let now = CACurrentMediaTime()
        lock.withLock {
            frames.append(Frame(time: now, bands: bands))
            if frames.count > 64 { frames.removeFirst(frames.count - 64) }
            if audible { _lastSound = .now }
        }
    }

    func reset() {
        lock.withLock {
            frames.removeAll()
            _lastSound = .distantPast
        }
    }

    /// Levels (0…1) resampled to `count` bars, or nil when there's no live audio.
    func current(count: Int) -> [Float]? {
        let now = CACurrentMediaTime()
        let bands: [Float]? = lock.withLock {
            guard let newest = frames.last, now - newest.time < 0.5 else { return nil }
            let target = now - latency
            return frames.last(where: { $0.time <= target })?.bands ?? frames.first?.bands
        }
        guard let bands, count > 0 else { return nil }
        return (0..<count).map { i in
            // Average the bands that fall under bar i.
            let lo = Float(i) * Float(bands.count) / Float(count)
            let hi = Float(i + 1) * Float(bands.count) / Float(count)
            var sum: Float = 0, weight: Float = 0
            for b in Int(lo)..<min(bands.count, Int(hi.rounded(.up))) {
                let w = min(hi, Float(b + 1)) - max(lo, Float(b))
                sum += bands[b] * w
                weight += w
            }
            return weight > 0 ? sum / weight : 0
        }
    }
}

// MARK: - Tap

private protocol StoppableTap: AnyObject {
    func stop()
}

@available(macOS 14.2, *)
private final class AudioTap: StoppableTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var analyzer: SpectrumAnalyzer?
    private let queue = DispatchQueue(label: "DynamicNotch.audiotap", qos: .userInteractive)

    struct Failure: Error, CustomStringConvertible {
        var step: String
        var status: OSStatus
        var description: String { "\(step) failed (\(status))" }
    }

    init(description: CATapDescription, levels: LevelStore) throws {
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw Failure(step: "create tap", status: status) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { cleanup(); throw Failure(step: "read tap format", status: status) }

        let analyzer = SpectrumAnalyzer(sampleRate: Float(format.mSampleRate),
                                    channels: Int(format.mChannelsPerFrame),
                                    interleaved: format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
                                    levels: levels)
        self.analyzer = analyzer

        let output = OutputDevice.current()
        levels.setLatency(output?.latency ?? 0)

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DynamicNotch Visualizer",
            kAudioAggregateDeviceUIDKey: "com.amirali.dynamicnotch.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        if let uid = output?.uid {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = uid
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid]]
        }
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID)
        guard status == noErr else { cleanup(); throw Failure(step: "create aggregate device", status: status) }

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, _, _, _ in
            analyzer.process(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
        }
        guard status == noErr else { cleanup(); throw Failure(step: "create IO proc", status: status) }

        status = AudioDeviceStart(deviceID, procID)
        guard status == noErr else { cleanup(); throw Failure(step: "start device", status: status) }
    }

    func stop() {
        cleanup()
    }

    private func cleanup() {
        if deviceID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { cleanup() }
}

// MARK: - Analysis

/// Windowed FFT over the most recent samples → log-spaced band levels with
/// adaptive gain, so quiet and loud tracks both fill the bars.
private final class SpectrumAnalyzer: @unchecked Sendable {
    private let fftSize = 2048
    private let hop = 1024
    private let log2n: vDSP_Length = 11
    private let setup: FFTSetup
    private let sampleRate: Float
    private let channels: Int
    private let interleaved: Bool
    private let levels: LevelStore

    private var history: [Float]
    private var newSamples = 0
    private var window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    private var bandRanges: [Range<Int>] = []
    private var peaks = [Float](repeating: -30, count: LevelStore.bandCount)
    private var smoothed = [Float](repeating: 0, count: LevelStore.bandCount)

    init(sampleRate: Float, channels: Int, interleaved: Bool, levels: LevelStore) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48000
        self.channels = max(channels, 1)
        self.interleaved = interleaved
        self.levels = levels
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        history = [Float](repeating: 0, count: fftSize)
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        power = [Float](repeating: 0, count: fftSize / 2)

        // Log-spaced bands from 50 Hz to 12 kHz.
        let binWidth = self.sampleRate / Float(fftSize)
        let low: Float = 50, high: Float = 12000
        let count = LevelStore.bandCount
        var previous = max(1, Int(low / binWidth))
        for i in 1...count {
            let edge = low * pow(high / low, Float(i) / Float(count))
            let bin = max(previous + 1, min(fftSize / 2, Int(edge / binWidth)))
            bandRanges.append(previous..<bin)
            previous = bin
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer) {
        guard let first = buffers.first, let data = first.mData else { return }
        let floats = data.assumingMemoryBound(to: Float.self)

        let frames: Int
        if interleaved {
            frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            append(frames: frames) { i in
                var sum: Float = 0
                for c in 0..<self.channels { sum += floats[i * self.channels + c] }
                return sum / Float(self.channels)
            }
        } else {
            frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let channelData = buffers.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
            append(frames: frames) { i in
                var sum: Float = 0
                for channel in channelData { sum += channel[i] }
                return sum / Float(max(channelData.count, 1))
            }
        }
    }

    private func append(frames: Int, sample: (Int) -> Float) {
        guard frames > 0 else { return }
        // Shift history left and append the new mono samples.
        let keep = max(0, fftSize - frames)
        if keep > 0 {
            history.withUnsafeMutableBufferPointer { buf in
                buf.baseAddress!.update(from: buf.baseAddress! + (fftSize - keep), count: keep)
            }
        }
        let start = max(0, frames - fftSize)
        for i in start..<frames {
            history[keep + (i - start)] = sample(i)
        }
        newSamples += frames
        if newSamples >= hop {
            newSamples = 0
            analyze()
        }
    }

    private func analyze() {
        var rms: Float = 0
        vDSP_rmsqv(history, 1, &rms, vDSP_Length(fftSize))
        let audible = rms > 0.0005

        vDSP_vmul(history, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(fftSize / 2))
            }
        }

        var bands = [Float](repeating: 0, count: bandRanges.count)
        for (i, range) in bandRanges.enumerated() {
            var mean: Float = 0
            power.withUnsafeBufferPointer { p in
                vDSP_meanv(p.baseAddress! + range.lowerBound, 1, &mean, vDSP_Length(range.count))
            }
            let db = 10 * log10(mean + 1e-12)
            // Adaptive gain: follow each band's recent peak, decaying slowly.
            peaks[i] = max(peaks[i] - 0.08, db, -40)
            var level = audible ? (db - (peaks[i] - 36)) / 36 : 0
            level = min(max(level, 0), 1)
            level = pow(level, 1.6)
            // Fast attack, slower release, like a VU meter.
            let k: Float = level > smoothed[i] ? 0.7 : 0.25
            smoothed[i] += (level - smoothed[i]) * k
            bands[i] = smoothed[i]
        }
        levels.push(bands, audible: audible)
    }
}

// MARK: - Core Audio helpers

private enum AudioProcesses {
    static func object(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// Audio process objects belonging to an app, including its helpers
    /// (e.g. com.google.Chrome.helper, or WebKit's GPU process for Safari).
    static func matching(bundleID: String) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        let prefixes = bundleID == "com.apple.Safari" ? ["com.apple.Safari", "com.apple.WebKit"] : [bundleID]
        return objects.filter { object in
            guard let bundle = string(object, kAudioProcessPropertyBundleID) else { return false }
            return prefixes.contains { bundle == $0 || bundle.hasPrefix($0 + ".") }
        }
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

private struct OutputDevice {
    var uid: String
    /// Seconds between a sample leaving an app and reaching your ears.
    var latency: CFTimeInterval

    static func current() -> OutputDevice? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device) == noErr,
              let uid = AudioProcesses.string(device, kAudioDevicePropertyDeviceUID) else { return nil }

        func uint32(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> UInt32 {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                     mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
            return value
        }
        var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 48000
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &rateSize, &rate)

        let frames = uint32(kAudioDevicePropertyLatency) + uint32(kAudioDevicePropertySafetyOffset)
            + uint32(kAudioDevicePropertyBufferFrameSize)
        return OutputDevice(uid: uid, latency: Double(frames) / max(rate, 1))
    }
}
