import Foundation

/// Locates `Fixtures/JavaCoverage` and `Fixtures/JavaProfiling` in this test bundle. The files are
/// copies of the ones under `Tests/PenumbraTests/Fixtures` that the model tests in the root package
/// read; only the four the Umbra views and the instrumented-run tests need are kept here.
enum InstrumentationFixtures {
    static func url(_ folder: String, _ name: String) -> URL {
        guard let resourceURL = Bundle.module.resourceURL else { fatalError("no resourceURL") }
        for candidate in [
            resourceURL.appendingPathComponent(folder).appendingPathComponent(name),
            resourceURL.appendingPathComponent("Fixtures/\(folder)/\(name)")
        ] where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        fatalError("Could not locate \(folder)/\(name) in \(resourceURL)")
    }
}
