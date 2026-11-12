import ActivityKit
import AppIntents

/// The ☕ button on the Lock Screen and in the Dynamic Island. Live Activity
/// intents run in the app's process (iOS launches it in the background if
/// needed), where the Bluetooth link lives; the widget extension only draws
/// the button.
struct SetCaffeinatedIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Set Caffeinated Mode"
    static let description = IntentDescription("Keeps your Mac awake with the lid closed, or lets it sleep again.")

    @Parameter(title: "On")
    var on: Bool

    init() {}

    init(on: Bool) {
        self.on = on
    }

    func perform() async throws -> some IntentResult {
        try await CaffeinateRemote.set(on)
        return .result()
    }
}

/// Bridges the intent to the app's MacLink; the widget extension never sets it.
enum CaffeinateRemote {
    @MainActor static var handler: ((Bool) async throws -> Void)?

    @MainActor static func set(_ on: Bool) async throws {
        try await handler?(on)
    }
}
