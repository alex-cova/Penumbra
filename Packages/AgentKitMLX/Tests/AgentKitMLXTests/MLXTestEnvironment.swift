import Foundation

enum MLXTestEnvironment {
    /// Resource folders of the bundle under test, found from the `--test-bundle-path` the SwiftPM
    /// test helper is started with (`…/X.xctest/Contents/MacOS/X`), plus the folder holding it.
    static func resourceRoots() -> [URL] {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--test-bundle-path"), arguments.indices.contains(flag + 1) else { return [] }
        var url = URL(fileURLWithPath: arguments[flag + 1])
        while url.pathExtension != "xctest", url.path != "/" { url.deleteLastPathComponent() }
        guard url.pathExtension == "xctest" else { return [] }
        return [url.appendingPathComponent("Contents/Resources"), url.deletingLastPathComponent()]
    }
}
