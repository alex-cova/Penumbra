import Foundation
import JavaIntelligence
import Observation

/// Which JDK Umbra uses, and the list it chooses from. The project's own choice wins over the
/// default for every project, and that over Automatic (`JDKLocator.resolve`). Indexing, `javac`
/// diagnostics, Gradle, Run and Debug all ask here instead of calling `JDKLocator` themselves, so
/// the status bar never names a different JDK than the one that runs.
///
/// Detection and resolution touch the file system and run `java_home`, so they happen off the main
/// actor. ``current`` is the last result, for code that needs the answer synchronously (building a
/// Run command).
@MainActor
@Observable
final class IDEJDKSelection {
    enum AddError: LocalizedError, Equatable {
        case notAJDK
        case alreadyListed

        var errorDescription: String? {
            switch self {
            case .notAJDK: "Not a JDK: no release file found."
            case .alreadyListed: "That JDK is already in the list."
            }
        }
    }

    /// Every JDK found on disk plus the ones the user added, newest first.
    private(set) var detected: [JDKInstallation] = []
    private(set) var isScanning = false
    /// The JDK the open project uses, resolved with its language level.
    private(set) var current: JDKResolution?
    /// The open project's own choice and the default (paths as chosen, not checked).
    private(set) var selection = JDKSelection()
    /// Homes of the JDKs the user added by hand, resolved.
    private(set) var addedHomes: Set<String> = []

    /// The open project's Java language level (the Gradle model's), when known.
    @ObservationIgnored var languageLevel: () -> Int? = { nil }
    /// A choice changed; the host re-indexes, re-checks and re-syncs.
    @ObservationIgnored var onSelectionChanged: (@MainActor () -> Void)?

    @ObservationIgnored private let store: JDKSelectionStore
    @ObservationIgnored private(set) var projectRoot: URL?
    @ObservationIgnored private var scanGeneration = 0

    init(store: JDKSelectionStore = IDESharedServices.shared.jdkSelection) {
        self.store = store
        selection = store.selection(forProject: nil)
        addedHomes = Self.resolvedHomes(store.customJDKs)
    }

    /// Next to `run-configurations.json`: a choice shouldn't reset with a cache.
    static var defaultStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("jdk-selection.json")
    }

    // MARK: - Project

    /// Loads the project's choice. Call before anything asks for a JDK for the new root.
    func setProjectRoot(_ url: URL?) {
        projectRoot = url
        selection = store.selection(forProject: url)
        current = nil
    }

    // MARK: - Resolving

    /// The JDK to use now. With no explicit choice, `minimumFeatureVersion` picks the closest
    /// installation at or above it, and `nil` the newest (what Gradle wants).
    func resolve(minimumFeatureVersion: Int?, maximumFeatureVersion: Int? = nil) async -> JDKResolution? {
        let selection = store.selection(forProject: projectRoot)
        let added = store.customJDKs
        return await Task.detached(priority: .utility) {
            JDKLocator().resolve(
                selection: selection,
                minimumFeatureVersion: minimumFeatureVersion,
                maximumFeatureVersion: maximumFeatureVersion,
                additionalHomes: added
            )
        }.value
    }

    /// The JDK to launch Gradle on: the newest one the project's wrapper supports. Gradle's Groovy
    /// cannot compile build scripts on a newer JDK (`Unsupported class file major version`). An
    /// explicit choice still wins.
    func resolveForGradle() async -> JDKResolution? {
        let cap = projectRoot.flatMap(GradleJDKCompatibility.maximumJavaVersion(forProject:))
        return await resolve(minimumFeatureVersion: nil, maximumFeatureVersion: cap)
    }

    /// Re-resolves ``current`` with the project's language level.
    func refreshCurrent() async {
        let root = projectRoot
        let resolution = await resolve(minimumFeatureVersion: languageLevel())
        guard root == projectRoot else { return }
        current = resolution
    }

    /// Lists the JDKs on disk and the ones the user added.
    func refreshDetected() async {
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        let added = store.customJDKs
        let found = await Task.detached(priority: .utility) {
            JDKLocator().discoverAll(additionalHomes: added)
        }.value
        guard generation == scanGeneration else { return }
        detected = found
        addedHomes = Self.resolvedHomes(added)
        isScanning = false
    }

    // MARK: - Choosing

    /// `nil` puts the project back on the default (or Automatic).
    func chooseForProject(_ installation: JDKInstallation?) {
        guard let projectRoot else { return }
        store.setProject(installation?.home, forProject: projectRoot)
        selectionDidChange()
    }

    /// `nil` puts every project without its own choice back on Automatic.
    func chooseAsDefault(_ installation: JDKInstallation?) {
        store.setGlobal(installation?.home)
        selectionDidChange()
    }

    func useAutomatic() {
        chooseForProject(nil)
    }

    // MARK: - Added JDKs

    /// Validates a folder the user picked and adds it to the list.
    func addJDK(at url: URL) -> Result<JDKInstallation, AddError> {
        guard let installation = JDKLocator().installation(atUserSelected: url) else { return .failure(.notAJDK) }
        let home = installation.home.resolvingSymlinksInPath().path
        let alreadyListed = detected.contains { $0.home.resolvingSymlinksInPath().path == home }
        guard store.addCustomJDK(installation.home) else { return .failure(.alreadyListed) }
        if alreadyListed {
            // Detected on its own already: nothing new for the list, but it now survives losing
            // the source that found it.
            addedHomes = Self.resolvedHomes(store.customJDKs)
        } else {
            Task { await refreshDetected() }
        }
        return .success(installation)
    }

    /// Removes an added JDK from the list. What still chose it falls back to the next level.
    func removeJDK(_ installation: JDKInstallation) {
        guard isUserAdded(installation) else { return }
        store.removeCustomJDK(installation.home)
        addedHomes = Self.resolvedHomes(store.customJDKs)
        detected.removeAll { $0.home.resolvingSymlinksInPath() == installation.home.resolvingSymlinksInPath() }
        Task { await refreshDetected() }
        selectionDidChange()
    }

    func isUserAdded(_ installation: JDKInstallation) -> Bool {
        addedHomes.contains(installation.home.resolvingSymlinksInPath().path)
    }

    /// What would lose its JDK if `installation` were removed, for the confirmation.
    func usage(of installation: JDKInstallation) -> (projects: [String], isDefault: Bool) {
        store.usage(of: installation.home)
    }

    /// An added JDK whose folder is gone or no longer holds a JDK.
    func isMissing(_ installation: JDKInstallation) -> Bool {
        !FileManager.default.fileExists(atPath: installation.home.appendingPathComponent("release").path)
    }

    // MARK: - Reading state

    /// `true` when `installation` is the project's own choice.
    func isProjectChoice(_ installation: JDKInstallation) -> Bool {
        matches(selection.project, installation)
    }

    func isDefault(_ installation: JDKInstallation) -> Bool {
        matches(selection.global, installation)
    }

    func isInUse(_ installation: JDKInstallation) -> Bool {
        current?.installation.home.resolvingSymlinksInPath() == installation.home.resolvingSymlinksInPath()
    }

    /// Short label for the status bar: `JDK 21`.
    var statusTitle: String? {
        current.map { "JDK \($0.installation.featureVersion)" }
    }

    /// Why the status bar item deserves attention (a JDK older than the project's language level,
    /// a saved JDK that is gone, a JRE without `javac`), or `nil`.
    func warning(maxLanguageLevel: Int?) -> String? {
        guard let current else { return nil }
        if let stale = current.staleSelection {
            return "The saved JDK (\(stale.path)) was not found; using \(current.installation.displayName)."
        }
        if let maxLanguageLevel, current.installation.featureVersion < maxLanguageLevel {
            return "Project targets Java \(maxLanguageLevel); JDK \(current.installation.featureVersion) selected."
        }
        if !current.installation.isFullJDK {
            return "\(current.installation.displayName) has no javac, so Java files can't be checked."
        }
        return nil
    }

    /// The tooltip for the status bar item.
    func summary(maxLanguageLevel: Int?) -> String {
        guard let current else { return "No JDK found. Choose one from this menu." }
        var lines = ["\(current.installation.displayName) (\(current.installation.home.path))"]
        switch current.source {
        case .project: lines.append("Chosen for this project")
        case .global: lines.append("Default for all projects")
        case .automatic: lines.append("Picked automatically")
        }
        if let warning = warning(maxLanguageLevel: maxLanguageLevel) { lines.append(warning) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    private func selectionDidChange() {
        selection = store.selection(forProject: projectRoot)
        onSelectionChanged?()
    }

    private func matches(_ home: URL?, _ installation: JDKInstallation) -> Bool {
        home?.resolvingSymlinksInPath() == installation.home.resolvingSymlinksInPath()
    }

    private static func resolvedHomes(_ homes: [URL]) -> Set<String> {
        Set(homes.map { $0.resolvingSymlinksInPath().path })
    }
}
