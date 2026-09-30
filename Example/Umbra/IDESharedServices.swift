import Foundation
import JavaIntelligence

/// The stores and services that belong to the app, not to a window. Each window's workspace used to
/// build its own copy of these, each loading its file once and later rewriting all of it, so two
/// windows overwrote each other's breakpoints, run configurations, JDK choices and Gradle trust
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
    let gradleTrust: GradleTrustStore
    let jdkSelection: JDKSelectionStore
    let runConfigurations: JavaRunConfigurationStore
    let breakpoints: JavaBreakpointStore
    /// One indexing run and one parsed shard per JDK for all windows.
    let jdkShards: JavaSharedShardHub

    private init() {
        gradleTrust = GradleTrustStore(storeURL: IDEJavaSupport.defaultGradleTrustStoreURL)
        jdkSelection = JDKSelectionStore(storeURL: IDEJDKSelection.defaultStoreURL)
        runConfigurations = JavaRunConfigurationStore(storeURL: IDEWorkspace.defaultRunConfigurationsURL)
        breakpoints = JavaBreakpointStore(storeURL: JavaBreakpointStore.defaultStoreURL)
        jdkShards = JavaSharedShardHub()
    }
}
