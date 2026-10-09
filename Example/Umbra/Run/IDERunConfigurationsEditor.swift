import Foundation
import JavaIntelligence

/// The working copy behind the Edit Configurations dialog: every configuration of the project and
/// the four kinds' templates, edited freely and written back together by OK or Apply. Nothing here
/// touches the stores; `IDEWorkspace.applyRunConfigurationEdits` does, from ``changes()``.
@MainActor
@Observable
final class IDERunConfigurationsEditor {
    enum Selection: Hashable {
        case configuration(UUID)
        case template(JavaRunConfiguration.Kind)
    }

    /// What OK writes: configurations to save (the ones that changed or are new), ones to delete, and templates.
    struct Changes: Equatable {
        var saved: [JavaRunConfiguration]
        var deleted: [UUID]
        var templates: [JavaRunConfiguration]

        var isEmpty: Bool { saved.isEmpty && deleted.isEmpty && templates.isEmpty }
    }

    /// The list in display order: saved configurations as they were, new ones at the end.
    private(set) var configurations: [JavaRunConfiguration]
    private(set) var templates: [JavaRunConfiguration.Kind: JavaRunConfiguration]
    var selection: Selection?

    @ObservationIgnored private var originals: [UUID: JavaRunConfiguration]
    @ObservationIgnored private var originalTemplates: [JavaRunConfiguration.Kind: JavaRunConfiguration]

    /// - Parameter highlighting: a configuration to select (and add, if it is not in `configurations` yet,
    ///   as a new one: the dialog was opened on a draft).
    init(
        configurations: [JavaRunConfiguration],
        templates: [JavaRunConfiguration.Kind: JavaRunConfiguration],
        highlighting draft: JavaRunConfiguration? = nil
    ) {
        self.configurations = configurations
        self.templates = templates
        originals = Dictionary(configurations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        originalTemplates = templates
        if let draft {
            if let index = self.configurations.firstIndex(where: { $0.id == draft.id }) {
                // An edited copy of a saved one (Modify Run Configuration… on a gutter button).
                self.configurations[index] = draft
            } else {
                self.configurations.append(draft)
            }
            selection = .configuration(draft.id)
            // Opening a configuration to edit it is keeping it: OK saves a temporary one for good.
            keep(draft.id)
        } else {
            selection = configurations.last.map { .configuration($0.id) }
        }
    }

    // MARK: - Reading

    var selectedConfigurationID: UUID? {
        if case .configuration(let id) = selection { return id }
        return nil
    }

    /// The configuration or template being edited.
    var selected: JavaRunConfiguration? {
        get {
            switch selection {
            case .configuration(let id): return configurations.first { $0.id == id }
            case .template(let kind): return templates[kind] ?? JavaRunConfiguration.defaultTemplate(for: kind)
            case nil: return nil
            }
        }
        set {
            guard let newValue else { return }
            switch selection {
            case .configuration(let id):
                if let index = configurations.firstIndex(where: { $0.id == id }) { configurations[index] = newValue }
            case .template(let kind):
                templates[kind] = newValue
            case nil:
                break
            }
        }
    }

    func isNew(_ id: UUID) -> Bool { originals[id] == nil }

    /// Whether `id` differs from what is saved. A temporary configuration counts as changed once its
    /// settings change, but not for being temporary.
    func isChanged(_ id: UUID) -> Bool {
        guard let current = configurations.first(where: { $0.id == id }) else { return false }
        guard let original = originals[id] else { return true }
        return Self.comparable(current) != Self.comparable(original)
    }

    var hasChanges: Bool { !changes().isEmpty }

    /// Configurations of a kind, grouped by folder (no folder first), for the list.
    func groups(of kind: JavaRunConfiguration.Kind) -> [(folder: String?, configurations: [JavaRunConfiguration])] {
        let ofKind = configurations.filter { $0.kind == kind }
        var result: [(String?, [JavaRunConfiguration])] = []
        let loose = ofKind.filter { $0.folder == nil }
        if !loose.isEmpty { result.append((nil, loose)) }
        for folder in Set(ofKind.compactMap(\.folder)).sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            result.append((folder, ofKind.filter { $0.folder == folder }))
        }
        return result
    }

    // MARK: - Editing

    /// A new configuration of `kind` from its template, selected. `target` is what it launches.
    @discardableResult
    func add(kind: JavaRunConfiguration.Kind, target: JavaRunConfiguration.Target, name: String? = nil) -> JavaRunConfiguration {
        let template = templates[kind] ?? JavaRunConfiguration.defaultTemplate(for: kind)
        var configuration = template.instantiating(target: target, name: name ?? Self.freshName(kind.title, among: configurations))
        configuration.isTemporary = false
        configurations.append(configuration)
        selection = .configuration(configuration.id)
        return configuration
    }

    func remove(_ id: UUID) {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else { return }
        configurations.remove(at: index)
        // Whatever ran before a deleted configuration no longer waits on it.
        for position in configurations.indices {
            configurations[position].beforeLaunch.removeAll { $0 == .runConfiguration(id) }
        }
        if selection == .configuration(id) {
            selection = configurations.indices.contains(index) ? .configuration(configurations[index].id)
                : configurations.last.map { .configuration($0.id) }
        }
    }

    @discardableResult
    func duplicate(_ id: UUID) -> JavaRunConfiguration? {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = configurations[index]
        copy.id = UUID()
        copy.name = Self.freshName(copy.displayName + " copy", among: configurations)
        copy.isTemporary = false
        configurations.insert(copy, at: index + 1)
        selection = .configuration(copy.id)
        return copy
    }

    /// Save Configuration on a temporary one: from now on it is kept.
    func keep(_ id: UUID) {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else { return }
        configurations[index].isTemporary = false
    }

    func move(_ id: UUID, toFolder folder: String?) {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        configurations[index].folder = trimmed?.isEmpty == false ? trimmed : nil
    }

    func resetTemplate(_ kind: JavaRunConfiguration.Kind) {
        templates[kind] = JavaRunConfiguration.defaultTemplate(for: kind)
    }

    // MARK: - Writing back

    /// What to write. A configuration that was only looked at is not rewritten, so a temporary one
    /// stays temporary; one that was edited (or kept with Save Configuration) is saved for good.
    func changes() -> Changes {
        var saved: [JavaRunConfiguration] = []
        for configuration in configurations {
            let original = originals[configuration.id]
            let kept = original?.isTemporary == true && !configuration.isTemporary
            guard original == nil || isChanged(configuration.id) || kept else { continue }
            var toSave = configuration
            toSave.isTemporary = false
            saved.append(toSave)
        }
        let deleted = originals.keys.filter { id in !configurations.contains { $0.id == id } }
        let changedTemplates = JavaRunConfiguration.Kind.allCases.compactMap { kind -> JavaRunConfiguration? in
            guard let template = templates[kind], template != originalTemplates[kind] else { return nil }
            return template
        }
        return Changes(saved: saved, deleted: Array(deleted), templates: changedTemplates)
    }

    /// Treats the current state as saved, after Apply.
    func markApplied() {
        originals = Dictionary(configurations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        originalTemplates = templates
    }

    // MARK: - Helpers

    /// Compared without the flag Save Configuration flips, so keeping a configuration is not an "edit".
    private static func comparable(_ configuration: JavaRunConfiguration) -> JavaRunConfiguration {
        var copy = configuration
        copy.isTemporary = false
        return copy
    }

    static func freshName(_ base: String, among configurations: [JavaRunConfiguration]) -> String {
        let taken = Set(configurations.map(\.displayName))
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}
