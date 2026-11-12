import SwiftUI

@main
struct DynamicNotchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Also runs when iOS relaunches the app in the background for a
        // Bluetooth event (state restoration).
        MacLink.shared.start()
        CaffeinateRemote.handler = { on in try await MacLink.shared.setCaffeinated(on) }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(MacLink.shared)
                .environmentObject(LiveActivityController.shared)
                .onOpenURL { url in MacLink.shared.pair(with: url) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { LiveActivityController.shared.startIfNeeded() }
        }
    }
}
