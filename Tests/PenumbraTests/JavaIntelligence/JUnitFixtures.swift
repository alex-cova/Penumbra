import Foundation

/// Locates `Tests/PenumbraTests/Fixtures/JUnit` in the test bundle (`.copy("Fixtures/JUnit")`).
enum JUnitFixtures {
    static var directory: URL {
        guard let resourceURL = Bundle.module.resourceURL else { fatalError("no resourceURL") }
        for candidate in [resourceURL.appendingPathComponent("JUnit"), resourceURL.appendingPathComponent("Fixtures/JUnit")] {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("TEST-com.acme.CalcTest.xml").path) {
                return candidate
            }
        }
        fatalError("Could not locate JUnit fixtures in \(resourceURL)")
    }
}
