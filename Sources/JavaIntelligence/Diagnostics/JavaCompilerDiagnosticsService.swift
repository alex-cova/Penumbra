import Foundation
import EditorIntelligence

/// Compiler-backed diagnostics for Java: runs `javac` over the editor's text with the project's
/// synced classpath and turns its messages into ``Diagnostic``s.
///
/// The engine only *pulls* diagnostics, but a compile takes far longer than a keystroke, so
/// ``diagnostics(for:)`` returns what it has -- the last result for that file -- and starts a
/// compile in the background; when one finishes, ``setResultHandler(_:)``'s handler tells the host
/// to refresh. Results are keyed by a hash of the compiled text, so refreshes that see unchanged
/// text neither recompile nor reset the idle timer.
///
/// Nothing runs until the host calls ``configure(_:)``, which is where trust and the user's
/// preference are decided.
public actor JavaCompilerDiagnosticsService: DiagnosticProvider {
    public struct Configuration: Sendable {
        public let kind: JavacProjectKind
        public let jdk: JDKInstallation
        public let projectRoot: URL
        /// Scratch space for buffer copies and compiler output; each compile uses (and removes)
        /// its own subdirectory.
        public let workDirectory: URL

        public init(kind: JavacProjectKind, jdk: JDKInstallation, projectRoot: URL, workDirectory: URL) {
            self.kind = kind
            self.jdk = jdk
            self.projectRoot = projectRoot
            self.workDirectory = workDirectory
        }
    }

    public nonisolated let name = "javac"

    private let launcher: GradleProcessLaunching
    private let idleDelay: Duration
    private let timeout: Duration
    private let maxConcurrentCompiles: Int

    private var configuration: Configuration?
    /// Bumped by ``configure(_:)`` and ``reset()`` so a compile that outlives its project never
    /// stores or delivers anything.
    private var generation = 0
    private var cache: [URL: CachedResult] = [:]
    private var pending: [URL: PendingCompile] = [:]
    private var resultHandler: (@Sendable (URL, [Diagnostic]) -> Void)?

    private var activeCompiles = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    private struct CachedResult {
        let textHash: Int
        let diagnostics: [Diagnostic]
    }

    private struct PendingCompile {
        let textHash: Int
        let task: Task<Void, Never>
    }

    public init(
        launcher: GradleProcessLaunching = SystemGradleProcessLauncher(),
        idleDelay: Duration = .milliseconds(600),
        timeout: Duration = .seconds(30),
        maxConcurrentCompiles: Int = 2
    ) {
        self.launcher = launcher
        self.idleDelay = idleDelay
        self.timeout = timeout
        self.maxConcurrentCompiles = max(1, maxConcurrentCompiles)
    }

    // MARK: - Configuration

    /// Points the service at a project, or turns it off with `nil`. Drops every cached result and
    /// cancels every compile in flight.
    public func configure(_ configuration: Configuration?) {
        reset()
        self.configuration = configuration
    }

    /// Forgets everything and stops compiling until ``configure(_:)`` is called again.
    public func reset() {
        generation += 1
        for compile in pending.values { compile.task.cancel() }
        pending = [:]
        cache = [:]
        configuration = nil
    }

    public var isEnabled: Bool { configuration != nil }

    /// Called (off the main actor) with each finished compile's diagnostics for one file, an empty
    /// array meaning the file is clean.
    public func setResultHandler(_ handler: (@Sendable (URL, [Diagnostic]) -> Void)?) {
        resultHandler = handler
    }

    // MARK: - DiagnosticProvider

    public func diagnostics(for document: Document) async -> [Diagnostic] {
        guard let url = compilableURL(for: document) else { return [] }
        let hash = document.text.hashValue
        if let cached = cache[url], cached.textHash == hash { return cached.diagnostics }
        schedule(url: url, text: document.text, textHash: hash, delay: idleDelay)
        return cache[url]?.diagnostics ?? []
    }

    /// Compiles now, skipping the idle wait -- for a save, or right after a sync -- unless the
    /// result for this exact text is already cached. `force` recompiles regardless: a file that
    /// didn't change can still break when a file it depends on does.
    public func compileNow(_ document: Document, force: Bool = false) {
        guard let url = compilableURL(for: document) else { return }
        let hash = document.text.hashValue
        if !force, let cached = cache[url], cached.textHash == hash { return }
        schedule(url: url, text: document.text, textHash: hash, delay: .zero)
    }

    private func compilableURL(for document: Document) -> URL? {
        guard configuration != nil,
              document.languageIdentifier == "java",
              let url = document.url,
              !document.contentSnapshot.isElided else { return nil }
        return url.standardizedFileURL
    }

    // MARK: - Scheduling

    private func schedule(url: URL, text: String, textHash: Int, delay: Duration) {
        if let existing = pending[url] {
            // Same text already waiting (or compiling): leave it alone, so a refresh that changed
            // nothing doesn't push the idle deadline back. A different text supersedes it, and
            // cancelling kills the running `javac`.
            if existing.textHash == textHash && delay != .zero { return }
            existing.task.cancel()
        }
        let currentGeneration = generation
        let task = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self else { return }
            await self.compile(url: url, text: text, textHash: textHash, generation: currentGeneration)
        }
        pending[url] = PendingCompile(textHash: textHash, task: task)
    }

    private func compile(url: URL, text: String, textHash: Int, generation compileGeneration: Int) async {
        await acquireSlot()
        defer { releaseSlot() }
        guard !Task.isCancelled, compileGeneration == generation, let configuration else { return }

        let workDirectory = configuration.workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        var result: [Diagnostic]?
        if let invocation = JavacInvocationBuilder.build(
            file: url, text: text, kind: configuration.kind, jdk: configuration.jdk, workDirectory: workDirectory
        ) {
            result = await run(invocation, url: url, text: text, in: configuration)
        } else {
            // Nothing meaningful to check (file outside every source set, JDK without javac).
            result = []
        }

        guard !Task.isCancelled, compileGeneration == generation else { return }
        // Done with this text, whatever came out: a failed run must not block a retry.
        if pending[url]?.textHash == textHash { pending[url] = nil }
        guard let result else { return }
        cache[url] = CachedResult(textHash: textHash, diagnostics: result)
        resultHandler?(url, result)
    }

    /// `nil` when the run produced nothing usable (couldn't launch, timed out, killed): the last
    /// good result then stays in place rather than being replaced by a false "clean".
    private func run(_ invocation: JavacInvocation, url: URL, text: String, in configuration: Configuration) async -> [Diagnostic]? {
        do {
            try FileManager.default.createDirectory(at: invocation.bufferFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: invocation.bufferFile, atomically: false, encoding: .utf8)
            let output = try await launcher.launch(
                GradleCommand(
                    executable: invocation.executable,
                    arguments: invocation.arguments,
                    currentDirectory: configuration.projectRoot,
                    environment: invocation.environment
                ),
                timeout: timeout,
                output: nil
            )
            let messages = JavacOutputParser.parse(output.stderr)
            // `javac` exits 0 (clean) or 1 (errors); anything else with no messages is a failed
            // invocation, not a clean file.
            if messages.isEmpty, output.exitCode != 0, output.exitCode != 1 { return nil }
            return Self.diagnostics(from: messages, compiledFile: invocation.bufferFile, text: text)
        } catch {
            return nil
        }
    }

    // MARK: - Concurrency limit

    private func acquireSlot() async {
        if activeCompiles < maxConcurrentCompiles {
            activeCompiles += 1
            return
        }
        await withCheckedContinuation { slotWaiters.append($0) }
    }

    private func releaseSlot() {
        if slotWaiters.isEmpty {
            activeCompiles -= 1
        } else {
            slotWaiters.removeFirst().resume()
        }
    }

    // MARK: - Mapping

    /// Maps `javac` messages about `compiledFile` (and file-less errors) onto positions in `text`.
    /// Messages about other files are dropped: they are reported when those files are compiled.
    static func diagnostics(from messages: [JavacMessage], compiledFile: URL, text: String) -> [Diagnostic] {
        let lines = LineTable(text)
        var result: [Diagnostic] = []
        for message in messages {
            let lineIndex: Int
            if let file = message.file {
                guard Self.isSameFile(file, compiledFile) else { continue }
                lineIndex = message.line - 1
            } else {
                // A message with no file is about the compilation as a whole; only errors matter,
                // and they are pinned to the top of the file.
                guard message.severity == .error else { continue }
                lineIndex = 0
            }
            let (start, end) = lines.range(line: lineIndex, column: message.column)
            let startPosition = lines.position(atOffset: start)
            let endPosition = lines.position(atOffset: end)
            let (text, code) = splitCategory(message.message)
            result.append(Diagnostic(
                severity: message.severity == .error ? .error : .warning,
                message: text,
                range: TextRange(start: startPosition, end: endPosition),
                source: "javac",
                code: code
            ))
        }
        return result
    }

    /// `javac` prints a path as it was given, while the URL may have collapsed a doubled slash or
    /// sit behind a symlink (`/var` -> `/private/var`), so compare resolved paths.
    private static func isSameFile(_ printed: String, _ compiledFile: URL) -> Bool {
        if printed == compiledFile.path { return true }
        return URL(fileURLWithPath: printed).resolvingSymlinksInPath().path
            == compiledFile.resolvingSymlinksInPath().path
    }

    /// `[deprecation] foo() is deprecated` -> ("foo() is deprecated", "deprecation").
    private static func splitCategory(_ message: String) -> (String, String?) {
        guard message.hasPrefix("["), let close = message.firstIndex(of: "]") else { return (message, nil) }
        let code = String(message[message.index(after: message.startIndex)..<close])
        let rest = message[message.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty, !rest.isEmpty, !code.contains(" ") else { return (message, nil) }
        return (rest, code)
    }
}

/// Line starts of a text, in UTF-16 offsets. Lines end at `\n`, `\r\n` or `\r`, as `javac` counts
/// them.
struct LineTable {
    private let utf16: [UInt16]
    private let lineStarts: [Int]

    init(_ text: String) {
        let units = Array(text.utf16)
        var starts = [0]
        var index = 0
        while index < units.count {
            let unit = units[index]
            index += 1
            if unit == 0x0A {
                starts.append(index)
            } else if unit == 0x0D {
                if index < units.count, units[index] == 0x0A { index += 1 }
                starts.append(index)
            }
        }
        self.utf16 = units
        self.lineStarts = starts
    }

    private func lineEnd(_ line: Int) -> Int {
        var end = lineStarts[line]
        while end < utf16.count, utf16[end] != 0x0A, utf16[end] != 0x0D { end += 1 }
        return end
    }

    /// The range to underline. With a column: the identifier starting there, else one character
    /// (stepping back onto the previous character when the column is at the line's end, as for
    /// "';' expected"). Without one: the line, minus its indentation.
    func range(line requestedLine: Int, column: Int?) -> (start: Int, end: Int) {
        let line = min(max(0, requestedLine), lineStarts.count - 1)
        let lineStart = lineStarts[line]
        let lineEnd = lineEnd(line)

        guard let column else {
            var start = lineStart
            while start < lineEnd, utf16[start] == 0x20 || utf16[start] == 0x09 { start += 1 }
            return (start, lineEnd)
        }

        var start = min(lineStart + column, lineEnd)
        var end = start
        while end < lineEnd, Self.isIdentifierUnit(utf16[end]) { end += 1 }
        if end == start, end < lineEnd { end += 1 }
        if end == start, start > lineStart { start -= 1 }
        return (start, end)
    }

    func position(atOffset offset: Int) -> TextPosition {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return TextPosition(line: low, column: offset - lineStarts[low], utf16Offset: offset)
    }

    private static func isIdentifierUnit(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x24: return true
        default: return unit > 0x7F
        }
    }
}
