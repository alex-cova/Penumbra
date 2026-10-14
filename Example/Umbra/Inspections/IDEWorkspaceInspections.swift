import Foundation
import JavaIntelligence
import Observation

/// One window's choice of inspection profile: its project's `.umbra/inspections.json` when there
/// is one (IntelliJ's "Project Default"), otherwise the selected global profile. Editing writes
/// to whichever is active, then `onChange` makes every window analyse again.
@MainActor
@Observable
final class IDEWorkspaceInspections {
    enum Source: Hashable {
        case project
        case global(String)
    }

    @ObservationIgnored let store: IDEInspectionProfiles
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: (() -> Void)?

    /// A rule the Settings pane should show (from "Edit inspection settings" on ⌥↩ or a result).
    var focusedRuleCode: String?

    private(set) var root: URL?
    private(set) var projectProfile: JavaInspectionProfile?
    /// The user picked a global profile although the project has its own.
    private(set) var prefersGlobal = false

    init(store: IDEInspectionProfiles = .shared, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    private func preferenceKey(for root: URL) -> String {
        "umbra.inspections.prefersGlobal.\(root.standardizedFileURL.path)"
    }

    func setRoot(_ url: URL?) {
        root = url
        projectProfile = url.flatMap(IDEInspectionProfiles.loadProjectProfile(root:))
        prefersGlobal = url.map { defaults.bool(forKey: preferenceKey(for: $0)) } ?? false
    }

    /// Re-reads the project file after it changed on disk. Returns whether the profile changed.
    @discardableResult
    func reloadProjectFile() -> Bool {
        guard let root else { return false }
        let loaded = IDEInspectionProfiles.loadProjectProfile(root: root)
        guard loaded != projectProfile else { return false }
        projectProfile = loaded
        return true
    }

    var hasProjectProfile: Bool { projectProfile != nil }

    var activeSource: Source {
        if projectProfile != nil, !prefersGlobal { return .project }
        return .global(store.profile(named: store.selectedName) == nil ? IDEInspectionProfiles.defaultName : store.selectedName)
    }

    var activeProfile: JavaInspectionProfile {
        profile(for: activeSource) ?? store.defaultProfile
    }

    func profile(for source: Source) -> JavaInspectionProfile? {
        switch source {
        case .project: projectProfile
        case .global(let name): store.profile(named: name)
        }
    }

    func title(for source: Source) -> String {
        switch source {
        case .project: "Project"
        case .global(let name): name
        }
    }

    /// Makes `source` the profile this window analyses with.
    func select(_ source: Source) {
        switch source {
        case .project:
            guard projectProfile != nil else { return }
            setPrefersGlobal(false)
        case .global(let name):
            guard store.profile(named: name) != nil else { return }
            store.selectedName = name
            if projectProfile != nil { setPrefersGlobal(true) }
        }
        onChange?()
    }

    private func setPrefersGlobal(_ value: Bool) {
        prefersGlobal = value
        guard let root else { return }
        if value { defaults.set(true, forKey: preferenceKey(for: root)) } else { defaults.removeObject(forKey: preferenceKey(for: root)) }
    }

    /// Changes `source` (the active profile when nil) and tells every window.
    func edit(_ source: Source? = nil, _ change: (inout JavaInspectionProfile) -> Void) {
        let target = source ?? activeSource
        guard var profile = profile(for: target) else { return }
        let before = profile
        change(&profile)
        guard profile != before else { return }
        switch target {
        case .project:
            guard let root else { return }
            projectProfile = profile
            try? IDEInspectionProfiles.writeProjectProfile(profile, root: root)
        case .global:
            store.save(profile)
        }
        onChange?()
    }

    /// Copies a global profile into the project's file and makes it the active one.
    func copyToProject(from name: String? = nil) {
        guard let root else { return }
        var profile = store.profile(named: name ?? store.selectedName) ?? store.defaultProfile
        profile.name = "Project"
        projectProfile = profile
        try? IDEInspectionProfiles.writeProjectProfile(profile, root: root)
        setPrefersGlobal(false)
        onChange?()
    }

    /// Saves the project's profile as a global one.
    @discardableResult
    func copyToGlobal(named base: String) -> String? {
        guard let projectProfile else { return nil }
        let created = store.create(named: base, from: projectProfile)
        return created.name
    }

    /// Removes the project's profile file; the window goes back to the global profile.
    func removeProjectProfile() {
        guard let root, projectProfile != nil else { return }
        try? FileManager.default.removeItem(at: IDEInspectionProfiles.projectFileURL(root: root))
        projectProfile = nil
        setPrefersGlobal(false)
        onChange?()
    }
}
