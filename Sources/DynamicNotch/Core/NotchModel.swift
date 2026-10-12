import AppKit
import SwiftUI

enum NotchMode: Equatable {
    case idle, compact, split, banner, expanded
}

/// Central state: which activities exist, which banner is up, and whether the
/// notch is expanded. Sources call `upsert`/`remove`/`show(banner:)`.
@MainActor
final class NotchModel: ObservableObject {
    static let shared = NotchModel()

    @Published private(set) var activities: [Activity] = []
    @Published private(set) var banner: Banner?
    @Published var isExpanded = false
    @Published var isHovering = false
    @Published var selectedTab: NotchTab = .media
    @Published var geometry = NotchGeometry.fallback
    /// Bumped to make the notch do a little shake (timer ringing, Claude asking).
    @Published var shakeCount = 0

    private var bannerQueue: [Banner] = []
    private var bannerTask: Task<Void, Never>?

    var primary: Activity? { activities.first }
    /// The second activity, shown in its own bubble on the right in split mode.
    var secondary: Activity? { activities.count > 1 ? activities[1] : nil }

    var mode: NotchMode {
        if isExpanded { return .expanded }
        if banner != nil { return .banner }
        if secondary != nil, Settings.shared.bool(Settings.Key.splitActivities) { return .split }
        if primary != nil { return .compact }
        return .idle
    }

    // MARK: Activities

    func upsert(_ activity: Activity) {
        if let index = activities.firstIndex(where: { $0.id == activity.id }) {
            guard activities[index] != activity else { return }
            activities[index] = activity
        } else {
            activities.append(activity)
        }
        activities.sort { $0.priority > $1.priority }
    }

    func remove(_ source: Activity.Source) {
        activities.removeAll { $0.source == source }
    }

    func removeAll(where predicate: (Activity.Source) -> Bool) {
        activities.removeAll { predicate($0.source) }
    }

    // MARK: Banners

    func show(_ banner: Banner) {
        guard Settings.shared.bannersEnabled else { return }
        if self.banner == nil {
            present(banner)
        } else {
            bannerQueue.append(banner)
        }
    }

    func dismissBanner() {
        bannerTask?.cancel()
        banner = nil
        if !bannerQueue.isEmpty {
            let next = bannerQueue.removeFirst()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                self.present(next)
            }
        }
    }

    /// Removes a banner (shown or queued) by its action id — e.g. when a
    /// ringing timer is stopped from somewhere else.
    func dismissBanners(actionID: String) {
        bannerQueue.removeAll { $0.action?.id == actionID }
        if banner?.action?.id == actionID { dismissBanner() }
    }

    private func present(_ banner: Banner) {
        self.banner = banner
        if banner.shakes { shakeCount += 1 }
        bannerTask?.cancel()
        bannerTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(banner.duration))
            guard !Task.isCancelled else { return }
            // Hold the banner while the user is looking at it.
            while self.isHovering, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled else { return }
            self.dismissBanner()
        }
    }

    // MARK: Expansion

    func expand(tab: NotchTab? = nil) {
        if let tab {
            selectedTab = tab
        } else if let primary {
            selectedTab = primary.tab
        } else if let bannerTab = banner?.tab {
            selectedTab = bannerTab
        }
        isExpanded = true
    }

    func collapse() {
        isExpanded = false
    }

    // MARK: Sizes

    /// Horizontal offset of the main shape from the notch center. In split mode
    /// it grows to the left only.
    func mainOffset(for mode: NotchMode) -> CGFloat {
        mode == .split ? -Layout.minimalWidth / 2 : 0
    }

    /// Center of the split-mode bubble, relative to the notch center.
    var bubbleOffset: CGFloat {
        let ears = NotchMode.split.topRadius
        return geometry.notchSize.width / 2 + ears + Layout.bubbleGap + (Layout.minimalWidth + 2 * ears) / 2
    }

    /// The span the pointer counts as "on the notch", relative to the notch center.
    func hotSpan(for mode: NotchMode) -> ClosedRange<CGFloat> {
        let ears = mode.topRadius
        if mode == .split {
            let half = geometry.notchSize.width / 2
            return (-half - Layout.minimalWidth - ears)...(bubbleOffset + Layout.minimalWidth / 2 + ears)
        }
        let half = size(for: mode).width / 2 + ears
        return -half...half
    }

    /// Size of the black shape for the current mode, in points.
    var shapeSize: CGSize { size(for: mode) }

    func size(for mode: NotchMode) -> CGSize {
        let notch = geometry.notchSize
        switch mode {
        case .idle:
            return notch
        case .compact:
            return CGSize(width: notch.width + 2 * Layout.compactSide, height: notch.height)
        case .split:
            // Only the left wing; the right side is the separate bubble.
            return CGSize(width: notch.width + Layout.minimalWidth, height: notch.height)
        case .banner:
            return CGSize(width: max(notch.width + 2 * Layout.compactSide, Layout.bannerWidth),
                          height: notch.height + Layout.bannerExtra)
        case .expanded:
            return CGSize(width: max(notch.width + 2 * Layout.compactSide, Layout.expandedWidth),
                          height: notch.height + Layout.expandedExtra)
        }
    }
}

enum Layout {
    static let compactSide: CGFloat = 52
    /// Width of one activity in split mode (left wing or right bubble).
    static let minimalWidth: CGFloat = 76
    static let bubbleGap: CGFloat = 8
    static let bannerWidth: CGFloat = 400
    static let bannerExtra: CGFloat = 50
    static let expandedWidth: CGFloat = 540
    static let expandedExtra: CGFloat = 152
    /// The window is a fixed transparent box; the shape animates inside it.
    static let windowSize = CGSize(width: 760, height: 320)
}
