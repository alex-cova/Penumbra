import Foundation
import JavaIntelligence

/// What a breakpoint stops on: a line of a file, a thrown exception, entry into a method, or
/// access to or modification of a field.
enum JavaBreakpointKind: Codable, Equatable, Hashable, Sendable {
    case line
    /// `className` empty means any exception.
    case exception(className: String, caught: Bool, uncaught: Bool)
    case method(className: String, methodName: String)
    case field(className: String, fieldName: String, access: Bool, modification: Bool)
}

/// What a hit suspends (IntelliJ's Suspend checkbox and its All / Thread choice).
enum JavaBreakpointSuspendPolicy: String, Codable, CaseIterable, Sendable {
    case all
    case thread
    /// Suspend off: the breakpoint only logs.
    case none
}

/// A breakpoint (1-based line numbers, matching the editor gutter).
struct JavaBreakpoint: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    /// The source file of a line breakpoint; empty for the other kinds.
    var filePath: String
    var line: Int
    var isEnabled: Bool
    var kind: JavaBreakpointKind
    /// A Java boolean expression; the breakpoint only stops when it is `true`.
    var condition: String?
    var suspendPolicy: JavaBreakpointSuspendPolicy
    /// Writes "Breakpoint reached at …" to the console on each hit.
    var logMessage: Bool
    /// An expression whose value is written to the console on each hit.
    var logExpression: String?
    var removeOnceHit: Bool
    /// Hits to let pass before stopping, once ("Disable until hit count").
    var passCount: Int?

    init(
        id: UUID = UUID(),
        filePath: String,
        line: Int,
        isEnabled: Bool = true,
        kind: JavaBreakpointKind = .line,
        condition: String? = nil,
        suspendPolicy: JavaBreakpointSuspendPolicy = .all,
        logMessage: Bool = false,
        logExpression: String? = nil,
        removeOnceHit: Bool = false,
        passCount: Int? = nil
    ) {
        self.id = id
        self.filePath = filePath
        self.line = line
        self.isEnabled = isEnabled
        self.kind = kind
        self.condition = condition
        self.suspendPolicy = suspendPolicy
        self.logMessage = logMessage
        self.logExpression = logExpression
        self.removeOnceHit = removeOnceHit
        self.passCount = passCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, filePath, line, isEnabled, kind, condition, suspendPolicy, logMessage, logExpression, removeOnceHit, passCount
    }

    /// Files written before conditions and kinds existed hold only id, file, line and enabled.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        line = try container.decodeIfPresent(Int.self, forKey: .line) ?? 0
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        kind = try container.decodeIfPresent(JavaBreakpointKind.self, forKey: .kind) ?? .line
        condition = try container.decodeIfPresent(String.self, forKey: .condition)
        suspendPolicy = try container.decodeIfPresent(JavaBreakpointSuspendPolicy.self, forKey: .suspendPolicy) ?? .all
        logMessage = try container.decodeIfPresent(Bool.self, forKey: .logMessage) ?? false
        logExpression = try container.decodeIfPresent(String.self, forKey: .logExpression)
        removeOnceHit = try container.decodeIfPresent(Bool.self, forKey: .removeOnceHit) ?? false
        passCount = try container.decodeIfPresent(Int.self, forKey: .passCount)
    }

    var isLineBreakpoint: Bool {
        kind == .line
    }

    /// A condition that is set and not blank.
    var activeCondition: String? {
        guard let condition = condition?.trimmingCharacters(in: .whitespacesAndNewlines), !condition.isEmpty else { return nil }
        return condition
    }

    var activeLogExpression: String? {
        guard let expression = logExpression?.trimmingCharacters(in: .whitespacesAndNewlines), !expression.isEmpty else { return nil }
        return expression
    }

    /// Anything beyond a plain stop: shown with a badge in the gutter and the list.
    var hasProperties: Bool {
        activeCondition != nil || suspendPolicy == .none || logMessage || activeLogExpression != nil || removeOnceHit || passCount != nil
    }

    /// The row title in the Breakpoints tab.
    var title: String {
        switch kind {
        case .line:
            return "\((filePath as NSString).lastPathComponent):\(line)"
        case .exception(let className, _, _):
            return className.isEmpty ? "Any exception" : Self.simpleName(className)
        case .method(let className, let methodName):
            return "\(Self.simpleName(className)).\(methodName)()"
        case .field(let className, let fieldName, _, _):
            return "\(Self.simpleName(className)).\(fieldName)"
        }
    }

    private static func simpleName(_ className: String) -> String {
        String(className.split(separator: ".").last ?? Substring(className)).replacingOccurrences(of: "$", with: ".")
    }
}

/// Persists breakpoints per project root, and whether the project's breakpoints are muted.
final class JavaBreakpointStore: @unchecked Sendable {
    private struct File: Codable {
        var breakpoints: [JavaBreakpoint] = []
        var isMuted = false

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            breakpoints = try container.decodeIfPresent([JavaBreakpoint].self, forKey: .breakpoints) ?? []
            isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        }
    }

    private let storeURL: URL
    private let lock = NSLock()
    private var projects: [String: File]
    private var stamp: FileChangeStamp

    init(storeURL: URL) {
        self.storeURL = storeURL
        projects = Self.load(storeURL) ?? [:]
        stamp = FileChangeStamp(url: storeURL)
    }

    private static func load(_ url: URL) -> [String: File]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: File].self, from: data)
    }

    /// Picks up what another window's store or another process wrote since this one read the file,
    /// so a write here does not drop it. A file that cannot be read keeps what is in memory.
    /// Caller must hold `lock`.
    private func reloadIfChangedOnDisk() {
        guard stamp.hasChanged(at: storeURL) else { return }
        stamp.update(at: storeURL)
        if let loaded = Self.load(storeURL) {
            projects = loaded
        }
    }

    func breakpoints(forProject root: URL?) -> [JavaBreakpoint] {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        return projects[key(for: root)]?.breakpoints ?? []
    }

    func breakpoints(forFile url: URL, project root: URL?) -> [JavaBreakpoint] {
        let path = url.standardizedFileURL.path
        return breakpoints(forProject: root).filter { $0.isLineBreakpoint && $0.filePath == path }
    }

    func breakpoint(id: UUID, project root: URL?) -> JavaBreakpoint? {
        breakpoints(forProject: root).first { $0.id == id }
    }

    /// Adds a line breakpoint on `line`, or removes the one there.
    @discardableResult
    func toggle(atLine line: Int, file url: URL, project root: URL?) -> JavaBreakpoint? {
        let path = url.standardizedFileURL.path
        var added: JavaBreakpoint?
        mutate(root) { entry in
            if let index = entry.breakpoints.firstIndex(where: { $0.isLineBreakpoint && $0.filePath == path && $0.line == line }) {
                entry.breakpoints.remove(at: index)
            } else {
                let breakpoint = JavaBreakpoint(filePath: path, line: line)
                entry.breakpoints.append(breakpoint)
                added = breakpoint
            }
        }
        return added
    }

    func add(_ breakpoint: JavaBreakpoint, project root: URL?) {
        mutate(root) { $0.breakpoints.append(breakpoint) }
    }

    /// Replaces the breakpoint with the same id.
    func update(_ breakpoint: JavaBreakpoint, project root: URL?) {
        mutate(root) { entry in
            guard let index = entry.breakpoints.firstIndex(where: { $0.id == breakpoint.id }) else { return }
            entry.breakpoints[index] = breakpoint
        }
    }

    func setEnabled(_ enabled: Bool, breakpointID: UUID, project root: URL?) {
        mutate(root) { entry in
            guard let index = entry.breakpoints.firstIndex(where: { $0.id == breakpointID }) else { return }
            entry.breakpoints[index].isEnabled = enabled
        }
    }

    /// Puts the file's line breakpoints on the lines the editor moved them to (`lines` by id), and
    /// removes `removed` (their lines were deleted). Writes only when something changed.
    @discardableResult
    func moveLines(in url: URL, to lines: [UUID: Int], removing removed: Set<UUID>, project root: URL?) -> Bool {
        let path = url.standardizedFileURL.path
        var changed = false
        mutate(root, persistOnlyIf: { changed }) { entry in
            let before = entry.breakpoints.count
            entry.breakpoints.removeAll { removed.contains($0.id) }
            changed = entry.breakpoints.count != before
            for index in entry.breakpoints.indices {
                let breakpoint = entry.breakpoints[index]
                guard breakpoint.isLineBreakpoint, breakpoint.filePath == path,
                      let line = lines[breakpoint.id], line != breakpoint.line else { continue }
                entry.breakpoints[index].line = line
                changed = true
            }
        }
        return changed
    }

    func remove(breakpointID: UUID, project root: URL?) {
        mutate(root) { $0.breakpoints.removeAll { $0.id == breakpointID } }
    }

    func removeAll(project root: URL?) {
        mutate(root) { $0.breakpoints = [] }
    }

    func isMuted(project root: URL?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        return projects[key(for: root)]?.isMuted ?? false
    }

    func setMuted(_ muted: Bool, project root: URL?) {
        mutate(root) { $0.isMuted = muted }
    }

    private func mutate(_ root: URL?, persistOnlyIf shouldPersist: (() -> Bool)? = nil, _ change: (inout File) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        var entry = projects[key(for: root)] ?? File()
        change(&entry)
        if let shouldPersist, !shouldPersist() { return }
        projects[key(for: root)] = entry
        persist()
    }

    static var defaultStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("breakpoints.json")
    }

    private func key(for root: URL?) -> String {
        root?.standardizedFileURL.path ?? ""
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
        stamp.update(at: storeURL)
    }
}

extension JavaBreakpoint {
    /// The adapter's `setBreakpoint` request for this breakpoint.
    func adapterRequest(imports: [String]) -> [String: Any] {
        var request: [String: Any] = [
            "command": "setBreakpoint",
            "breakpointId": id.uuidString,
            "suspendPolicy": suspendPolicy.rawValue,
            "logMessage": logMessage,
            "removeOnceHit": removeOnceHit
        ]
        switch kind {
        case .line:
            request["kind"] = "line"
            request["file"] = filePath
            request["line"] = line
        case .exception(let className, let caught, let uncaught):
            request["kind"] = "exception"
            request["className"] = className
            request["caught"] = caught
            request["uncaught"] = uncaught
        case .method(let className, let methodName):
            request["kind"] = "method"
            request["className"] = className
            request["methodName"] = methodName
        case .field(let className, let fieldName, let access, let modification):
            request["kind"] = "field"
            request["className"] = className
            request["fieldName"] = fieldName
            request["access"] = access
            request["modification"] = modification
        }
        if let condition = activeCondition { request["condition"] = condition }
        if let expression = activeLogExpression { request["logExpression"] = expression }
        if let passCount, passCount > 0 { request["passCount"] = passCount }
        if !imports.isEmpty { request["imports"] = imports }
        return request
    }
}
