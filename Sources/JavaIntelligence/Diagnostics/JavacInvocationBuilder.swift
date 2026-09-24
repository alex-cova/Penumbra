import Foundation

/// What kind of project a file belongs to, which decides its classpath and source path.
public enum JavacProjectKind: Sendable {
    /// A folder with no build tool: no classpath, and the source path is the package root inferred
    /// from the file's `package` declaration.
    case plainFolder
    /// A synced Gradle project: the file's source set gives the classpath and source path.
    case gradle(JavaGradleProjectModel)
}

/// A fully-built `javac` command for one file, plus where the caller must write the buffer text.
public struct JavacInvocation: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    /// The file `javac` is told to compile. It holds the editor's (possibly unsaved) text, so the
    /// caller writes the buffer here before launching, and messages about this path belong to the
    /// original file.
    public let bufferFile: URL
}

/// Builds `javac` command lines that check one file against a project's classpath, without
/// producing usable output and without running annotation processors -- except Lombok, which the
/// project's own classpath ships and which would otherwise turn every generated getter into a
/// false error.
public enum JavacInvocationBuilder {
    /// - Returns: `nil` when the file can't be checked meaningfully: the JDK has no `javac`, or a
    ///   Gradle file lies outside every source set (so compiling it would only produce noise).
    public static func build(
        file: URL,
        text: String,
        kind: JavacProjectKind,
        jdk: JDKInstallation,
        workDirectory: URL
    ) -> JavacInvocation? {
        guard let javac = jdk.javac else { return nil }

        let packageName = packageDeclaration(in: text)
        let packagePath = packageName?.replacingOccurrences(of: ".", with: "/") ?? ""
        let bufferFile = workDirectory
            .appendingPathComponent("src", isDirectory: true)
            .appendingPathComponent(packagePath, isDirectory: true)
            .appendingPathComponent(file.lastPathComponent)

        var classpath: [URL] = []
        var sourcepath: [URL] = []
        var languageLevel: Int?

        switch kind {
        case .plainFolder:
            sourcepath = [sourceRoot(for: file, packageName: packageName)]
        case .gradle(let model):
            guard let match = model.sourceSet(containing: file) else { return nil }
            classpath = match.sourceSet.compileClasspathJars
            languageLevel = match.subproject.languageLevel
            sourcepath = match.sourceSet.sourceDirs
            // Test (and other) source sets see their module's main classes.
            if match.sourceSet.name != "main",
               let main = match.subproject.sourceSets.first(where: { $0.name == "main" }) {
                sourcepath += main.sourceDirs
            }
            for dependency in match.sourceSet.projectDependencies {
                guard let target = model.subprojects.first(where: { $0.path == dependency.projectPath }) else { continue }
                let set = target.sourceSets.first { $0.name == dependency.sourceSetName }
                    ?? target.sourceSets.first { $0.name == "main" }
                if let set { sourcepath += set.sourceDirs }
            }
        }

        var arguments = [
            // Compiler messages are localized; the parser reads the English ones.
            "-J-Duser.language=en", "-J-Duser.country=US",
            "-encoding", "UTF-8",
            "-Xmaxerrs", "200", "-Xmaxwarns", "200",
            "-implicit:none",
            // Stop after flow analysis: every error a user can fix, no class generation.
            "-XDshould-stop.at=FLOW", "-XDshouldStopPolicyIfNoError=FLOW",
            "-d", workDirectory.appendingPathComponent("classes", isDirectory: true).path,
        ]
        if let release = release(languageLevel: languageLevel, jdkFeatureVersion: jdk.featureVersion) {
            arguments += ["--release", String(release)]
        }
        let classpathJars = unique(classpath)
        if !classpathJars.isEmpty {
            arguments += ["-classpath", classpathJars.map(\.path).joined(separator: ":")]
        }
        let sourceDirs = unique(sourcepath)
        if !sourceDirs.isEmpty {
            arguments += ["-sourcepath", sourceDirs.map(\.path).joined(separator: ":")]
        }
        if case .gradle = kind, let lombok = classpathJars.first(where: isLombok) {
            arguments += ["-processorpath", lombok.path]
        } else {
            arguments.append("-proc:none")
        }
        arguments.append(bufferFile.path)

        return JavacInvocation(
            executable: javac,
            arguments: arguments,
            environment: ["JAVA_HOME": jdk.home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            bufferFile: bufferFile
        )
    }

    /// `--release N`, capped at what the JDK supports. Omitted when unknown, or on a JDK 8 (whose
    /// `javac` has no `--release`) or below level 8 (which current JDKs no longer accept).
    static func release(languageLevel: Int?, jdkFeatureVersion: Int) -> Int? {
        guard let languageLevel, languageLevel >= 8, jdkFeatureVersion >= 9 else { return nil }
        return min(languageLevel, jdkFeatureVersion)
    }

    static func isLombok(_ jar: URL) -> Bool {
        jar.pathExtension.lowercased() == "jar" && jar.lastPathComponent.lowercased().hasPrefix("lombok")
    }

    private static let packagePattern = try! NSRegularExpression(pattern: #"^\s*package\s+([\w.]+)\s*;"#, options: [.anchorsMatchLines])

    /// The `package` declared in `text`, or `nil` for the unnamed package.
    static func packageDeclaration(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = packagePattern.firstMatch(in: text, range: range),
              let name = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[name])
    }

    /// The directory the package hierarchy hangs from: the file's directory with the package's
    /// trailing path components removed, or the directory itself when it doesn't follow them.
    static func sourceRoot(for file: URL, packageName: String?) -> URL {
        var directory = file.deletingLastPathComponent().standardizedFileURL
        guard let packageName else { return directory }
        for component in packageName.split(separator: ".").reversed() {
            guard directory.lastPathComponent == component else {
                return file.deletingLastPathComponent().standardizedFileURL
            }
            directory = directory.deletingLastPathComponent()
        }
        return directory
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
