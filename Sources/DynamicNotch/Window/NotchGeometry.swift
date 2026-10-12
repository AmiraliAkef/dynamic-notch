import AppKit

/// Where the hardware notch is on a screen (or where a fake one goes on a
/// screen without a notch).
struct NotchGeometry: Equatable {
    /// Notch size in points.
    var notchSize: CGSize
    /// Horizontal center of the notch, in global screen coordinates.
    var centerX: CGFloat
    /// Top edge of the screen, in global screen coordinates.
    var top: CGFloat
    var hasHardwareNotch: Bool

    static let fallback = NotchGeometry(notchSize: CGSize(width: 190, height: 32), centerX: 0, top: 0, hasHardwareNotch: false)

    init(notchSize: CGSize, centerX: CGFloat, top: CGFloat, hasHardwareNotch: Bool) {
        self.notchSize = notchSize
        self.centerX = centerX
        self.top = top
        self.hasHardwareNotch = hasHardwareNotch
    }

    init(screen: NSScreen) {
        let frame = screen.frame
        top = frame.maxY
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // The auxiliary areas are the menu bar strips either side of the notch.
            let width = frame.width - left.width - right.width
            notchSize = CGSize(width: width, height: screen.safeAreaInsets.top)
            centerX = frame.minX + left.width + width / 2
            hasHardwareNotch = true
        } else {
            let menuBar = max(frame.maxY - screen.visibleFrame.maxY, 24)
            notchSize = CGSize(width: 190, height: menuBar)
            centerX = frame.midX
            hasHardwareNotch = false
        }
    }

    /// The built-in display if it has a notch, else the main screen.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
