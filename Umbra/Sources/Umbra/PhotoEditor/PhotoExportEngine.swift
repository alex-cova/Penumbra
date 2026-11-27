import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum PhotoExportFormat: String, CaseIterable, Identifiable, Sendable {
    case heic
    case jpeg
    case png
    case tiff16

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .heic: "HEIC"
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .tiff16: "TIFF 16-bit"
        }
    }

    var utType: UTType {
        switch self {
        case .heic: .heic
        case .jpeg: .jpeg
        case .png: .png
        case .tiff16: .tiff
        }
    }

    var fileExtension: String {
        switch self {
        case .heic: "heic"
        case .jpeg: "jpg"
        case .png: "png"
        case .tiff16: "tiff"
        }
    }

    var supportsQuality: Bool { self == .heic || self == .jpeg }
}

nonisolated enum PhotoExportError: Error, LocalizedError, Equatable {
    case destinationCreationFailed
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .destinationCreationFailed:
            "Could not create the export file."
        case .encodeFailed:
            "Could not encode the image."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .destinationCreationFailed:
            "Choose a different location and try again."
        case .encodeFailed:
            "Try a different format or lower the quality."
        }
    }
}

nonisolated enum PhotoExportEngine {
    /// `sourceMetadata` is the dictionary from `CGImageSourceCopyPropertiesAtIndex` on import.
    static func encode(
        _ image: CGImage,
        format: PhotoExportFormat,
        quality: Double,
        sourceMetadata: [String: Any]?
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            format.utType.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotoExportError.destinationCreationFailed
        }

        var properties: [CFString: Any] = [:]
        if format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, quality))
        }
        if format == .tiff16 {
            properties[kCGImagePropertyDepth] = 16
        }
        // Pixels are already oriented (CIImage applied EXIF orientation on import).
        properties[kCGImagePropertyOrientation] = 1

        copyMetadataKey(kCGImagePropertyExifDictionary, from: sourceMetadata, into: &properties)
        copyMetadataKey(kCGImagePropertyGPSDictionary, from: sourceMetadata, into: &properties)
        copyMetadataKey(kCGImagePropertyTIFFDictionary, from: sourceMetadata, into: &properties)
        copyMetadataKey(kCGImagePropertyIPTCDictionary, from: sourceMetadata, into: &properties)

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoExportError.encodeFailed
        }
        return data as Data
    }

    private static func copyMetadataKey(
        _ key: CFString,
        from source: [String: Any]?,
        into properties: inout [CFString: Any]
    ) {
        guard let value = source?[key as String] else { return }
        properties[key] = value
    }
}
