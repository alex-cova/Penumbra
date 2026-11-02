import XCTest
@testable import JavaIntelligence

final class JavaClassFileDecompilerTests: XCTestCase {
    func testRecognisesClassFilesByNameAndMagic() {
        XCTAssertTrue(JavaClassFileDecompiler.isClassFile(URL(fileURLWithPath: "/a/B.class")))
        XCTAssertTrue(JavaClassFileDecompiler.isClassFile(URL(fileURLWithPath: "/a/B.CLASS")))
        XCTAssertFalse(JavaClassFileDecompiler.isClassFile(URL(fileURLWithPath: "/a/B.java")))
        XCTAssertTrue(JavaClassFileDecompiler.hasClassMagic(Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0])))
        XCTAssertFalse(JavaClassFileDecompiler.hasClassMagic(Data([0xCA, 0xFE])))
        XCTAssertFalse(JavaClassFileDecompiler.hasClassMagic(Data("package a;".utf8)))
    }

    func testDecompilesARealClassWithTheNotice() throws {
        let text = try XCTUnwrap(JavaClassFileDecompiler.decompile(JavaFixtures.classFile("Fixture")))
        XCTAssertTrue(text.hasPrefix(JavaDecompilerAgreement.sourceNotice))
        XCTAssertTrue(text.contains("class Fixture"))
        XCTAssertTrue(text.contains("add("))
    }

    func testANestedClassIsNamedByItsSimpleName() throws {
        let text = try XCTUnwrap(JavaClassFileDecompiler.decompile(JavaFixtures.classFile("Fixture$Point")))
        XCTAssertFalse(text.contains("Fixture.Point("))
        XCTAssertTrue(text.contains("Point"))
    }

    func testBytesThatAreNotAClassDoNotDecompile() {
        XCTAssertNil(JavaClassFileDecompiler.decompile(Data("not a class".utf8)))
        XCTAssertNil(JavaClassFileDecompiler.decompile(Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00])))
    }

    func testClassFilesAreDependencySourceButAUsersFileIsNotInTheCache() {
        let userClass = URL(fileURLWithPath: "/work/build/classes/Foo.class")
        XCTAssertTrue(JavaAttachedSources.isExtractedSource(userClass))
        XCTAssertFalse(JavaAttachedSources.isInCache(userClass))
        let cached = URL(fileURLWithPath: "/cache/attached-sources/ab/resources/Foo.class")
        XCTAssertTrue(JavaAttachedSources.isInCache(cached))
        XCTAssertFalse(JavaAttachedSources.isExtractedSource(URL(fileURLWithPath: "/work/Foo.java")))
    }

    func testAJarEntryIsCopiedOutAsAClassFile() throws {
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("cls-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let url = try XCTUnwrap(JavaAttachedSources.extractResource(
            entry: "com/penumbra/fixture/Fixture.class", from: JavaFixtures.jarURL, cacheRoot: cacheRoot
        ))
        XCTAssertTrue(JavaClassFileDecompiler.isClassFile(url))
        XCTAssertTrue(JavaAttachedSources.isInCache(url))
        XCTAssertNotNil(JavaClassFileDecompiler.decompile(contentsOf: url))
    }
}
