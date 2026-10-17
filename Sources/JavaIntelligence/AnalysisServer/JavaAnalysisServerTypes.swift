import EditorIntelligence
import Foundation

/// Configuration for one ``JavaAnalysisServerClient``: where the server jar lives and which
/// `java` runs it. The host app injects both — the library ships no jar and picks no JDK.
public struct JavaAnalysisServerConfiguration: Sendable {
    /// The `java-analysis-server.jar` built by `Example/Umbra/Tools/JavaAnalysisServer/build.sh`.
    public let jarURL: URL
    /// The JDK's `bin/java` executable. The server needs a JDK 17 or newer.
    public let javaExecutable: URL
    /// `-Xmx` for the server. It holds one file manager per configured module, so this bounds
    /// how many modules stay warm.
    public let maxHeapMB: Int

    public init(jarURL: URL, javaExecutable: URL, maxHeapMB: Int = 512) {
        self.jarURL = jarURL
        self.javaExecutable = javaExecutable
        self.maxHeapMB = maxHeapMB
    }
}

/// The module scope of a `configure` call, mirroring the server's `configure` params.
public struct JavaAnalysisServerModule: Sendable, Equatable {
    public let moduleId: String
    public let classpath: [URL]
    public let sourcepath: [URL]
    /// `--release` value (the module's language level), or `nil` for the running JDK's default.
    public let release: Int?
    /// Annotation processor jars (Lombok). Empty means `-proc:none`.
    public let processorPath: [URL]
    public let options: [String]

    public init(
        moduleId: String,
        classpath: [URL] = [],
        sourcepath: [URL] = [],
        release: Int? = nil,
        processorPath: [URL] = [],
        options: [String] = []
    ) {
        self.moduleId = moduleId
        self.classpath = classpath
        self.sourcepath = sourcepath
        self.release = release
        self.processorPath = processorPath
        self.options = options
    }
}

/// One diagnostic from the server's `check`.
///
/// `start`/`end` are UTF-16 code-unit offsets into the buffer text the diagnostic is about
/// (`nil` when `javac` reports no position). `line`/`column` are the 1-based line and 0-based
/// column of the diagnostic's preferred position — the line the CLI prints, which is not always
/// the line `start` sits on. `file` is the path `javac` attributed the diagnostic to, which may
/// be another file than the one checked.
public struct JavaAnalysisServerDiagnostic: Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable {
        case error
        case warning
    }

    /// `Diagnostic.getCode()`, e.g. `compiler.err.cant.resolve.location`.
    public let key: String
    public let severity: Severity
    public let start: Int?
    public let end: Int?
    public let line: Int?
    public let column: Int?
    public let file: String?
    /// `Diagnostic.getMessage(Locale.ENGLISH)`.
    public let message: String

    public init(key: String, severity: Severity, start: Int?, end: Int?, line: Int?, column: Int?, file: String?, message: String) {
        self.key = key
        self.severity = severity
        self.start = start
        self.end = end
        self.line = line
        self.column = column
        self.file = file
        self.message = message
    }

    /// The editor-facing code, so the Phase 2 quick fixes (keyed on `javac:<key>`) serve the
    /// native checks later too.
    public var diagnosticCode: String { "javac:\(key)" }

    /// This diagnostic as an editor `Diagnostic` over `text`, or `nil` when it has no usable
    /// position.
    public func diagnostic(in text: String, source: String = "javac") -> Diagnostic? {
        guard let start, let end else { return nil }
        let lines = LineTable(text)
        let startPosition = lines.position(atOffset: min(max(0, start), text.utf16.count))
        let endPosition = lines.position(atOffset: min(max(start, end), text.utf16.count))
        return Diagnostic(
            severity: severity == .error ? .error : .warning,
            message: message,
            range: TextRange(start: startPosition, end: endPosition),
            source: source,
            code: diagnosticCode
        )
    }
}

/// An unsaved buffer that shadows the file on disk for one `check`.
public struct JavaAnalysisServerOverlay: Sendable {
    public let file: URL
    public let text: String

    public init(file: URL, text: String) {
        self.file = file
        self.text = text
    }
}

public enum JavaAnalysisServerError: Error, Sendable, Equatable {
    /// The server answered with an `error` (bad options, unknown module, failed compile setup).
    case serverError(String)
    case launchFailed(String)
    /// The server exited mid-request. The next request relaunches it.
    case terminated(String)
    case cancelled
}
