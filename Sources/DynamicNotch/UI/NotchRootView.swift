import SwiftUI

struct NotchRootView: View {
    @EnvironmentObject private var model: NotchModel

    var body: some View {
        let mode = model.mode
        let size = model.size(for: mode)
        let shape = NotchShape(topRadius: mode.topRadius, bottomRadius: mode.bottomRadius)

        VStack(spacing: 0) {
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
            .scaleEffect(model.isHovering && mode == .compact ? 1.04 : 1, anchor: .top)
            .modifier(Shake(animatableData: CGFloat(model.shakeCount)))
            .animation(.linear(duration: 0.45), value: model.shakeCount)
            .onTapGesture { tapped(mode) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(NotchAnimation.morph, value: mode)
        .animation(NotchAnimation.morph, value: model.primary?.id)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.isHovering)
    }

    @ViewBuilder
    private func content(_ mode: NotchMode) -> some View {
        switch mode {
        case .idle:
            Color.clear
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
        case .compact, .idle:
            withAnimation(NotchAnimation.open) { model.expand() }
        case .expanded:
            break
        }
    }
}
