import Foundation

/// Locates the `.class`/`.jar` fixtures under `Tests/PenumbraTests/Fixtures/Java`, copied into the
/// test bundle by `Package.swift`'s `.copy("Fixtures/Java")` resource entry. See that directory's
/// README for how to regenerate them.
enum JavaFixtures {
    static var directory: URL {
        guard let resourceURL = Bundle.module.resourceURL else {
            fatalError("PenumbraTests bundle has no resourceURL")
        }
        // `.copy("Fixtures/Java")` in Package.swift copies the directory's *contents* to the
        // bundle root under its last path component ("Java"), not the full relative path.
        for candidate in [resourceURL.appendingPathComponent("Java"), resourceURL.appendingPathComponent("Fixtures/Java")] {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Fixture.class").path) {
                return candidate
            }
        }
        // Fall back to a recursive search rooted at the bundle so this doesn't break across SPM versions.
        let enumerator = FileManager.default.enumerator(at: resourceURL, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "Fixture.class" {
                return url.deletingLastPathComponent()
            }
        }
        fatalError("Could not locate Java fixtures in test bundle at \(resourceURL)")
    }

    static func classFile(_ name: String) -> Data {
        let url = directory.appendingPathComponent("\(name).class")
        guard let data = try? Data(contentsOf: url) else {
            fatalError("Missing fixture class file: \(url.path)")
        }
        return data
    }

    static var jarURL: URL {
        directory.appendingPathComponent("fixture.jar")
    }
}
