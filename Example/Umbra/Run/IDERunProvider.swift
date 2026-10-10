import Foundation
import JavaIntelligence

/// A program to start in the Run tool window: an executable and its arguments (never a shell string),
/// its working directory and its whole environment. What a run provider builds and `IDERunSession`
/// spawns.
struct IDEProcessLaunch: Equatable, Sendable {
    var executable: URL
    var arguments: [String]
    var workingDirectory: URL
    /// The child's whole environment.
    var environment: [String: String]
    /// A text file to feed the program as standard input.
    var redirectInput: URL?
    /// Files written for this launch (an `@argfile`); deleted when it ends.
    var temporaryFiles: [URL]
    /// The launch as a shell would write it, for the console and Copy Command Line. Not what runs.
    var displayCommand: String

    init(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        redirectInput: URL? = nil,
        temporaryFiles: [URL] = [],
        displayCommand: String = ""
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.redirectInput = redirectInput
        self.temporaryFiles = temporaryFiles
        self.displayCommand = displayCommand
    }

    init(_ launch: JavaProcessLaunch) {
        self.init(
            executable: launch.executable,
            arguments: launch.arguments,
            workingDirectory: launch.workingDirectory,
            environment: launch.environment,
            redirectInput: launch.redirectInput,
            temporaryFiles: launch.temporaryFiles,
            displayCommand: launch.displayCommand
        )
    }
}

enum IDERunMode: Sendable {
    case run
    case debug
}

/// The active editor as a run provider sees it: where it lives, what language it is, its text and the
/// caret. Read on the main actor when a button is pressed or the run availability is refreshed.
struct IDERunDocument {
    var url: URL?
    var languageIdentifier: String?
    var caretUTF16Offset: Int
    private let readText: @MainActor () -> String

    /// `text` is read only when a provider asks for it: copying a large buffer is not free, and Run
    /// of a file needs no text at all.
    init(
        url: URL?, languageIdentifier: String?, caretUTF16Offset: Int = 0,
        text: @autoclosure @escaping @MainActor () -> String
    ) {
        self.url = url
        self.languageIdentifier = languageIdentifier
        self.caretUTF16Offset = caretUTF16Offset
        readText = text
    }

    @MainActor var text: String { readText() }
}

/// Something in a document that can be started on its own: a `main`, a test method, a test class. The
/// gutter's play buttons and the caret's "Run in Context" both come from these.
struct IDERunnableLocation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A program's entry point.
        case entryPoint
        case test
        /// A group of tests: a test class.
        case testGroup
    }

    let kind: Kind
    /// 1-based.
    let line: Int
    /// "Main.main()", "shouldAdd()", "CalculatorTest".
    let title: String
}

/// One start of a program in the Run tool window: who runs it, what to call it, how a rerun replaces
/// it, and the work that comes before the process (checks, the build, the JDK) ending in
/// `session.start(_:)` or `session.fail(_:)`.
struct IDERunRequest {
    /// Identifies what is being run across reruns (a run configuration's id): the newest session of
    /// the same id is the one a rerun replaces.
    let id: UUID
    let title: String
    let providerID: String
    /// The provider's own description of the run, kept on the session so the provider can run it again.
    let payload: (any Sendable)?
    /// A second start of the same run while the first is going runs beside it instead of replacing it.
    let allowsMultipleInstances: Bool
    let prepare: @MainActor (IDERunSession) async -> Void
}

/// What a language adds so Run, Debug, Run in Context and Stop work on its files. Supplies the
/// runnable places in a document and the process launch; the sessions, the Run tool window and the
/// toolbar belong to Umbra. Debugging stays with the one language that has a debugger (Java).
///
/// One instance per window, made by the language module (`IDELanguageModule.makeRunProvider`). A
/// provider holds its window weakly, so it never keeps the window alive.
@MainActor
protocol IDERunProvider: AnyObject {
    var id: String { get }
    var languageIdentifiers: Set<String> { get }

    /// Whether the Run button applies to `document`. May parse the text: the host asks once typing
    /// pauses, never per keystroke.
    func canRun(_ document: IDERunDocument) -> Bool
    /// Debugging is available in this project (cheap: asked on every toolbar redraw).
    func canDebug(fileURL: URL?) -> Bool
    /// Tooltips for the Run and Debug buttons (cheap: asked on every toolbar redraw).
    func runHelp(fileURL: URL?) -> String
    func debugHelp(fileURL: URL?, canRun: Bool) -> String

    /// The runnable places in `document` (a `main`, test methods, a test class), parsed from its text.
    func runnableLocations(in document: IDERunDocument) async -> [IDERunnableLocation]

    /// The play and bug buttons: what the active file runs by default.
    func run(_ document: IDERunDocument, mode: IDERunMode)
    /// The gutter's Run or Debug item for one ``IDERunnableLocation``. The default runs the whole
    /// document, which is what a language with no per-line launch does.
    func run(_ document: IDERunDocument, location: IDERunnableLocation, mode: IDERunMode)
    /// Whether the gutter menu offers Modify Run Configuration for `location`.
    func canEditRunConfiguration(_ location: IDERunnableLocation) -> Bool
    /// Opens the editor on the configuration that would launch `location`.
    func editRunConfiguration(_ document: IDERunDocument, location: IDERunnableLocation)
    /// ⌃⇧R and ⌃⇧D: what the caret is in. `false` when it is in nothing runnable, and the host
    /// repeats the last run instead, so the key is never dead.
    func runInContext(_ document: IDERunDocument, mode: IDERunMode) async -> Bool
    /// Runs the session again in its tab with the settings it has now.
    func rerun(_ session: IDERunSession)

    /// Something this provider started that is not a Run-tab session is still going (a Gradle task).
    var hasActiveWork: Bool { get }
    /// Stop: cancels what is starting or going.
    func stop()
    /// A project system's task run ended: pull compiler errors and test results out of it.
    func projectTasksDidFinish(_ report: IDEProjectTaskReport)
}

extension IDERunProvider {
    func projectTasksDidFinish(_ report: IDEProjectTaskReport) {}
    func runnableLocations(in document: IDERunDocument) async -> [IDERunnableLocation] { [] }
    func run(_ document: IDERunDocument, location: IDERunnableLocation, mode: IDERunMode) {
        run(document, mode: mode)
    }
    func canEditRunConfiguration(_ location: IDERunnableLocation) -> Bool { false }
    func editRunConfiguration(_ document: IDERunDocument, location: IDERunnableLocation) {}
}

/// The run providers of one window, found by language.
@MainActor
final class IDERunProviders {
    let providers: [any IDERunProvider]

    init(_ providers: [any IDERunProvider]) {
        self.providers = providers
    }

    func provider(forLanguage identifier: String?) -> (any IDERunProvider)? {
        guard let identifier else { return nil }
        return providers.first { $0.languageIdentifiers.contains(identifier) }
    }

    func provider(id: String) -> (any IDERunProvider)? {
        providers.first { $0.id == id }
    }

    func provider<Provider: IDERunProvider>(_ type: Provider.Type) -> Provider? {
        providers.lazy.compactMap { $0 as? Provider }.first
    }

    var hasActiveWork: Bool { providers.contains { $0.hasActiveWork } }

    func stopAll() {
        for provider in providers { provider.stop() }
    }

    func projectTasksDidFinish(_ report: IDEProjectTaskReport) {
        for provider in providers { provider.projectTasksDidFinish(report) }
    }
}
