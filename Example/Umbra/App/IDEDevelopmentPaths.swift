import Foundation

/// Where this app's source tree is when it runs from a development build (`swift run`, the tests, an
/// Xcode run). Tool jars built next to the sources are found there when the app bundle has none.
///
/// Derived from this file's own location (`Example/Umbra/App/`), so the folders above it can be
/// reorganised without breaking a lookup written relative to some other file.
enum IDEDevelopmentPaths {
    /// `Example/Umbra`.
    static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // App
        .deletingLastPathComponent()  // Umbra
}
