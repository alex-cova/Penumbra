import Foundation

/// Which producer a diagnostic came from. An editor report and a build can both speak for one file;
/// they stay in separate buckets.
public struct DiagnosticSourceID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let javac = DiagnosticSourceID(rawValue: "javac")
    public static let javaInspection = DiagnosticSourceID(rawValue: "java-inspection")
    public static let gradle = DiagnosticSourceID(rawValue: "gradle")
    public static let swiftPM = DiagnosticSourceID(rawValue: "swiftpm")
    public static let sourceKitLSP = DiagnosticSourceID(rawValue: "sourcekit-lsp")
    public static let typeScriptLSP = DiagnosticSourceID(rawValue: "typescript-lsp")
}

/// A push of diagnostics for one file from one source. An empty `diagnostics` clears that source.
public struct DiagnosticPublication: Sendable {
    public var source: DiagnosticSourceID
    public var url: URL
    public var documentVersion: Int?
    public var diagnostics: [Diagnostic]

    public init(source: DiagnosticSourceID, url: URL, documentVersion: Int? = nil, diagnostics: [Diagnostic]) {
        self.source = source
        self.url = url
        self.documentVersion = documentVersion
        self.diagnostics = diagnostics
    }
}

/// Something a language may only do with the user's agreement (decompiling class files, running a
/// build script). The host decides how to ask and remembers the answer.
public struct ConsentTopic: Hashable, Sendable, ExpressibleByStringLiteral {
    public let id: String

    public init(_ id: String) {
        self.id = id
    }

    public init(stringLiteral value: String) {
        id = value
    }
}

/// What a ``LanguageService`` reads from the host instead of the host pushing it into each provider
/// one setter at a time. Handed to ``LanguageService/start(environment:)`` once, when the editor
/// window starts, and valid until ``LanguageService/stop()``.
///
/// Every member is a closure, so a service never holds the host: the closures capture it weakly,
/// and ``LanguageServiceRegistry/stop()`` lets a service drop them before the window closes.
public struct LanguageEnvironment: Sendable {
    /// The text of `url` as the user has it open, unsaved edits included; nil when the file is not
    /// open, in which case the service reads the disk.
    public var openBufferText: @Sendable (URL) async -> String?
    /// One level of indentation (`"    "` or `"\t"`), asked for each time code is generated or
    /// formatted so a change to the editor's tab settings applies to the next one.
    public var indentUnit: @Sendable () async -> String
    /// Whether the user has already agreed to `topic`. Never prompts.
    public var hasConsent: @Sendable (ConsentTopic) async -> Bool
    /// Asks the user to agree to `topic` (showing whatever UI the host has), remembers a yes, and
    /// returns the answer. Only for an explicit user action, never from a background request.
    public var requestConsent: @Sendable (ConsentTopic) async -> Bool
    /// Pushed diagnostics from a language service or a build. The default drops them. An empty
    /// `diagnostics` array clears that source for the file.
    public var publishDiagnostics: @Sendable (DiagnosticPublication) -> Void

    public init(
        openBufferText: @escaping @Sendable (URL) async -> String? = { _ in nil },
        indentUnit: @escaping @Sendable () async -> String = { "    " },
        hasConsent: @escaping @Sendable (ConsentTopic) async -> Bool = { _ in false },
        requestConsent: @escaping @Sendable (ConsentTopic) async -> Bool = { _ in false },
        publishDiagnostics: @escaping @Sendable (DiagnosticPublication) -> Void = { _ in }
    ) {
        self.openBufferText = openBufferText
        self.indentUnit = indentUnit
        self.hasConsent = hasConsent
        self.requestConsent = requestConsent
        self.publishDiagnostics = publishDiagnostics
    }
}
