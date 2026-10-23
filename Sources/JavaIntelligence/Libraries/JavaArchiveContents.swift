import Foundation

/// One row of a library's expansion in the Explorer: a module, a package, a folder of resources, a
/// top-level type or a resource file.
public struct JavaArchiveNode: Equatable, Sendable, Identifiable {
    public enum Kind: Sendable {
        case module, package, folder, type, resource
    }

    /// Unique inside one archive (`pkg:org/slf4j`, `type:org.slf4j.Logger`, `entry:META-INF/MANIFEST.MF`).
    public let id: String
    public let kind: Kind
    public let name: String
    /// The archive entry a `.resource` or `.type` row stands for.
    public let entry: String?
    /// `org.slf4j.Logger` for a `.type`.
    public let qualifiedName: String?
    public var children: [JavaArchiveNode]
}

/// Builds the tree under a library from the names in its central directory; nothing is decompressed.
public enum JavaArchiveContents {
    public enum Layout: Sendable {
        /// A dependency jar: `org/slf4j/Logger.class`, `META-INF/MANIFEST.MF`.
        case jar
        /// A JDK `src.zip`, or jmod entries prefixed with their module: `java.base/java/lang/String.java`.
        case moduleRooted
    }

    /// Packages are flat and dotted (`org.apache.commons.lang3`) as IntelliJ shows them with
    /// "Flatten Packages"; a directory with resources only is a slash-separated folder. Inner and
    /// local classes (`$`), `module-info` and `package-info` are left out, and so are the
    /// multi-release copies under `META-INF/versions/`.
    public static func nodes(entries: [String], layout: Layout) -> [JavaArchiveNode] {
        struct Bucket {
            var types: [JavaArchiveNode] = []
            var resources: [JavaArchiveNode] = []
        }
        // module ("" for a jar) -> directory ("" for the root) -> content
        var buckets: [String: [String: Bucket]] = [:]

        for entry in entries where !entry.hasSuffix("/") {
            var module = ""
            var path = Substring(entry)
            switch layout {
            case .jar:
                if entry.hasPrefix("META-INF/versions/") { continue }
            case .moduleRooted:
                guard let slash = path.firstIndex(of: "/") else { continue }
                module = String(path[..<slash])
                path = path[path.index(after: slash)...]
            }
            let directory: String
            let file: Substring
            if let slash = path.lastIndex(of: "/") {
                directory = String(path[..<slash])
                file = path[path.index(after: slash)...]
            } else {
                directory = ""
                file = path
            }
            guard !file.isEmpty else { continue }
            let scope = module.isEmpty ? "" : module + "/"
            let dot = file.lastIndex(of: ".")
            let stem = dot.map { String(file[..<$0]) } ?? String(file)
            let ext = dot.map { String(file[file.index(after: $0)...]) } ?? ""

            let isType = ext == "class" || (layout == .moduleRooted && ext == "java")
            if isType {
                guard !stem.contains("$"), stem != "module-info", stem != "package-info", !stem.isEmpty else { continue }
                let package = directory.replacingOccurrences(of: "/", with: ".")
                let qualified = package.isEmpty ? stem : package + "." + stem
                buckets[module, default: [:]][directory, default: Bucket()].types.append(JavaArchiveNode(
                    id: "type:" + scope + qualified, kind: .type, name: stem, entry: entry,
                    qualifiedName: qualified, children: []
                ))
            } else if layout == .jar {
                buckets[module, default: [:]][directory, default: Bucket()].resources.append(JavaArchiveNode(
                    id: "entry:" + entry, kind: .resource, name: String(file), entry: entry,
                    qualifiedName: nil, children: []
                ))
            }
        }

        func containers(of directories: [String: Bucket], scope: String) -> [JavaArchiveNode] {
            var result: [JavaArchiveNode] = []
            for (directory, bucket) in directories {
                if directory.isEmpty && bucket.types.isEmpty { continue }
                let isPackage = !bucket.types.isEmpty
                let name = isPackage
                    ? (directory.isEmpty ? "(default package)" : directory.replacingOccurrences(of: "/", with: "."))
                    : directory
                result.append(JavaArchiveNode(
                    id: (isPackage ? "pkg:" : "dir:") + scope + directory,
                    kind: isPackage ? .package : .folder, name: name, entry: nil, qualifiedName: nil,
                    children: sorted(bucket.types + bucket.resources)
                ))
            }
            return sorted(result)
        }

        switch layout {
        case .jar:
            let directories = buckets[""] ?? [:]
            let rootFiles = sorted(directories[""]?.resources ?? [])
            return containers(of: directories, scope: "") + rootFiles
        case .moduleRooted:
            return buckets.map { module, directories in
                JavaArchiveNode(
                    id: "mod:" + module, kind: .module, name: module, entry: nil, qualifiedName: nil,
                    children: containers(of: directories, scope: module + "/")
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private static func sorted(_ nodes: [JavaArchiveNode]) -> [JavaArchiveNode] {
        nodes.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
