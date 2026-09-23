import Foundation
import FernflowerKit

/// Turns one `.class` file (from a dependency JAR or a JDK `.jmod`) into Java source when no
/// attached sources exist. The bytes are Sunflower's input; the caller must already have shown
/// ``JavaDecompilerAgreement``.
enum JavaClassDecompiler {
    static func decompile(stub: JavaClassStub, jdkHome: URL?, cacheRoot: URL) -> (url: URL, text: String)? {
        guard let archive = archiveURL(for: stub.origin, jdkHome: jdkHome) else { return nil }
        let destination = cachedFileURL(for: stub, archive: archive, cacheRoot: cacheRoot)
        if let cached = readCached(destination, archive: archive) {
            return (destination, cached)
        }
        guard let data = classBytes(for: stub, jdkHome: jdkHome) else { return nil }
        guard let raw = try? JavaDecompiler().decompile(classData: data) else { return nil }
        let normalized = normalizeTypeName(raw, simpleName: stub.simpleName, dottedName: dottedName(of: stub))
        let source = JavaDecompilerAgreement.sourceNotice + "\n\n" + normalized
        guard write(source, to: destination) else { return nil }
        return (destination, source)
    }

    /// `java.util.Map$Entry` → `java/util/Map$Entry.class`.
    static func classEntryPath(binaryName: String) -> String {
        binaryName.replacingOccurrences(of: ".", with: "/") + ".class"
    }

    /// Sunflower prints a nested class's own declaration and constructors as `Outer.Inner`, which
    /// is not a Java type name — `JavaDeclarationLocator` expects a single identifier for a
    /// decompiled file (it accepts one via `relaxedSimpleName`). This rewrites just those two
    /// spots; any other qualified use of the nested name elsewhere in the body is left alone.
    static func normalizeTypeName(_ source: String, simpleName: String, dottedName: String) -> String {
        guard dottedName != simpleName, dottedName.contains(".") else { return source }
        let escaped = NSRegularExpression.escapedPattern(for: dottedName)
        let patterns = [
            #"(?:@interface|\bclass|\binterface|\benum|\brecord)\s+("# + escaped + ")",
            #"(?<!new )\b("# + escaped + #")\s*\("#
        ]
        var result = source
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let full = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: full)
            for match in matches.reversed() {
                guard let range = Range(match.range(at: 1), in: result) else { continue }
                result.replaceSubrange(range, with: simpleName)
            }
        }
        return result
    }

    /// The type's name relative to its package, e.g. `Fixture.Point` for
    /// `com.penumbra.fixture.Fixture.Point`, or just `Fixture` for a top-level type.
    private static func dottedName(of stub: JavaClassStub) -> String {
        guard !stub.packageName.isEmpty, stub.qualifiedName.hasPrefix(stub.packageName + ".") else {
            return stub.qualifiedName
        }
        return String(stub.qualifiedName.dropFirst(stub.packageName.count + 1))
    }

    private static func archiveURL(for origin: JavaStubOrigin, jdkHome: URL?) -> URL? {
        switch origin {
        case .jar(let jar):
            return jar
        case .jdkModule(let module):
            guard let jdkHome else { return nil }
            return jdkHome.appendingPathComponent("jmods").appendingPathComponent("\(module).jmod")
        case .source:
            return nil
        }
    }

    private static func classBytes(for stub: JavaClassStub, jdkHome: URL?) -> Data? {
        let entry = classEntryPath(binaryName: stub.binaryName)
        switch stub.origin {
        case .jar(let jar):
            return zipEntry(entry, in: jar)
        case .jdkModule(let module):
            guard let jdkHome else { return nil }
            let jmod = jdkHome.appendingPathComponent("jmods").appendingPathComponent("\(module).jmod")
            return zipEntry("classes/\(entry)", in: jmod)
        case .source:
            return nil
        }
    }

    private static func zipEntry(_ name: String, in archiveURL: URL) -> Data? {
        guard let archive = try? ZipArchive(url: archiveURL) else { return nil }
        return try? archive.data(for: name)
    }

    /// Keyed by the source archive so two JARs with a same-named class don't collide, and cached
    /// so repeated resolution (e.g. Cmd-hover) doesn't re-decompile on every call.
    private static func cachedFileURL(for stub: JavaClassStub, archive: URL, cacheRoot: URL) -> URL {
        let entry = classEntryPath(binaryName: stub.binaryName).replacingOccurrences(of: ".class", with: ".java")
        var destination = cacheRoot
            .appendingPathComponent("attached-sources", isDirectory: true)
            .appendingPathComponent("decompiled", isDirectory: true)
            .appendingPathComponent(JavaAttachedSources.stableKey(archive.path), isDirectory: true)
        for component in entry.split(separator: "/") {
            destination.appendPathComponent(String(component))
        }
        return destination
    }

    private static func readCached(_ destination: URL, archive: URL) -> String? {
        let fileManager = FileManager.default
        guard let destinationAttributes = try? fileManager.attributesOfItem(atPath: destination.path),
              let destinationDate = destinationAttributes[.modificationDate] as? Date,
              let archiveAttributes = try? fileManager.attributesOfItem(atPath: archive.path),
              let archiveDate = archiveAttributes[.modificationDate] as? Date,
              destinationDate >= archiveDate else {
            return nil
        }
        return try? String(contentsOf: destination, encoding: .utf8)
    }

    private static func write(_ text: String, to destination: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: destination, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
