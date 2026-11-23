import Foundation
import JavaIntelligence

/// The stores and services that belong to the app, not to a window. Each window's workspace used to
/// build its own copy of these, each loading its file once and later rewriting all of it, so two
/// windows overwrote each other's breakpoints, run configurations, JDK choices and trust
/// decisions, and a decision made in one was not seen by the other. There is one instance of each
/// now, created here once and handed to every window.
///
/// The stores also re-read their file when it changed on disk before reading or merging their own
/// change (`FileChangeStamp`), which covers a second Umbra process as well; that is not a supported
/// setup, just no longer destructive.
@MainActor
final class IDESharedServices {
    static let shared = IDESharedServices()

    /// Which Gradle projects the user trusted to run build scripts. A decision in one window counts
    /// in all of them immediately.
    let gradleTrust: ProjectTrustStore
    /// Which folders the user trusted to run Maven. Separate from Gradle: agreeing to one does not
    /// agree to the other. Reading a POM does not consult it.
    let mavenTrust: ProjectTrustStore
    /// Which folders the user trusted to run npm scripts. Separate from Gradle trust: agreeing to
    /// one does not agree to the other.
    let npmTrust: ProjectTrustStore
    /// Which folders the user trusted to evaluate `Package.swift` and run `swift` commands. Its own
    /// file, like npm's.
    let swiftPMTrust: ProjectTrustStore
    /// Which folders the user trusted to run `xcodebuild` (build phases can run scripts). Its own file.
    let xcodeTrust: ProjectTrustStore
    let dockerTrust: ProjectTrustStore
    /// Which repositories the user trusted to run their own hooks and config-named programs (clean
    /// filters, credential helpers…) when Umbra stages, commits or syncs. Its own file.
    let gitTrust: ProjectTrustStore
    let jdkSelection: JDKSelectionStore
    /// The run configurations kept on this Mac and the ones a project shares in `.umbra/runConfigurations`.
    let runConfigurations: JavaRunConfigurationCatalog
    let breakpoints: JavaBreakpointStore
    /// Bookmarks and bookmark lists per project.
    let bookmarks: IDEBookmarkStore
    /// Data sources for the Database tool. Passwords stay in the Keychain.
    let databases: IDEDatabaseCatalog
    /// One indexing run and one parsed shard per JDK and per dependency jar, for all windows.
    let shards: JavaSharedShardHub
    /// Gives back the parsed jar and JDK shards nobody is using when the system asks for memory;
    /// they are rebuilt from disk on the next request. Held for the life of the app.
    private let memoryPressure: DispatchSourceMemoryPressure

    private init() {
        let store = Self.storeURL
        gradleTrust = ProjectTrustStore(storeURL: store(IDEGradleProjectSystem.defaultTrustStoreURL))
        mavenTrust = ProjectTrustStore(storeURL: store(IDEMavenProjectSystem.defaultTrustStoreURL))
        npmTrust = ProjectTrustStore(storeURL: store(IDENpmProjectSystem.defaultTrustStoreURL))
        swiftPMTrust = ProjectTrustStore(storeURL: store(IDESwiftPMProjectSystem.defaultTrustStoreURL))
        xcodeTrust = ProjectTrustStore(storeURL: store(IDEXcodeProjectSystem.defaultTrustStoreURL))
        dockerTrust = ProjectTrustStore(storeURL: store(IDEGradleProjectSystem.defaultTrustStoreURL
            .deletingLastPathComponent().appendingPathComponent("docker-trust.json")))
        gitTrust = ProjectTrustStore(storeURL: store(IDEGradleProjectSystem.defaultTrustStoreURL
            .deletingLastPathComponent().appendingPathComponent("git-trust.json")))
        jdkSelection = JDKSelectionStore(storeURL: store(IDEJDKSelection.defaultStoreURL))
        runConfigurations = JavaRunConfigurationCatalog(
            store: JavaRunConfigurationStore(storeURL: store(IDEWorkspace.defaultRunConfigurationsURL))
        )
        breakpoints = JavaBreakpointStore(storeURL: store(JavaBreakpointStore.defaultStoreURL))
        bookmarks = IDEBookmarkStore(storeURL: store(IDEBookmarkStore.defaultStoreURL))
        databases = IDEDatabaseCatalog(storeURL: store(IDEDatabaseCatalog.defaultStoreURL))
        let hub = JavaSharedShardHub()
        shards = hub
        memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressure.setEventHandler {
            Task { await hub.trimMemory() }
        }
        memoryPressure.resume()
    }

    /// Where the shared stores live under XCTest: a directory of its own for this test process,
    /// so the suite neither reads the user's saved data sources, trust decisions, JDK choice,
    /// breakpoints and bookmarks nor writes to them. Nil in a real Umbra process.
    static let testStoreDirectory: URL? = {
        let environment = ProcessInfo.processInfo.environment
        let underXCTest = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        guard underXCTest else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-test-shared-stores-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
    }()

    /// `defaultURL` in a real process; the same file name inside `testStoreDirectory` under XCTest.
    static func storeURL(_ defaultURL: URL) -> URL {
        guard let directory = testStoreDirectory else { return defaultURL }
        return directory.appendingPathComponent(defaultURL.lastPathComponent)
    }
}
