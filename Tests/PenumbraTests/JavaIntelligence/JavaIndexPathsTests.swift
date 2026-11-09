import CryptoKit
import XCTest
@testable import JavaIntelligence

/// Shard file names are a SHA-256 of a path in lower-case hex. The name is the cache key, so changing it
/// would silently discard every user's index; the hex is produced without `String(format:)` now, and
/// must come out exactly as it did.
final class JavaIndexPathsTests: XCTestCase {
    private func expectedHex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testShardNamesAreUnchanged() {
        let paths = JavaIndexPaths(root: URL(fileURLWithPath: "/cache"))
        var samples = [
            "", "a", "abc", "/Users/alex/.gradle/caches/modules-2/files-2.1/org.springframework/spring-core/6.1.0/abc/spring-core-6.1.0.jar",
            "/tmp/é日本😀.jar", String(repeating: "x", count: 4_000)
        ]
        for index in 0..<400 { samples.append("/m2/repository/g\(index)/a\(index * 7)/\(index).\(index % 13)/a-\(index).jar") }
        for path in samples {
            XCTAssertEqual(paths.jarShard(URL(fileURLWithPath: path)).lastPathComponent, "jar-\(expectedHex(URL(fileURLWithPath: path).path)).idx", path)
        }
    }

    func testKnownDigest() {
        // SHA-256("abc"), from FIPS 180-2.
        let paths = JavaIndexPaths(root: URL(fileURLWithPath: "/cache"))
        let name = paths.jarShard(URL(fileURLWithPath: "/abc")).lastPathComponent
        XCTAssertEqual(name, "jar-\(expectedHex("/abc")).idx")
        XCTAssertEqual(expectedHex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
