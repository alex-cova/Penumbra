import Foundation

/// Finds installed JDKs on disk, the equivalent of `SdkEntity`/`Sdk.getRootProvider()` root
/// discovery in the handoff doc, minus any IDE project-model integration (there is none here --
/// this is a from-scratch macOS app, not a plugin inside an existing SDK-aware host).
///
/// Search order (first match per source; all sources are merged and deduplicated by `home`):
/// 1. `$JAVA_HOME`
/// 2. `/usr/libexec/java_home -X` (every registered JVM on macOS)
/// 3. `~/Library/Java/JavaVirtualMachines`, `/Library/Java/JavaVirtualMachines`
/// 4. `~/.sdkman/candidates/java/*`, `~/.gradle/jdks/*`
/// 5. Homebrew (`openjdk*` formulae) and the asdf, jenv and mise version managers
/// 6. Homes the user added by hand (`additionalHomes`)
public struct JDKLocator: Sendable {
    private var fileManager: FileManager { .default }
    private let environment: [String: String]
    private let processRunner: ProcessRunning

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, processRunner: ProcessRunning = SystemProcessRunner()) {
        self.environment = environment
        self.processRunner = processRunner
    }

    /// All discovered JDKs, deduplicated by install path, newest first.
    public func discoverAll(additionalHomes: [URL] = []) -> [JDKInstallation] {
        var seen = Set<URL>()
        var result: [JDKInstallation] = []

        func add(_ home: URL) {
            let resolved = home.resolvingSymlinksInPath()
            guard !seen.contains(resolved) else { return }
            seen.insert(resolved)
            if let installation = ReleaseFileParser.parse(resolved) {
                result.append(installation)
            }
        }

        if let javaHome = environment["JAVA_HOME"], !javaHome.isEmpty {
            add(URL(fileURLWithPath: javaHome))
        }

        for home in javaHomeRegisteredJVMs() {
            add(home)
        }

        for base in candidateVMDirectories() {
            for entry in contentsHomes(under: base) {
                add(entry)
            }
        }

        let userHome = fileManager.homeDirectoryForCurrentUser
        for base in [
            userHome.appendingPathComponent(".sdkman/candidates/java"),
            userHome.appendingPathComponent(".gradle/jdks"),
            userHome.appendingPathComponent(".asdf/installs/java"),
            userHome.appendingPathComponent(".jenv/versions"),
            userHome.appendingPathComponent(".local/share/mise/installs/java")
        ] {
            for entry in directChildDirectories(of: base) {
                add(entry)
            }
        }

        // Homebrew's `openjdk*` formulae are linked under `opt/<formula>/libexec/openjdk.jdk`, and
        // an unlinked one is not registered with `java_home`.
        for prefix in ["/opt/homebrew/opt", "/usr/local/opt"] {
            let opt = URL(fileURLWithPath: prefix)
            for formula in directChildDirectories(of: opt) where formula.lastPathComponent.hasPrefix("openjdk") {
                add(formula.appendingPathComponent("libexec/openjdk.jdk/Contents/Home"))
            }
        }

        for home in additionalHomes {
            add(home)
        }

        return result.sorted { $0.featureVersion > $1.featureVersion }
    }

    /// Picks the best JDK for a required minimum feature version: an explicit override always
    /// wins if valid; otherwise the closest installation at or above `minimumFeatureVersion`
    /// (preferring the smallest such version, to match the project's declared level rather than
    /// silently jumping to a much newer one); falls back to the newest installation available.
    public func select(preferring override: URL? = nil, minimumFeatureVersion: Int? = nil) -> JDKInstallation? {
        if let override, let installation = ReleaseFileParser.parse(override.resolvingSymlinksInPath()) {
            return installation
        }
        return Self.pick(from: discoverAll(), minimumFeatureVersion: minimumFeatureVersion)
    }

    /// Validates a folder the user picked and returns the JDK home inside it, or `nil` when it isn't
    /// one. Accepts the home itself, a `.jdk` bundle (`Contents/Home`), or a home's `bin` folder.
    public func installation(atUserSelected url: URL) -> JDKInstallation? {
        var candidates = [url]
        if url.lastPathComponent == "bin" {
            candidates.append(url.deletingLastPathComponent())
        }
        candidates.append(url.appendingPathComponent("Contents/Home"))
        for candidate in candidates {
            if let installation = ReleaseFileParser.parse(candidate.resolvingSymlinksInPath()) {
                return installation
            }
        }
        return nil
    }

    /// Applies the resolution order: the project's JDK, then the global default, then
    /// ``select(preferring:minimumFeatureVersion:)``'s automatic pick. A chosen path that no longer
    /// holds a JDK is skipped and reported in ``JDKResolution/staleSelection`` (the project's, else
    /// the default's), so the UI can say the saved JDK is gone. An explicit choice ignores
    /// `minimumFeatureVersion`.
    public func resolve(
        selection: JDKSelection,
        minimumFeatureVersion: Int? = nil,
        maximumFeatureVersion: Int? = nil,
        additionalHomes: [URL] = []
    ) -> JDKResolution? {
        var stale: URL?
        if let project = selection.project {
            if let installation = installation(atUserSelected: project) {
                return JDKResolution(installation: installation, source: .project, staleSelection: nil)
            }
            stale = project
        }
        if let global = selection.global {
            if let installation = installation(atUserSelected: global) {
                return JDKResolution(installation: installation, source: .global, staleSelection: stale)
            }
            stale = stale ?? global
        }
        guard let automatic = Self.pick(
            from: discoverAll(additionalHomes: additionalHomes),
            minimumFeatureVersion: minimumFeatureVersion,
            maximumFeatureVersion: maximumFeatureVersion
        ) else { return nil }
        return JDKResolution(installation: automatic, source: .automatic, staleSelection: stale)
    }

    /// The selection algorithm, factored out as a pure function so it's testable against synthetic
    /// installation lists without touching disk: the closest installation at or above
    /// `minimumFeatureVersion`, or the newest installation if none qualifies (or none was given).
    /// A `maximumFeatureVersion` drops newer installations first (a tool that cannot run on them),
    /// unless every installation is newer, in which case they all stay.
    static func pick(
        from allInstallations: [JDKInstallation], minimumFeatureVersion: Int?, maximumFeatureVersion: Int? = nil
    ) -> JDKInstallation? {
        var installations = allInstallations
        if let maximumFeatureVersion {
            let capped = installations.filter { $0.featureVersion <= maximumFeatureVersion }
            if !capped.isEmpty { installations = capped }
        }
        guard let minimumFeatureVersion else {
            return installations.max { $0.featureVersion < $1.featureVersion }
        }
        let atOrAbove = installations.filter { $0.featureVersion >= minimumFeatureVersion }
        if let best = atOrAbove.min(by: { $0.featureVersion < $1.featureVersion }) {
            return best
        }
        return installations.max { $0.featureVersion < $1.featureVersion }
    }

    // MARK: - Sources

    private func javaHomeRegisteredJVMs() -> [URL] {
        guard let output = try? processRunner.run(executable: "/usr/libexec/java_home", arguments: ["-X"]) else {
            return []
        }
        guard let data = output.data(using: .utf8) ?? output.data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]] else {
            return []
        }
        return plist.compactMap { entry in
            guard let path = entry["JVMHomePath"] as? String else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    private func candidateVMDirectories() -> [URL] {
        [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Java/JavaVirtualMachines"),
            URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines")
        ]
    }

    /// Each entry under a JavaVirtualMachines directory is a `.jdk` bundle whose real home is
    /// `Contents/Home`.
    private func contentsHomes(under base: URL) -> [URL] {
        directChildDirectories(of: base).map { $0.appendingPathComponent("Contents/Home") }
    }

    private func directChildDirectories(of directory: URL) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }
}

/// Abstraction over running a subprocess and capturing stdout, so `JDKLocator` (and later the
/// Gradle resolver) can be unit tested without actually invoking `/usr/libexec/java_home` or a
/// real build tool.
public protocol ProcessRunning: Sendable {
    func run(executable: String, arguments: [String], currentDirectory: URL?, environment: [String: String]?) throws -> String
}

public extension ProcessRunning {
    func run(executable: String, arguments: [String]) throws -> String {
        try run(executable: executable, arguments: arguments, currentDirectory: nil, environment: nil)
    }
}

public enum ProcessRunError: Error, Sendable {
    case executableNotFound(String)
    case nonZeroExit(Int32, stderr: String)
}

public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: String, arguments: [String], currentDirectory: URL?, environment: [String: String]?) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessRunError.executableNotFound(executable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment { process.environment = environment }
        // Same reason as `SystemGradleProcessLauncher`: an inherited terminal stdin makes some
        // tools (Gradle's client, anything that reads until EOF) block forever. This runner has
        // no timeout, so a hang here would stick for good. Callers today are `java_home -X` and
        // `command -v gradle`, which do not read stdin; closing it is still the safe default.
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProcessRunError.nonZeroExit(process.terminationStatus, stderr: String(data: errData, encoding: .utf8) ?? "")
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}

/// The JDKs the user picked: one for the open project and a default for every project. `nil`
/// means "Automatic".
public struct JDKSelection: Equatable, Sendable {
    public var project: URL?
    public var global: URL?

    public init(project: URL? = nil, global: URL? = nil) {
        self.project = project
        self.global = global
    }
}

/// The JDK chosen by ``JDKLocator/resolve(selection:minimumFeatureVersion:additionalHomes:)`` and
/// where the choice came from.
public struct JDKResolution: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case project
        case global
        case automatic
    }

    public let installation: JDKInstallation
    public let source: Source
    /// A chosen JDK that could not be used because its folder is gone or is no longer a JDK.
    public let staleSelection: URL?

    public init(installation: JDKInstallation, source: Source, staleSelection: URL?) {
        self.installation = installation
        self.source = source
        self.staleSelection = staleSelection
    }
}
