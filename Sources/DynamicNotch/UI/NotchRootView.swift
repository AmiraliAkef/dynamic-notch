import SwiftUI

struct NotchRootView: View {
    @EnvironmentObject private var model: NotchModel

    var body: some View {
        let mode = model.mode
        let size = model.size(for: mode)
        let shape = NotchShape(topRadius: mode.topRadius, bottomRadius: mode.bottomRadius)
        let hoverScale = model.isHovering && (mode == .compact || mode == .split) ? 1.04 : 1

        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                shape.fill(.black)
                content(mode)
                    .padding(.horizontal, mode.topRadius)
                    .frame(width: size.width + 2 * mode.topRadius, height: size.height, alignment: .top)
            }
            .frame(width: size.width + 2 * mode.topRadius, height: size.height)
            .clipShape(shape)
            .contentShape(shape)
            .shadow(color: .black.opacity(mode == .expanded || mode == .banner ? 0.45 : 0),
                    radius: mode == .expanded ? 18 : 10, y: 6)
            .scaleEffect(hoverScale, anchor: .top)
            .modifier(Shake(animatableData: CGFloat(model.shakeCount)))
            .onTapGesture { tapped(mode) }
            .offset(x: model.mainOffset(for: mode))

            // Split mode: the second activity gets its own bubble, like the
            // detached circle on iPhone. It emerges from the notch's right edge.
            if mode == .split, let secondary = model.secondary {
                SplitBubble(activity: secondary)
                    .scaleEffect(hoverScale, anchor: .top)
                    .offset(x: model.bubbleOffset)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.2, anchor: .leading)
                            .combined(with: .offset(x: -Layout.minimalWidth / 2))
                            .combined(with: .opacity),
                        removal: .scale(scale: 0.2, anchor: .leading)
                            .combined(with: .offset(x: -Layout.minimalWidth))
                            .combined(with: .opacity)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.linear(duration: 0.45), value: model.shakeCount)
        .animation(NotchAnimation.morph, value: mode)
        .animation(NotchAnimation.morph, value: model.primary?.id)
        .animation(NotchAnimation.morph, value: model.secondary?.id)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.isHovering)
    }

    @ViewBuilder
    private func content(_ mode: NotchMode) -> some View {
        switch mode {
        case .idle:
            Color.clear
        case .split:
            if let primary = model.primary {
                // Left wing only; the camera sits to its right.
                HStack(spacing: 0) {
                    CompactView(activity: primary, notchWidth: nil)
                        .frame(width: Layout.minimalWidth)
                        .id(primary.id)
                        .transition(.blurReplace)
                    Color.clear.frame(width: model.geometry.notchSize.width)
                }
                .frame(height: model.geometry.notchSize.height)
            }
        case .compact:
            if let primary = model.primary {
                CompactView(activity: primary, notchWidth: model.geometry.notchSize.width)
                    .frame(height: model.geometry.notchSize.height)
                    .id(primary.id)
                    .transition(.blurReplace)
            }
        case .banner:
            if let banner = model.banner {
                BannerView(banner: banner, notchHeight: model.geometry.notchSize.height)
                    .id(banner.id)
                    .transition(.blurReplace.combined(with: .scale(0.9, anchor: .top)))
            }
        case .expanded:
            ExpandedView()
                .transition(.blurReplace.combined(with: .scale(0.92, anchor: .top)))
        }
    }

    private func tapped(_ mode: NotchMode) {
        switch mode {
        case .banner:
            guard let banner = model.banner else { return }
            model.dismissBanner()
            if let bundle = banner.openBundle {
                activateApp(bundleID: bundle)
            } else {
                withAnimation(NotchAnimation.open) { model.expand(tab: banner.tab) }
            }
        case .compact, .split, .idle:
            withAnimation(NotchAnimation.open) { model.expand() }
        case .expanded:
            break
        }
    }
}

/// The detached right-hand bubble in split mode: a small notch-shaped tab.
private struct SplitBubble: View {
    @EnvironmentObject private var model: NotchModel
    var activity: Activity

    var body: some View {
        let shape = NotchShape(topRadius: NotchMode.split.topRadius, bottomRadius: NotchMode.split.bottomRadius)
        ZStack {
            shape.fill(.black)
            CompactView(activity: activity, notchWidth: nil)
                .id(activity.id)
                .transition(.blurReplace)
        }
        .frame(width: Layout.minimalWidth + 2 * NotchMode.split.topRadius,
               height: model.geometry.notchSize.height)
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture {
            withAnimation(NotchAnimation.open) { model.expand(tab: activity.tab) }
        }
    }
}
