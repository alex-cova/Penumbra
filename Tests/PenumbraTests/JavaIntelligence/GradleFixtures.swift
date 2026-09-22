import Foundation

/// Locates the fixture JSON files under `Tests/PenumbraTests/Fixtures/Gradle`, copied into the
/// test bundle by `Package.swift`'s `.copy("Fixtures/Gradle")` resource entry. Mirrors
/// `JavaFixtures`.
enum GradleFixtures {
    static var directory: URL {
        guard let resourceURL = Bundle.module.resourceURL else {
            fatalError("PenumbraTests bundle has no resourceURL")
        }
        // `.copy("Fixtures/Gradle")` in Package.swift copies the directory's *contents* to the
        // bundle root under its last path component ("Gradle"), not the full relative path.
        for candidate in [resourceURL.appendingPathComponent("Gradle"), resourceURL.appendingPathComponent("Fixtures/Gradle")] {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("single-module.json").path) {
                return candidate
            }
        }
        let enumerator = FileManager.default.enumerator(at: resourceURL, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "single-module.json" {
                return url.deletingLastPathComponent()
            }
        }
        fatalError("Could not locate Gradle fixtures in test bundle at \(resourceURL)")
    }

    static func modelData(_ name: String) -> Data {
        let url = directory.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url) else {
            fatalError("Missing fixture: \(url.path)")
        }
        return data
    }
}
