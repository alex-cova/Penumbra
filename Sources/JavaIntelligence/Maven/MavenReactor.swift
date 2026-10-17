import Foundation

/// The modules of one reactor: the root POM and every module it lists, including modules that an
/// active profile added. A module's path is `:` plus its directory relative to the root, with `:`
/// between folders (`:services:api`). The root is `:`.
enum MavenReactor {
    static func modules(
        projectRoot: URL,
        repository: URL,
        options: MavenReadOptions,
        config: MavenConfigFile,
        store: MavenPOMStore
    ) throws -> [MavenEffectiveModule] {
        let rootPOM = projectRoot.appendingPathComponent("pom.xml")
        guard FileManager.default.fileExists(atPath: rootPOM.path) else {
            throw MavenReadError(file: rootPOM, message: "The folder has no pom.xml.")
        }
        var result: [MavenEffectiveModule] = []
        var seenDirectories = Set<String>()
        try walk(
            pomFile: rootPOM, projectRoot: projectRoot, repository: repository, options: options,
            config: config, store: store, into: &result, seen: &seenDirectories
        )
        return result
    }

    private static func walk(
        pomFile: URL,
        projectRoot: URL,
        repository: URL,
        options: MavenReadOptions,
        config: MavenConfigFile,
        store: MavenPOMStore,
        into result: inout [MavenEffectiveModule],
        seen: inout Set<String>
    ) throws {
        let directory = pomFile.deletingLastPathComponent().standardizedFileURL
        let key = directory.path
        guard seen.insert(key).inserted else { return }
        let path = modulePath(directory: directory, projectRoot: projectRoot)
        let module = try MavenModelBuilder.module(
            pomFile: pomFile, projectRoot: projectRoot, modulePath: path, repository: repository,
            options: options, config: config, store: store
        )
        result.append(module)
        for name in module.modules {
            let child = directory.appendingPathComponent(name)
            let childPOM = child.pathExtension.lowercased() == "xml" ? child : child.appendingPathComponent("pom.xml")
            guard FileManager.default.fileExists(atPath: childPOM.path) else { continue }
            try walk(
                pomFile: childPOM, projectRoot: projectRoot, repository: repository, options: options,
                config: config, store: store, into: &result, seen: &seen
            )
        }
    }

    static func modulePath(directory: URL, projectRoot: URL) -> String {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
        if path == root { return ":" }
        guard path.hasPrefix(root + "/") else { return ":" + directory.lastPathComponent }
        let relative = path.dropFirst(root.count + 1)
        return ":" + relative.split(separator: "/").joined(separator: ":")
    }
}
