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

/// Allow / Deny on a Claude Code permission request, from the Lock Screen or
/// the Dynamic Island. Runs in the app's process, like the ☕ button.
struct AnswerPermissionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer Permission Request"
    static let description = IntentDescription("Allows or denies what Claude Code asked to do on your Mac.")

    @Parameter(title: "Request")
    var request: Int

    @Parameter(title: "Allow")
    var allow: Bool

    init() {}

    init(request: UInt32, allow: Bool) {
        self.request = Int(request)
        self.allow = allow
    }

    func perform() async throws -> some IntentResult {
        try await PermissionRemote.answer(UInt32(request), allow ? .allow : .deny)
        return .result()
    }
}

/// Bridges the permission intent to the app's MacLink.
enum PermissionRemote {
    @MainActor static var handler: ((UInt32, PermissionDecision) async throws -> Void)?

    @MainActor static func answer(_ id: UInt32, _ decision: PermissionDecision) async throws {
        try await handler?(id, decision)
    }
}

/// Bridges the intent to the app's MacLink; the widget extension never sets it.
enum CaffeinateRemote {
    @MainActor static var handler: ((Bool) async throws -> Void)?

    @MainActor static func set(_ on: Bool) async throws {
        try await handler?(on)
    }
}
