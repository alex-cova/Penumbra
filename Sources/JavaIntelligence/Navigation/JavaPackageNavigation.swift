import EditorIntelligence
import Foundation

/// Go to Definition on a package name: the folder of a project package, else the package itself.
extension JavaNavigationSession {
    /// A package's folder in each source root that has one (main and test, several modules), or
    /// the package alone (`Location.Target.package`) when only the JDK or a JAR holds it.
    func packageHits(components: [String]) async -> [JavaDefinitionHit] {
        let name = components.joined(separator: ".")
        guard !name.isEmpty, await index.hasPackage(name) else { return [] }
        let directories = await packageDirectories(of: components)
        if !directories.isEmpty {
            return directories.map { directory in
                JavaDefinitionHit(
                    url: directory,
                    range: Self.emptyRange,
                    displayName: Self.label(for: directory, components: components),
                    target: .directory
                )
            }
        }
        return [JavaDefinitionHit(url: nil, range: Self.emptyRange, displayName: name, target: .package(name))]
    }

    /// The folders that hold `components` as a package, found through the source files of the
    /// project classes in it. A package that has no class of its own (`com.acme`) is found
    /// through its nearest subpackages, one level at a time, with the extra folders stripped.
    func packageDirectories(of components: [String]) async -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        var level = [components.joined(separator: ".")]
        var visited = 0
        while !level.isEmpty, visited < 400 {
            var next: [String] = []
            for package in level {
                visited += 1
                let depth = package.split(separator: ".").count - components.count
                for stub in await index.classes(inPackage: package) {
                    guard case .source(let url, _) = stub.origin else { continue }
                    if let directory = Self.directory(of: url, strippingPackageDepth: depth, expected: components),
                       seen.insert(directory.standardizedFileURL.path).inserted {
                        found.append(directory)
                    }
                }
                next.append(contentsOf: await index.subpackages(of: package))
            }
            if !found.isEmpty { break }
            level = next
        }
        return found.sorted { $0.path < $1.path }
    }

    /// `/p/src/main/java/com/acme/model/Dog.java` for package `com.acme.model` is its folder; for
    /// the prefix `com.acme` (`depth` 1) it is that folder's parent. Nil when the file's folder
    /// does not end with the package path (a file outside its package's layout).
    private static func directory(of file: URL, strippingPackageDepth depth: Int, expected components: [String]) -> URL? {
        var directory = file.deletingLastPathComponent()
        for _ in 0..<max(0, depth) { directory = directory.deletingLastPathComponent() }
        let tail = directory.pathComponents.suffix(components.count)
        return Array(tail) == components ? directory : nil
    }

    /// `src/main/java/com/acme/model`: the folder with the source root that holds it.
    private static func label(for directory: URL, components: [String]) -> String {
        let all = directory.pathComponents
        let rootLength = max(0, all.count - components.count)
        let root = Array(all.prefix(rootLength).suffix(3))
        return (root + components).joined(separator: "/")
    }

    private static var emptyRange: EditorIntelligence.TextRange {
        let origin = EditorIntelligence.TextPosition(line: 0, column: 0, utf16Offset: 0)
        return EditorIntelligence.TextRange(start: origin, end: origin)
    }
}
