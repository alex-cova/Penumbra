import Foundation
import Penumbra
import XCTest

final class ImageContentDetectorTests: XCTestCase {
    func testRecognizesCommonImageExtensions() {
        XCTAssertTrue(ImageContentDetector.isImageFile(URL(fileURLWithPath: "/tmp/photo.jpg")))
        XCTAssertTrue(ImageContentDetector.isImageFile(URL(fileURLWithPath: "/tmp/photo.JPEG")))
        XCTAssertTrue(ImageContentDetector.isImageFile(URL(fileURLWithPath: "/tmp/icon.png")))
        XCTAssertTrue(ImageContentDetector.isImageFile(URL(fileURLWithPath: "/tmp/anim.gif")))
        XCTAssertTrue(ImageContentDetector.isImageFile(URL(fileURLWithPath: "/tmp/scan.tiff")))
    }

    func testRejectsTextFiles() {
        XCTAssertFalse(ImageContentDetector.isImageFile(URL(fileURLWithPath: "/tmp/main.swift")))
        XCTAssertFalse(ImageContentDetector.isImageFile(URL(fileURLWithPath: "/tmp/readme.md")))
        XCTAssertFalse(ImageContentDetector.isImageFile(URL(fileURLWithPath: "/tmp/data.json")))
    }

    func testLoadImageDocumentSetsContentKind() {
        let url = URL(fileURLWithPath: "/tmp/preview.png")
        let document = WorkbenchDocument.loadImage(from: url)
        XCTAssertEqual(document.contentKind, .image)
        XCTAssertEqual(document.url, url)
        XCTAssertEqual(document.displayName, "preview.png")
        XCTAssertFalse(document.isFileBacked)
    }
}
