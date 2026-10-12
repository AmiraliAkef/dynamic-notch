import AppKit
import Combine
import SwiftUI

/// Borderless, transparent panel that floats above the menu bar.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on a button work even though the panel never becomes key.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Positions the panel over the notch, turns click-through on and off as the
/// pointer moves, and drives hover-to-expand.
@MainActor
final class NotchWindowController {
    private let model: NotchModel
    private let panel: NotchPanel
    private var monitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    private var hoverTask: Task<Void, Never>?

    init(model: NotchModel) {
        self.model = model
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Layout.windowSize))
        let host = NotchHostingView(rootView: NotchRootView().environmentObject(model))
        host.frame = NSRect(origin: .zero, size: Layout.windowSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    func start() {
        reposition()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        // Re-assert ordering after Space switches so the panel never ends up behind.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.orderFrontRegardless() }
        }

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) { monitors.append(local) }

        // The shape changes size on its own (banners, activities): re-check the pointer.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.pointerMoved() }
            .store(in: &cancellables)
    }

    /// Debug aid (`notch send '{"kind":"snapshot","path":"/tmp/x.png"}'`):
    /// renders the panel to a PNG without needing screen-recording permission.
    func snapshot(to path: String) {
        guard let view = panel.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func reposition() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let geometry = NotchGeometry(screen: screen)
        model.geometry = geometry
        let size = Layout.windowSize
        panel.setFrame(NSRect(x: geometry.centerX - size.width / 2,
                              y: geometry.top - size.height,
                              width: size.width, height: size.height),
                       display: true)
    }

    /// Screen rect the pointer must be in to count as "on the notch".
    private func hotRect() -> NSRect {
        let g = model.geometry
        var size = model.shapeSize
        size.width += 2 * model.mode.topRadius
        if model.mode == .idle {
            // Make the idle notch a slightly bigger target.
            size.width += 16
            size.height += 4
        }
        // A little slack below so the expanded panel doesn't close at the edge.
        let slack: CGFloat = model.mode == .expanded ? 8 : 0
        return NSRect(x: g.centerX - size.width / 2,
                      y: g.top - size.height - slack,
                      width: size.width,
                      height: size.height + slack)
    }

    private func pointerMoved() {
        let inside = hotRect().contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        guard inside != model.isHovering else { return }
        model.isHovering = inside
        hoverTask?.cancel()

        if inside {
            guard Settings.shared.hoverToExpand, !model.isExpanded else { return }
            let delay = Settings.shared.hoverDelay
            hoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.model.isHovering else { return }
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                withAnimation(NotchAnimation.open) { self.model.expand() }
            }
        } else if model.isExpanded {
            hoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, !Task.isCancelled, !self.model.isHovering else { return }
                withAnimation(NotchAnimation.close) { self.model.collapse() }
            }
        }
    }
}

enum NotchAnimation {
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.74)
    static let close = Animation.spring(response: 0.38, dampingFraction: 0.86)
    static let morph = Animation.spring(response: 0.45, dampingFraction: 0.78)
}
