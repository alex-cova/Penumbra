import Foundation
import JavaIntelligence

/// Reads Spring Boot configuration metadata for a module: `META-INF/spring-configuration-metadata.json` (and the
/// hand-written `additional-` file) from every classpath jar and from the module's own build output and resources.
/// Because it reads the project's own jars, the keys, defaults and deprecations are those of the project's Boot
/// version. A jar is read once per (path, size, modification date) and the result is kept.
actor SpringMetadataLoader {
    private struct JarKey: Hashable { let path: String; let size: Int; let modified: Date }
    private var jarCache: [JarKey: SpringConfigMetadata?] = [:]
    private static let names = ["META-INF/spring-configuration-metadata.json", "META-INF/additional-spring-configuration-metadata.json"]

    func load(modules: [SpringModuleInfo]) -> SpringConfigMetadata {
        var merged = SpringConfigMetadata()
        var seenJars = Set<URL>()
        for module in modules {
            // The project's own output and resources come first so its keys win over a library's.
            for dir in module.outputDirs + module.resourceRoots {
                for name in Self.names {
                    let file = dir.appendingPathComponent(name)
                    if let data = try? Data(contentsOf: file), let m = SpringConfigMetadata.parse(json: data, origin: module.projectPath) {
                        merged.merge(m)
                    }
                }
            }
            for jar in module.classpathJars where jar.pathExtension == "jar" && seenJars.insert(jar).inserted {
                if let m = metadata(in: jar) { merged.merge(m) }
            }
        }
        merged.finalize()
        return merged
    }

    private func metadata(in jar: URL) -> SpringConfigMetadata? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: jar.path)
        guard let size = attrs?[.size] as? Int, let modified = attrs?[.modificationDate] as? Date else { return nil }
        let key = JarKey(path: jar.path, size: size, modified: modified)
        if let cached = jarCache[key] { return cached }
        var result: SpringConfigMetadata?
        if let archive = try? ZipArchive(url: jar) {
            var merged = SpringConfigMetadata()
            var found = false
            for name in Self.names where archive.contains(name) {
                if let data = try? archive.data(for: name), let m = SpringConfigMetadata.parse(json: data, origin: jar.lastPathComponent) {
                    merged.merge(m); found = true
                }
            }
            result = found ? merged : nil
        }
        jarCache[key] = .some(result)
        return result
    }
}
