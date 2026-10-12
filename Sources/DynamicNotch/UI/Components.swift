import AppKit
import SwiftUI

/// Claude's starburst mark, drawn as rounded rays.
struct ClaudeMark: View {
    var color: Color = .claude
    /// Spins slowly while Claude is working.
    var spinning = false

    var body: some View {
        TimelineView(.animation(paused: !spinning)) { context in
            let angle = spinning ? context.date.timeIntervalSinceReferenceDate * 90 : 0
            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2
                let lengths: [CGFloat] = [1, 0.82, 0.95, 0.78, 1, 0.86, 0.92, 0.8, 0.98, 0.84, 0.9, 0.79]
                for (i, length) in lengths.enumerated() {
                    let theta = (Double(i) / Double(lengths.count)) * 2 * .pi
                    var ray = Path(roundedRect: CGRect(x: -radius * 0.09, y: radius * 0.12,
                                                       width: radius * 0.18, height: radius * length - radius * 0.12),
                                   cornerRadius: radius * 0.09)
                    ray = ray.applying(CGAffineTransform(rotationAngle: theta))
                    ray = ray.applying(CGAffineTransform(translationX: center.x, y: center.y))
                    ctx.fill(ray, with: .color(color))
                }
            }
            .rotationEffect(.degrees(angle))
        }
    }
}

/// Animated equalizer bars; flat when paused.
struct Waveform: View {
    var playing: Bool
    var color: Color
    var bars = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let phase = Double(i) * 1.7
                    let level = playing ? 0.35 + 0.65 * abs(sin(t * (3.1 + Double(i) * 0.9) + phase)) : 0.2
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: max(3, 16 * level))
                }
            }
            .frame(height: 16)
        }
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

/// Three bouncing dots for "working".
struct WorkingDots: View {
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(color)
                        .frame(width: 4.5, height: 4.5)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.9)))
                }
            }
        }
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
