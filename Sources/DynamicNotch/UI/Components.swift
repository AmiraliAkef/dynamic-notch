import AppKit
import SwiftUI

/// Claude's starburst mark, drawn as rounded rays.
struct ClaudeMark: View {
    var color: Color = .claude
    /// Spins slowly while Claude is working.
    var spinning = false

    var body: some View {
        if spinning {
            SpinningClaudeMark(color: NSColor(color))
        } else {
            Canvas { ctx, size in
                ctx.fill(Path(Self.path(in: size)), with: .color(color))
            }
        }
    }

    static func path(in size: CGSize) -> CGPath {
        let path = CGMutablePath()
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        let lengths: [CGFloat] = [1, 0.82, 0.95, 0.78, 1, 0.86, 0.92, 0.8, 0.98, 0.84, 0.9, 0.79]
        for (i, length) in lengths.enumerated() {
            let theta = (CGFloat(i) / CGFloat(lengths.count)) * 2 * .pi
            let ray = CGRect(x: -radius * 0.09, y: radius * 0.12,
                             width: radius * 0.18, height: radius * length - radius * 0.12)
            let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: theta)
            path.addPath(CGPath(roundedRect: ray, cornerWidth: radius * 0.09, cornerHeight: radius * 0.09,
                                transform: nil), transform: transform)
        }
        return path
    }
}

/// The spinning mark is a Core Animation rotation, so the render server
/// animates it without waking the app every frame.
private struct SpinningClaudeMark: NSViewRepresentable {
    var color: NSColor

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        let shape = CAShapeLayer()
        view.layer?.addSublayer(shape)
        view.onLayout = { bounds in
            shape.frame = bounds
            shape.path = ClaudeMark.path(in: bounds.size)
            if shape.animation(forKey: "spin") == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = -2 * Double.pi
                spin.duration = 4
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                shape.add(spin, forKey: "spin")
            }
        }
        return view
    }

    func updateNSView(_ view: LayerView, context: Context) {
        (view.layer?.sublayers?.first as? CAShapeLayer)?.fillColor = color.cgColor
    }
}

/// Layer-backed NSView that reports layout so sublayers can follow its bounds.
final class LayerView: NSView {
    var onLayout: ((CGRect) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        onLayout?(bounds)
        CATransaction.commit()
    }
}

/// Equalizer bars that follow the playing audio (see AudioVisualizer), with a
/// canned animation as fallback and flat bars when paused.
///
/// Drawn with Core Animation layers driven by a display link: animating it
/// through SwiftUI re-rendered the whole notch every frame (~10% CPU).
struct Waveform: NSViewRepresentable {
    var playing: Bool
    var color: Color
    var bars = 4

    func makeNSView(context: Context) -> WaveformView {
        WaveformView(bars: bars)
    }

    func updateNSView(_ view: WaveformView, context: Context) {
        view.color = NSColor(color)
        view.playing = playing
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WaveformView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

final class WaveformView: NSView {
    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2
    private let height: CGFloat = 16
    private var barLayers: [CALayer] = []
    private var link: CADisplayLink?

    var color: NSColor = .white {
        didSet { barLayers.forEach { $0.backgroundColor = color.cgColor } }
    }

    var playing = false {
        didSet {
            guard playing != oldValue else { return }
            updateLink()
            tick()
        }
    }

    init(bars: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<bars {
            let bar = CALayer()
            bar.cornerRadius = barWidth / 2
            bar.backgroundColor = color.cgColor
            layer?.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(barLayers.count) * (barWidth + spacing) - spacing, height: height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLink()
        tick()
    }

    override func layout() {
        super.layout()
        tick()
    }

    private func updateLink() {
        if playing, window != nil, link == nil {
            let link = displayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !playing || window == nil {
            link?.invalidate()
            link = nil
        }
    }

    @objc private func tick() {
        let count = barLayers.count
        let live = playing ? AudioVisualizer.shared.levels.current(count: count) : nil
        let t = CACurrentMediaTime()
        let total = intrinsicContentSize.width
        var x = (bounds.width - total) / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in barLayers.enumerated() {
            let level: Double = if let live {
                0.15 + 0.85 * Double(live[i])
            } else if playing {
                0.35 + 0.65 * abs(sin(t * (3.1 + Double(i) * 0.9) + Double(i) * 1.7))
            } else {
                0.2
            }
            let h = max(barWidth, height * level)
            bar.frame = CGRect(x: x, y: (bounds.height - h) / 2, width: barWidth, height: h)
            x += barWidth + spacing
        }
        CATransaction.commit()
    }
}

struct ProgressRing: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct AppIcon: View {
    var bundleID: String?
    var size: CGFloat

    var body: some View {
        if let icon = Self.icon(for: bundleID) {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        }
    }

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct BannerIconView: View {
    var icon: Banner.Icon
    var tint: Color
    var size: CGFloat

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.62, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        case .claude:
            ClaudeMark().frame(width: size * 0.82, height: size * 0.82).frame(width: size, height: size)
        case .app(let bundle):
            AppIcon(bundleID: bundle, size: size)
        case .image(let image):
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        }
    }
}

/// Pulsing dot for "needs attention".
struct PulseDot: View {
    var color: Color
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(on ? 1.25 : 0.8)
            .opacity(on ? 1 : 0.5)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// Three dots fading in sequence for "working" (Core Animation, no per-frame work).
struct WorkingDots: NSViewRepresentable {
    var color: Color

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        let dots = (0..<3).map { i -> CALayer in
            let dot = CALayer()
            dot.cornerRadius = 2.25
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.3
            fade.toValue = 1
            fade.duration = 0.45
            fade.autoreverses = true
            fade.repeatCount = .infinity
            fade.beginTime = CACurrentMediaTime() + Double(i) * 0.18
            fade.fillMode = .backwards
            fade.isRemovedOnCompletion = false
            dot.add(fade, forKey: "fade")
            view.layer?.addSublayer(dot)
            return dot
        }
        view.onLayout = { bounds in
            let size: CGFloat = 4.5, gap: CGFloat = 3
            var x = (bounds.width - (3 * size + 2 * gap)) / 2
            for dot in dots {
                dot.frame = CGRect(x: x, y: (bounds.height - size) / 2, width: size, height: size)
                x += size + gap
            }
        }
        return view
    }

    func updateNSView(_ view: LayerView, context: Context) {
        view.layer?.sublayers?.forEach { $0.backgroundColor = NSColor(color).cgColor }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LayerView, context: Context) -> CGSize? {
        CGSize(width: 22, height: 10)
    }
}

/// Small round icon button used in the expanded panel.
struct NotchButton: View {
    var symbol: String
    var size: CGFloat = 15
    var prominent = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size * 2.1, height: size * 2.1)
                .background(Circle().fill(.white.opacity(prominent ? 0.18 : (hovering ? 0.12 : 0))))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Capsule button with a label, e.g. "Stop" or "5 min".
struct PillButton: View {
    var title: String
    var tint: Color = .white
    var filled = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(filled ? .black : tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(filled ? tint : tint.opacity(hovering ? 0.25 : 0.15)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Side-to-side shake, driven by an incrementing counter.
struct Shake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 5 * sin(animatableData * .pi * 4), y: 0))
    }
}
