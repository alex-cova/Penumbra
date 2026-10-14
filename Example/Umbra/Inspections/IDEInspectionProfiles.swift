import Foundation
import JavaIntelligence
import Observation

/// The app's named inspection profiles. "Default" is the one the settings always had: its
/// rules, severities and thresholds live in the `IDEPreferences` keys, so what a user set before
/// profiles existed is still there, and its per-scope exceptions in one more key. Every other
/// profile is a JSON file in Application Support, one per profile.
@MainActor
@Observable
final class IDEInspectionProfiles {
    static let shared = IDEInspectionProfiles()
    static let defaultName = JavaInspectionProfile.defaultName

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("InspectionProfiles", isDirectory: true)
    }

    private static let selectedKey = "com.umbra.editor.inspectionProfile"
    private static let scopedOverridesKey = "com.umbra.editor.javaInspectionScopedOverrides"

    /// File-backed profiles by name.
    private(set) var custom: [String: JavaInspectionProfile] = [:]
    /// Bumped on every change, for views that read `profile(named:)`.
    private(set) var revision = 0

    /// The global profile windows use when their project has no profile file of its own.
    var selectedName: String {
        didSet {
            guard oldValue != selectedName else { return }
            defaults.set(selectedName, forKey: Self.selectedKey)
            revision += 1
        }
    }

    @ObservationIgnored let directory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let preferences: IDEPreferences

    init(directory: URL = defaultDirectory, defaults: UserDefaults = .standard, preferences: IDEPreferences = .shared) {
        self.directory = directory
        self.defaults = defaults
        self.preferences = preferences
        selectedName = defaults.string(forKey: Self.selectedKey) ?? Self.defaultName
        reload()
        if selectedName != Self.defaultName, custom[selectedName] == nil { selectedName = Self.defaultName }
    }

    // MARK: Reading

    /// "Default" first, then the others by name.
    var names: [String] {
        [Self.defaultName] + custom.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var defaultProfile: JavaInspectionProfile {
        var scoped: [JavaInspectionProfile.ScopedOverride] = []
        if let data = defaults.data(forKey: Self.scopedOverridesKey),
           let decoded = try? JSONDecoder().decode([JavaInspectionProfile.ScopedOverride].self, from: data) {
            scoped = decoded
        }
        return JavaInspectionProfile(
            name: Self.defaultName,
            disabled: preferences.javaDisabledInspections,
            severities: preferences.javaInspectionSeverities,
            limits: preferences.javaInspectionLimits,
            treatsPublicApiAsUsed: preferences.javaTreatsPublicApiAsUsed,
            scopedOverrides: scoped
        )
    }

    func profile(named name: String) -> JavaInspectionProfile? {
        name == Self.defaultName ? defaultProfile : custom[name]
    }

    /// The selected global profile (Default when the choice is gone).
    var selectedProfile: JavaInspectionProfile {
        profile(named: selectedName) ?? defaultProfile
    }

    // MARK: Writing

    /// Stores `profile` under its name: into the preference keys for Default, a file otherwise.
    func save(_ profile: JavaInspectionProfile) {
        if profile.name == Self.defaultName {
            if preferences.javaDisabledInspections != profile.disabled { preferences.javaDisabledInspections = profile.disabled }
            if preferences.javaInspectionSeverities != profile.severities { preferences.javaInspectionSeverities = profile.severities }
            if preferences.javaInspectionLimits != profile.limits { preferences.javaInspectionLimits = profile.limits }
            if preferences.javaTreatsPublicApiAsUsed != profile.treatsPublicApiAsUsed {
                preferences.javaTreatsPublicApiAsUsed = profile.treatsPublicApiAsUsed
            }
            if profile.scopedOverrides.isEmpty {
                defaults.removeObject(forKey: Self.scopedOverridesKey)
            } else if let data = try? JSONEncoder().encode(profile.scopedOverrides) {
                defaults.set(data, forKey: Self.scopedOverridesKey)
            }
        } else {
            custom[profile.name] = profile
            try? write(profile)
        }
        revision += 1
    }

    /// A new profile named after `base` (made unique), starting from `contents`.
    @discardableResult
    func create(named base: String, from contents: JavaInspectionProfile) -> JavaInspectionProfile {
        var profile = contents
        profile.name = uniqueName(base)
        save(profile)
        return profile
    }

    func rename(_ oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard oldName != Self.defaultName, !trimmed.isEmpty, trimmed != oldName, custom[trimmed] == nil,
              trimmed != Self.defaultName, var profile = custom[oldName] else { return }
        delete(oldName, adjustingSelection: false)
        profile.name = trimmed
        save(profile)
        if selectedName == oldName { selectedName = trimmed }
    }

    func delete(_ name: String) { delete(name, adjustingSelection: true) }

    private func delete(_ name: String, adjustingSelection: Bool) {
        guard name != Self.defaultName, custom.removeValue(forKey: name) != nil else { return }
        try? FileManager.default.removeItem(at: fileURL(for: name))
        if adjustingSelection, selectedName == name { selectedName = Self.defaultName }
        revision += 1
    }

    /// Re-reads the profile files (they may have been copied in or edited).
    func reload() {
        var loaded: [String: JavaInspectionProfile] = [:]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), var profile = try? JSONDecoder().decode(JavaInspectionProfile.self, from: data)
            else { continue }
            if profile.name.isEmpty || profile.name == Self.defaultName { profile.name = url.deletingPathExtension().lastPathComponent }
            if profile.name == Self.defaultName { continue }
            loaded[profile.name] = profile
        }
        guard loaded != custom else { return }
        custom = loaded
        revision += 1
    }

    func uniqueName(_ base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmed.isEmpty ? "Profile" : trimmed
        guard root == Self.defaultName || custom[root] != nil else { return root }
        var number = 2
        while custom["\(root) \(number)"] != nil { number += 1 }
        return "\(root) \(number)"
    }

    private func fileURL(for name: String) -> URL {
        let safe = name.map { "/:\\".contains($0) ? "-" : String($0) }.joined()
        return directory.appendingPathComponent(safe).appendingPathExtension("json")
    }

    private func write(_ profile: JavaInspectionProfile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoded(profile).write(to: fileURL(for: profile.name), options: .atomic)
    }

    static func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    // MARK: Project file

    /// `<project>/.umbra/inspections.json`, shared through version control.
    static let projectRelativePath = ".umbra/inspections.json"

    private struct ProjectFile: Codable {
        var profile: JavaInspectionProfile
    }

    static func projectFileURL(root: URL) -> URL {
        root.appendingPathComponent(projectRelativePath)
    }

    /// The project's own profile, or nil when there is no file or it does not read.
    static func loadProjectProfile(root: URL) -> JavaInspectionProfile? {
        guard let data = try? Data(contentsOf: projectFileURL(root: root)) else { return nil }
        return (try? JSONDecoder().decode(ProjectFile.self, from: data))?.profile
    }

    static func writeProjectProfile(_ profile: JavaInspectionProfile, root: URL) throws {
        let url = projectFileURL(root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded(ProjectFile(profile: profile)).write(to: url, options: .atomic)
    }
}
