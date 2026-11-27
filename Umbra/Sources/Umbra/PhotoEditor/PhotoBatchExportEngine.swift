import CoreImage
import Foundation
import ImageIO

nonisolated struct PhotoBatchExportItem: Equatable, Sendable {
    var sourceURL: URL
    var succeeded: Bool
    var outputURL: URL?
    var message: String?
}

nonisolated enum PhotoBatchExportEngine {
    /// Writes one file into `destinationDirectory`. Collision-safe: `name.jpg`, `name-2.jpg`, …
    static func export(
        sourceURL: URL,
        adjustments: EditAdjustment,
        format: PhotoExportFormat,
        quality: Double,
        destinationDirectory: URL,
        engine: PhotoRenderEngine
    ) -> PhotoBatchExportItem {
        let ciFormat: CIFormat = format == .tiff16 ? .RGBA16 : .RGBA8
        guard let image = engine.renderFull(
            sourceURL: sourceURL,
            adjustments: adjustments,
            format: ciFormat
        ) else {
            return PhotoBatchExportItem(
                sourceURL: sourceURL,
                succeeded: false,
                outputURL: nil,
                message: PhotoExportError.encodeFailed.localizedDescription
            )
        }
        let metadata = metadata(from: sourceURL)
        do {
            let data = try PhotoExportEngine.encode(
                image,
                format: format,
                quality: quality,
                sourceMetadata: metadata
            )
            let output = uniqueURL(
                directory: destinationDirectory,
                baseName: sourceURL.deletingPathExtension().lastPathComponent,
                fileExtension: format.fileExtension
            )
            try data.write(to: output, options: .atomic)
            return PhotoBatchExportItem(
                sourceURL: sourceURL,
                succeeded: true,
                outputURL: output,
                message: nil
            )
        } catch {
            return PhotoBatchExportItem(
                sourceURL: sourceURL,
                succeeded: false,
                outputURL: nil,
                message: error.localizedDescription
            )
        }
    }

    static func uniqueURL(directory: URL, baseName: String, fileExtension: String) -> URL {
        let sanitized = baseName.isEmpty ? "photo" : baseName
        var candidate = directory.appendingPathComponent("\(sanitized).\(fileExtension)")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(sanitized)-\(index).\(fileExtension)")
            index += 1
        }
        return candidate
    }

    private static func metadata(from url: URL) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    }
}
