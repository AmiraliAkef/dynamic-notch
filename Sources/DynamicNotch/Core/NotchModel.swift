import AppKit
import SwiftUI

enum NotchMode: Equatable {
    case idle, compact, banner, expanded
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

    var mode: NotchMode {
        if isExpanded { return .expanded }
        if banner != nil { return .banner }
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

    /// Size of the black shape for the current mode, in points.
    var shapeSize: CGSize { size(for: mode) }

    func size(for mode: NotchMode) -> CGSize {
        let notch = geometry.notchSize
        switch mode {
        case .idle:
            return notch
        case .compact:
            return CGSize(width: notch.width + 2 * Layout.compactSide, height: notch.height)
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
    static let bannerWidth: CGFloat = 400
    static let bannerExtra: CGFloat = 50
    static let expandedWidth: CGFloat = 540
    static let expandedExtra: CGFloat = 152
    /// The window is a fixed transparent box; the shape animates inside it.
    static let windowSize = CGSize(width: 760, height: 320)
}
