import Foundation

/// Which packages of other modules a file may name (F16). A file whose source root has a
/// `module-info.java` is in a named module; the modules it reads (its `requires`, and what those
/// `requires transitive`) give it only their exported packages. Every other module, and every
/// file of a plain classpath project, is unrestricted: this fails open.
///
/// It narrows name listings (completion, import suggestions), not type resolution: a method of
/// module `a` may return a type from a package `a` does not export, and members of that value
/// still complete.
///
/// Policy (F-17): jars and the JDK are unrestricted by design. Their `module-info` graphs are
/// not modelled — `javac` still rejects a bad import at build time, and resolving into an
/// internal package (go-to-definition, hover) is a feature, not a leak. Measured by
/// `testAModularJarsNonExportedPackageIsOfferedWhileJavacRejectsIt`: Umbra offers what
/// `javac` rejects, on purpose. A `not exported` diagnostic would need the jars' module
/// graph first; until then, offering more is the safer error.
public struct JavaModuleVisibility: Sendable, Equatable {
    /// One restricted shard: every package of the module, and the ones the reader may use.
    public struct Restriction: Sendable, Equatable {
        public let packages: Set<String>
        public let exported: Set<String>

        public init(packages: Set<String>, exported: Set<String>) {
            self.packages = packages
            self.exported = exported
        }

        /// A class belongs to the longest prefix of its name that is a package of the module
        /// (`a.api.Outer.Inner` is in `a.api`). A name that fits no known package is allowed.
        public func allows(qualifiedName: String) -> Bool {
            var end = qualifiedName.endIndex
            while let dot = qualifiedName[..<end].lastIndex(of: ".") {
                let candidate = String(qualifiedName[..<dot])
                if packages.contains(candidate) { return exported.contains(candidate) }
                end = dot
            }
            return true
        }
    }

    /// By shard path (``JavaIndex/Source/shardPath``). A shard that is not here is unrestricted.
    public let restrictions: [String: Restriction]

    public init(restrictions: [String: Restriction]) {
        self.restrictions = restrictions
    }

    public var isEmpty: Bool { restrictions.isEmpty }
}

/// Reads and remembers the module declarations and package lists of source directories.
enum JavaModuleSources {
    private struct Cached<Value> {
        let stamp: Date
        let value: Value
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var descriptors: [String: Cached<JavaModuleDescriptor?>] = [:]
    nonisolated(unsafe) private static var packageLists: [String: Cached<Set<String>>] = [:]

    /// The module declared in the first of `directories` that has a `module-info.java`.
    static func descriptor(in directories: [URL]) -> JavaModuleDescriptor? {
        for directory in directories {
            let file = directory.appendingPathComponent("module-info.java")
            guard let stamp = modificationDate(file) else { continue }
            lock.lock()
            if let cached = descriptors[file.path], cached.stamp == stamp {
                lock.unlock()
                if let value = cached.value { return value }
                continue
            }
            lock.unlock()
            let parsed = (try? String(contentsOf: file, encoding: .utf8)).flatMap(JavaModuleDescriptor.parse(source:))
            lock.lock()
            descriptors[file.path] = Cached(stamp: stamp, value: parsed)
            lock.unlock()
            if let parsed { return parsed }
        }
        return nil
    }

    /// Every package that has a `.java` file under `directory`, from the folder layout. Cached on
    /// the directory's own modification date, so a package added in a new folder is missed until
    /// the root changes; a missed package is allowed (see ``JavaModuleVisibility/Restriction``).
    static func packages(in directory: URL) -> Set<String> {
        let root = directory.standardizedFileURL
        let stamp = modificationDate(root) ?? .distantPast
        lock.lock()
        if let cached = packageLists[root.path], cached.stamp == stamp {
            lock.unlock()
            return cached.value
        }
        lock.unlock()
        var found = Set<String>()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator where url.pathExtension == "java" {
                let folder = url.deletingLastPathComponent().standardizedFileURL.path
                guard folder.hasPrefix(prefix) else { continue }
                found.insert(String(folder.dropFirst(prefix.count)).replacingOccurrences(of: "/", with: "."))
            }
        }
        lock.lock()
        packageLists[root.path] = Cached(stamp: stamp, value: found)
        lock.unlock()
        return found
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

extension JavaGradleProjectModel {
    /// The package restrictions for a file in a named module, or nil when the file's source set
    /// has no `module-info.java` (classpath rules: everything is visible).
    ///
    /// Only the modules this one reads are restricted, to their exported packages (a qualified
    /// `exports … to` counts when this module is a target). A module it does not require is left
    /// alone: the editor still offers its types, as IntelliJ does, and the compiler says why not.
    public func moduleVisibility(forFile file: URL, paths: JavaIndexPaths) -> JavaModuleVisibility? {
        guard let match = sourceSet(containing: file),
              let own = JavaModuleSources.descriptor(in: match.sourceSet.sourceDirs) else { return nil }

        struct Dependency {
            let descriptor: JavaModuleDescriptor
            let directories: [URL]
        }
        // Every module reachable through project dependencies (a `requires transitive` chain can
        // reach one the file's own source set does not list).
        var dependencies: [String: Dependency] = [:]
        var visited = Set<String>()
        var pending = match.sourceSet.projectDependencies
        while let dependency = pending.popLast() {
            guard visited.insert("\(dependency.projectPath):\(dependency.sourceSetName)").inserted,
                  let target = subprojects.first(where: { $0.path == dependency.projectPath }) else { continue }
            let set = target.sourceSets.first { $0.name == dependency.sourceSetName } ?? target.sourceSets.first { $0.name == "main" }
            guard let set else { continue }
            pending += set.projectDependencies
            if let descriptor = JavaModuleSources.descriptor(in: set.sourceDirs) {
                dependencies[descriptor.name] = Dependency(descriptor: descriptor, directories: set.sourceDirs + set.generatedSourceDirs)
            }
        }

        // The modules this one reads: its requires, and what each of those requires transitively.
        var readable = Set<String>()
        var queue = own.requires.map(\.module)
        while let name = queue.popLast() {
            guard readable.insert(name).inserted, let dependency = dependencies[name] else { continue }
            queue += dependency.descriptor.requires.filter(\.isTransitive).map(\.module)
        }

        var restrictions: [String: JavaModuleVisibility.Restriction] = [:]
        for name in readable {
            guard let dependency = dependencies[name] else { continue }
            let existing = dependency.directories.filter { FileManager.default.fileExists(atPath: $0.path) }
            let packages = existing.reduce(into: Set<String>()) { $0.formUnion(JavaModuleSources.packages(in: $1)) }
            let exported = Set(dependency.descriptor.exports.filter { $0.to.isEmpty || $0.to.contains(own.name) }.map(\.package))
            let restriction = JavaModuleVisibility.Restriction(packages: packages, exported: exported)
            for directory in existing {
                restrictions[paths.projectSourcesShard(for: directory.standardizedFileURL).path] = restriction
            }
        }
        return restrictions.isEmpty ? nil : JavaModuleVisibility(restrictions: restrictions)
    }
}
