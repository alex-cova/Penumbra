import Foundation
import Observation

/// What clicking a notification does. The workspace maps each case to the panel it opens, so the
/// model stays free of UI types.
enum IDENotificationAction: Equatable {
    case showGradleOutput
    case showMavenOutput
    case showSourceControl
    case showProblems
    /// Show the Coverage tab.
    case showCoverage
    /// Open the agent panel on this chat.
    case showAgentChat(UUID)
    /// Show this file's tab (opening it if it was closed).
    case openFile(String)
    /// Select this file in Finder.
    case revealInFinder(String)
}

extension IDENotificationAction {
    /// The link shown under a notification whose click does something a panel title would not
    /// say; nil when the title and detail are enough.
    var linkTitle: String? {
        switch self {
        case .revealInFinder: "Reveal in Finder"
        default: nil
        }
    }
}

enum IDENotificationCategory: String, CaseIterable, Identifiable {
    case gradle
    case maven
    case git
    case agent
    case terminal
    case general

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gradle: "Gradle"
        case .maven: "Maven"
        case .git: "Git"
        case .agent: "Agent"
        case .terminal: "Terminal"
        case .general: "General"
        }
    }
}

enum IDENotificationSeverity: Equatable {
    case info
    case success
    case warning
    case error
}

struct IDENotification: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let category: IDENotificationCategory
    let severity: IDENotificationSeverity
    let title: String
    let detail: String?
    let action: IDENotificationAction?
}

/// The bell's list plus the toast that announces a new entry. Live progress (a sync running) is
/// not a notification; only events that finished are posted here. An entry stays until the user
/// dismisses it, so "no notifications" means nothing is waiting.
@MainActor
@Observable
final class IDENotificationCenter {
    static let capacity = 100
    nonisolated static let defaultToastDuration: Duration = .seconds(5)

    private enum Keys {
        static let muted = "notifications.muted"
        static let disabledCategories = "notifications.disabledCategories"
    }

    /// Newest first.
    private(set) var items: [IDENotification] = []
    /// The entry announced top-right. Errors stay until dismissed; the rest fade after
    /// `toastDuration`.
    private(set) var toast: IDENotification?
    private(set) var isPanelPresented = false
    /// Entries posted while the panel was closed and not yet seen. Opening the panel sees them all.
    private var unseenIDs: Set<IDENotification.ID> = []

    /// How many entries arrived since the panel was last open: the bell's count badge.
    var unseenCount: Int {
        items.reduce(0) { unseenIDs.contains($1.id) ? $0 + 1 : $0 }
    }

    /// The bell glyph: plain while the count badge says what is new, dotted while seen entries
    /// still wait, plain when there are none.
    var bellSymbol: String {
        unseenCount == 0 && !items.isEmpty ? "bell.badge" : "bell"
    }

    /// Do Not Disturb: notifications are still recorded, but none is announced.
    var isMuted: Bool {
        didSet { defaults.set(isMuted, forKey: Keys.muted) }
    }
    /// A disabled category is not recorded at all.
    private(set) var disabledCategories: Set<IDENotificationCategory> {
        didSet { defaults.set(disabledCategories.map(\.rawValue).sorted(), forKey: Keys.disabledCategories) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let toastDuration: Duration
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Only written in `init` and read in `deinit`, which run without other access.
    @ObservationIgnored nonisolated(unsafe) private var defaultsObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, toastDuration: Duration = IDENotificationCenter.defaultToastDuration) {
        self.defaults = defaults
        self.toastDuration = toastDuration
        isMuted = defaults.bool(forKey: Keys.muted)
        let stored = defaults.stringArray(forKey: Keys.disabledCategories) ?? []
        disabledCategories = Set(stored.compactMap(IDENotificationCategory.init(rawValue:)))
        // Do Not Disturb and the category switches are app-wide: another window's bell writes them
        // to the same defaults, and this window's copy follows.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSharedSettings() }
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    /// Re-reads the two shared switches, assigning only what differs: assigning writes the defaults
    /// again, which would post the change notification and loop.
    private func reloadSharedSettings() {
        let muted = defaults.bool(forKey: Keys.muted)
        if muted != isMuted {
            isMuted = muted
        }
        let stored = defaults.stringArray(forKey: Keys.disabledCategories) ?? []
        let categories = Set(stored.compactMap(IDENotificationCategory.init(rawValue:)))
        if categories != disabledCategories {
            disabledCategories = categories
            // A category another window just turned off is not recorded here either.
            items.removeAll { categories.contains($0.category) }
            if let toast, categories.contains(toast.category) { dismissToast() }
        }
    }

    func post(
        _ title: String,
        detail: String? = nil,
        category: IDENotificationCategory = .general,
        severity: IDENotificationSeverity = .info,
        action: IDENotificationAction? = nil
    ) {
        guard !disabledCategories.contains(category) else { return }
        let notification = IDENotification(
            id: UUID(),
            date: Date(),
            category: category,
            severity: severity,
            title: title,
            detail: detail,
            action: action
        )
        items.insert(notification, at: 0)
        if items.count > Self.capacity {
            items.removeLast(items.count - Self.capacity)
            unseenIDs.formIntersection(items.map(\.id))
        }
        if !isPanelPresented { unseenIDs.insert(notification.id) }
        guard !isMuted, !isPanelPresented else { return }
        announce(notification)
    }

    func remove(_ id: IDENotification.ID) {
        items.removeAll { $0.id == id }
        unseenIDs.remove(id)
        if toast?.id == id { dismissToast() }
    }

    func clear() {
        items.removeAll()
        unseenIDs.removeAll()
        dismissToast()
    }

    func dismissToast() {
        toastTask?.cancel()
        toastTask = nil
        toast = nil
    }

    func togglePanel() {
        setPanelPresented(!isPanelPresented)
    }

    func setPanelPresented(_ presented: Bool) {
        isPanelPresented = presented
        if presented {
            unseenIDs.removeAll()
            dismissToast()
        }
    }

    func isEnabled(_ category: IDENotificationCategory) -> Bool {
        !disabledCategories.contains(category)
    }

    func setCategory(_ category: IDENotificationCategory, enabled: Bool) {
        if enabled {
            disabledCategories.remove(category)
        } else {
            disabledCategories.insert(category)
            items.removeAll { $0.category == category }
            if toast?.category == category { dismissToast() }
        }
    }

    private func announce(_ notification: IDENotification) {
        toastTask?.cancel()
        toastTask = nil
        toast = notification
        guard notification.severity != .error else { return }
        let id = notification.id
        let duration = toastDuration
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.toast?.id == id else { return }
            self.toast = nil
            self.toastTask = nil
        }
    }
}
