import Foundation

/// What a coverage run measures: which packages to instrument and which class directories to
/// report on, worked out from the project's Gradle model.
public struct JavaCoverageScope: Equatable, Sendable {
    /// The agent's `includes`; `nil` instruments everything (then dependencies too).
    public var includes: String?
    /// Compiled output directories to report on (`--classfiles`).
    public var classDirectories: [URL]
    /// Source directories of the same modules, for resolving the report's files and the HTML export.
    public var sourceDirectories: [URL]

    public init(includes: String? = nil, classDirectories: [URL] = [], sourceDirectories: [URL] = []) {
        self.includes = includes
        self.classDirectories = classDirectories
        self.sourceDirectories = sourceDirectories
    }

    /// The scope of every module of `model`.
    ///
    /// - Parameter includeTests: also report on the test source sets (off by default: the coverage
    ///   of a test class is rarely what is wanted).
    public static func make(model: JavaGradleProjectModel, includeTests: Bool = false) -> JavaCoverageScope {
        var classDirectories: [URL] = []
        var sourceDirectories: [URL] = []
        var seen = Set<String>()
        for subproject in model.subprojects {
            for sourceSet in subproject.sourceSets where includeTests || sourceSet.name == "main" {
                sourceDirectories += sourceSet.sourceDirs
                for directory in sourceSet.outputDirs {
                    // `build/resources/main` holds no classes; the CLI would only skip it, but the
                    // report step lists these in its log.
                    let path = directory.standardizedFileURL.path
                    guard !path.contains("/resources/"), seen.insert(path).inserted else { continue }
                    classDirectories.append(directory.standardizedFileURL)
                }
            }
        }
        return scope(classDirectories: classDirectories, sourceDirectories: sourceDirectories, includeTests: includeTests)
    }

    /// The scope from directories alone.
    public static func scope(
        classDirectories: [URL], sourceDirectories: [URL], includeTests: Bool = false
    ) -> JavaCoverageScope {
        let discovered = JavaCoveragePackages.discover(in: sourceDirectories)
        return JavaCoverageScope(
            includes: JavaCoverageCommand.includes(
                packages: discovered.packages, defaultPackageClasses: discovered.defaultPackageClasses
            ),
            classDirectories: classDirectories,
            sourceDirectories: sourceDirectories
        )
    }
}

/// Reads the packages a set of source directories declares.
public enum JavaCoveragePackages {
    public struct Discovery: Equatable, Sendable {
        /// Dotted package names, sorted; the default package is not listed.
        public var packages: [String]
        /// Simple names of the classes (files) with no `package` declaration.
        public var defaultPackageClasses: [String]
    }

    /// Directories visited at most, so a source root holding a whole checkout cannot stall a run.
    public static let directoryLimit = 20_000

    /// The package of the first `.java` file of each directory under `directories`, by its
    /// `package` declaration (a layout does not have to follow the packages).
    public static func discover(in directories: [URL]) -> Discovery {
        var packages = Set<String>()
        var defaults = Set<String>()
        var visited = 0
        let fileManager = FileManager.default
        var queue = directories.map { $0.standardizedFileURL }
        var seen = Set<String>()
        while let directory = queue.popLast() {
            guard seen.insert(directory.path).inserted, visited < directoryLimit else { continue }
            visited += 1
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            var firstJava: URL?
            var javaFiles: [URL] = []
            for entry in entries {
                if entry.pathExtension == "java" {
                    javaFiles.append(entry)
                    if firstJava == nil { firstJava = entry }
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    queue.append(entry)
                }
            }
            guard let firstJava else { continue }
            if let name = declaredPackage(in: firstJava) {
                if name.isEmpty {
                    for file in javaFiles where declaredPackage(in: file) == "" {
                        defaults.insert(file.deletingPathExtension().lastPathComponent)
                    }
                } else {
                    packages.insert(name)
                }
            }
        }
        return Discovery(packages: packages.sorted(), defaultPackageClasses: defaults.sorted())
    }

    /// `com.acme` for `package com.acme;`, `""` for a file with none, `nil` when unreadable.
    public static func declaredPackage(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8_192) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        // Strip comments before looking, so a licence header that says "package" does not count.
        let stripped = text
            .replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"//[^\n]*"#, with: " ", options: .regularExpression)
        if let range = stripped.range(of: #"(?m)^\s*(?:@\w+(?:\([^)]*\))?\s*)*package\s+([\w.]+)\s*;"#, options: .regularExpression) {
            let match = String(stripped[range])
            if let name = match.range(of: #"package\s+([\w.]+)"#, options: .regularExpression) {
                return String(match[name]).replacingOccurrences(of: "package", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }
}
