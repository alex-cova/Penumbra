import Foundation

/// Which jars' parsed shards are worth keeping loaded after the last window stops using them.
///
/// A release artifact in a dependency cache never changes at a given path, and it is the jar that
/// different projects share (Guava, JUnit, Spring), so its reader is kept and the next open or
/// re-sync only checks the file's stamp. A jar that can be rewritten in place (a `SNAPSHOT`, a
/// local `libs/` jar, a module's build output) is not: its reader lives only while a window holds it.
/// Either way the reader's stamp is compared with the file's before every use, so this decides how
/// long an unused reader stays in memory, never whether a stale one can be served.
public enum JavaJarCachePolicy {
    /// Path components that mark a dependency cache whose layout is `<group>/<artifact>/<version>/…`
    /// and whose release files are never rewritten.
    private static let immutableCacheMarkers = [
        "/modules-2/files-2.1/",
        "/.m2/repository/"
    ]

    public static func isImmutableArtifact(_ jarURL: URL) -> Bool {
        let path = jarURL.standardizedFileURL.path
        guard immutableCacheMarkers.contains(where: { path.contains($0) }) else { return false }
        return !path.localizedCaseInsensitiveContains("SNAPSHOT")
    }
}
