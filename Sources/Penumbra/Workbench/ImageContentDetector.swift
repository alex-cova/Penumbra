import Foundation
import UniformTypeIdentifiers

/// Detects image files that AppKit can render natively.
public enum ImageContentDetector {
    private static let knownExtensions: Set<String> = [
        "bmp", "gif", "heic", "heif", "icns", "ico", "jpeg", "jpg", "png", "tiff", "tif", "webp"
    ]

    public static func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if knownExtensions.contains(ext) {
            return true
        }
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else {
            return false
        }
        return type.conforms(to: .image)
    }
}
