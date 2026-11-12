import SwiftUI

/// Stable accessibility identifiers for the ACP Adapter Manager and the agent conversation.
///
/// Identifiers are independent of the visible labels. Labels, hints, and values stay on the
/// controls themselves. UI tests look these up; VoiceOver users hear the labels.
enum IDEACPAccessibility {
    static let settingsSearch = "settings.search"
    static let settingsSidebar = "settings.sidebar"
    static let settingsDetail = "settings.detail"
    static let settingsOpen = "settings.open"
    static let agentToggle = "agent.toggle"
    static func settingsDomain(_ id: String) -> String { "settings.domain.\(id)" }

    static let adapters = "acp.adapters"
    static let adaptersLoading = "acp.adapters.loading"
    static let adaptersOffline = "acp.adapters.offline"
    static let adaptersNode = "acp.adapters.node"
    static let adaptersSandbox = "acp.adapters.sandbox"
    static let updatePolicy = "acp.adapters.updatePolicy"
    static let checkUpdates = "acp.adapters.checkUpdates"

    static func adapter(_ id: String) -> String { "acp.adapter.\(id)" }
    static func install(_ id: String) -> String { "acp.adapter.\(id).install" }
    static func update(_ id: String) -> String { "acp.adapter.\(id).update" }
    static func cancel(_ id: String) -> String { "acp.adapter.\(id).cancel" }
    static func retry(_ id: String) -> String { "acp.adapter.\(id).retry" }
    static func test(_ id: String) -> String { "acp.adapter.\(id).test" }
    static func more(_ id: String) -> String { "acp.adapter.\(id).more" }
    static func status(_ id: String) -> String { "acp.adapter.\(id).status" }
    static func progress(_ id: String) -> String { "acp.adapter.\(id).progress" }
    static func message(_ id: String) -> String { "acp.adapter.\(id).message" }
    static func connection(_ id: String) -> String { "acp.adapter.\(id).connection" }
    static func versions(_ id: String) -> String { "acp.adapter.\(id).versions" }
    static func restore(_ id: String) -> String { "acp.adapter.\(id).restore" }
    static func remove(_ id: String) -> String { "acp.adapter.\(id).remove" }
    static func details(_ id: String) -> String { "acp.adapter.\(id).details" }
    static func activateVersion(_ id: String, _ version: String) -> String { "acp.adapter.\(id).version.\(version).activate" }
    static func removeVersion(_ id: String, _ version: String) -> String { "acp.adapter.\(id).version.\(version).remove" }

    static let approval = "acp.approval"
    static let approvalConfirm = "acp.approval.confirm"
    static let approvalCancel = "acp.approval.cancel"
    static let approvalPackage = "acp.approval.package"

    static let provider = "acp.provider"
    static let composer = "agent.composer"
    static let send = "agent.send"
    static let stop = "agent.stop"
    static func tool(_ id: String) -> String { "agent.tool.\(id)" }
    static let approvalAllow = "agent.approval.allow"
    static let approvalDeny = "agent.approval.deny"
    static let changes = "agent.changes"
    static func change(_ path: String) -> String { "agent.change.\(path)" }
    static let diff = "agent.diff"
}

extension View {
    /// Posts the text to VoiceOver when the view appears. Progress percentages are not announced;
    /// those stay on the progress view's accessibility value.
    func ideAnnounces(_ text: String) -> some View {
        onAppear {
            let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty else { return }
            AccessibilityNotification.Announcement(spoken).post()
        }
    }
}

/// Launch flags that exist so UI tests can drive the app. Compiled to a constant in Release.
enum IDEACPUITestLaunch {
    /// True only for a Debug launch started with `--acp-ui-test`. Release builds are never in this mode.
    static var isEnabled: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--acp-ui-test")
        #else
        false
        #endif
    }

    /// The welcome backdrop animates every frame. XCUITest waits for the app to go idle, so the
    /// UI-test launch holds that animation still. A normal launch is unchanged.
    static var pausesMotion: Bool { isEnabled }
}
