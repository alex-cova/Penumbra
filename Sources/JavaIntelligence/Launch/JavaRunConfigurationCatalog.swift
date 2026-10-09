import Foundation

/// A project's run configurations as the user sees them: the ones kept on this Mac
/// (``JavaRunConfigurationStore``) and the ones the project shares in `.umbra/runConfigurations`
/// (``JavaProjectRunConfigurationFolder``), in one list. A configuration's
/// ``JavaRunConfiguration/storeAsProjectFile`` says where it lives; changing it moves the
/// configuration and keeps its id. Which one is selected is always a per-Mac choice.
///
/// Umbra talks to this and not to the store, so the two sides cannot disagree.
public final class JavaRunConfigurationCatalog: @unchecked Sendable {
    public let store: JavaRunConfigurationStore
    private let lock = NSLock()
    private var folders: [String: JavaProjectRunConfigurationFolder] = [:]
    private var storedTemporaryLimit = JavaRunConfigurationStore.defaultTemporaryLimit

    /// How many temporary configurations a project keeps when `setLast` is not told otherwise.
    public var temporaryLimit: Int {
        get { lock.withLock { storedTemporaryLimit } }
        set { lock.withLock { storedTemporaryLimit = max(1, newValue) } }
    }

    public init(store: JavaRunConfigurationStore) {
        self.store = store
    }

    // MARK: - Reading

    /// Local configurations in the order they were made, then the shared ones by file name.
    public func configurations(forProject root: URL?) -> [JavaRunConfiguration] {
        let local = store.configurations(forProject: root).filter { !$0.storeAsProjectFile }
        let shared = folder(for: root)?.configurations() ?? []
        let sharedIDs = Set(shared.map(\.id))
        return local.filter { !sharedIDs.contains($0.id) } + shared
    }

    /// The selected configuration: what Run Last Configuration runs.
    public func last(forProject root: URL?) -> JavaRunConfiguration? {
        let all = configurations(forProject: root)
        if let selected = store.selectedID(forProject: root), let match = all.first(where: { $0.id == selected }) {
            return match
        }
        return all.last
    }

    public func template(for kind: JavaRunConfiguration.Kind, forProject root: URL?) -> JavaRunConfiguration {
        store.template(for: kind, forProject: root)
    }

    public func setTemplate(_ template: JavaRunConfiguration, forProject root: URL?) {
        store.setTemplate(template, forProject: root)
    }

    // MARK: - Writing

    /// Records `configuration` as the one just used or saved: it replaces the entry with the same id
    /// and becomes the selected one.
    public func setLast(
        _ configuration: JavaRunConfiguration,
        forProject root: URL?,
        temporaryLimit: Int? = nil
    ) {
        let limit = temporaryLimit ?? self.temporaryLimit
        if let folder = sharedFolder(for: configuration, root: root) {
            store.delete(configuration.id, forProject: root)
            folder.save(configuration)
            store.setSelected(configuration.id, forProject: root)
        } else {
            removeShared(configuration.id, root: root)
            store.setLast(localCopy(of: configuration), forProject: root, temporaryLimit: limit)
        }
    }

    /// Adds or replaces `configuration` without changing which one is selected.
    public func save(_ configuration: JavaRunConfiguration, forProject root: URL?) {
        if let folder = sharedFolder(for: configuration, root: root) {
            let wasSelected = store.selectedID(forProject: root) == configuration.id
            store.delete(configuration.id, forProject: root)
            folder.save(configuration)
            if wasSelected { store.setSelected(configuration.id, forProject: root) }
        } else {
            let wasSelected = store.selectedID(forProject: root) == configuration.id
            removeShared(configuration.id, root: root)
            store.save(localCopy(of: configuration), forProject: root)
            if wasSelected { store.setSelected(configuration.id, forProject: root) }
        }
    }

    public func select(_ id: UUID, forProject root: URL?) {
        guard configurations(forProject: root).contains(where: { $0.id == id }) else { return }
        store.setSelected(id, forProject: root)
    }

    /// Removes a configuration from wherever it lives. When it was selected, the newest remaining
    /// one is.
    public func delete(_ id: UUID, forProject root: URL?) {
        let wasSelected = store.selectedID(forProject: root) == id
        store.delete(id, forProject: root)
        removeShared(id, root: root)
        if wasSelected, let fallback = configurations(forProject: root).last {
            store.setSelected(fallback.id, forProject: root)
        }
    }

    /// Adds a copy named `<name> copy` next to the original (shared stays shared), selects it, and
    /// returns it.
    @discardableResult
    public func duplicate(_ id: UUID, forProject root: URL?) -> JavaRunConfiguration? {
        guard var copy = configurations(forProject: root).first(where: { $0.id == id }) else { return nil }
        copy.id = UUID()
        copy.name = copy.displayName + " copy"
        copy.isTemporary = false
        setLast(copy, forProject: root)
        return copy
    }

    /// Save Configuration: a temporary configuration becomes a saved one and stays selected.
    public func makePermanent(_ id: UUID, forProject root: URL?) {
        guard var configuration = configurations(forProject: root).first(where: { $0.id == id }),
              configuration.isTemporary else { return }
        configuration.isTemporary = false
        save(configuration, forProject: root)
    }

    /// Puts a configuration in `folder` (a group of the list), or out of any with `nil`.
    public func move(_ id: UUID, toFolder folder: String?, forProject root: URL?) {
        guard var configuration = configurations(forProject: root).first(where: { $0.id == id }) else { return }
        let trimmed = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.folder = trimmed?.isEmpty == false ? trimmed : nil
        save(configuration, forProject: root)
    }

    // MARK: - Folders

    private func folder(for root: URL?) -> JavaProjectRunConfigurationFolder? {
        guard let root else { return nil }
        let key = root.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if let existing = folders[key] { return existing }
        let created = JavaProjectRunConfigurationFolder(root: root)
        folders[key] = created
        return created
    }

    /// The folder to write `configuration` to, when it is shared and the project has a root.
    private func sharedFolder(for configuration: JavaRunConfiguration, root: URL?) -> JavaProjectRunConfigurationFolder? {
        configuration.storeAsProjectFile ? folder(for: root) : nil
    }

    /// What the local store keeps: with no project folder to share into, the flag cannot hold, and a
    /// flagged configuration would be hidden from the list.
    private func localCopy(of configuration: JavaRunConfiguration) -> JavaRunConfiguration {
        var copy = configuration
        copy.storeAsProjectFile = false
        return copy
    }

    private func removeShared(_ id: UUID, root: URL?) {
        folder(for: root)?.delete(id: id)
    }
}
