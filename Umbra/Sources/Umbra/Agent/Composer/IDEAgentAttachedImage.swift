import AgentKit
import AppKit
import Foundation

/// An image waiting in the composer to go with the next message. The bytes are what the model
/// gets (through `SessionStore`, beside the session); the thumbnail is what the chip shows.
struct IDEAttachedImage: Identifiable, Equatable {
    let id = UUID()
    var mediaType: String
    var data: Data
    var pixelSize: CGSize

    static func == (lhs: IDEAttachedImage, rhs: IDEAttachedImage) -> Bool { lhs.id == rhs.id }

    /// Images the composer accepts, by file extension. Anything else keeps the `@` mention path.
    static let acceptedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "heic", "heif"]

    static func isImageFile(_ url: URL) -> Bool {
        acceptedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Decodes pasted or dropped data, downscales to a bounded size (long edge 1,568 px) and
    /// re-encodes, so the bytes sent stay small. GIFs pass through unchanged (still under the cap)
    /// to keep their animation. `nil` when the data is not an image or is still too large.
    static func prepare(_ data: Data, filename: String) -> IDEAttachedImage? {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        if ext == "gif" {
            guard data.count <= SessionStore.maxImageBytes else { return nil }
            let size = NSImage(data: data)?.size ?? CGSize(width: 800, height: 600)
            return IDEAttachedImage(mediaType: "image/gif", data: data, pixelSize: size)
        }
        guard let image = NSImage(data: data) else { return nil }
        let mediaType: String
        let encoded: Data?
        switch ext {
        case "png":
            mediaType = "image/png"
            encoded = downscaled(image, maxEdge: 1_568)?.pngData
        case "webp":
            mediaType = "image/webp"
            encoded = downscaled(image, maxEdge: 1_568).flatMap { jpegData($0, quality: 0.85) }
            // WebP re-encodes as JPEG: the model sees the same pixels either way.
            return encoded.flatMap { IDEAttachedImage(mediaType: "image/jpeg", data: $0, pixelSize: $0.pixelSize) }
                .flatMap { $0.data.count <= SessionStore.maxImageBytes ? $0 : nil }
        case "tiff", "tif", "heic", "heif":
            mediaType = "image/jpeg"
            encoded = downscaled(image, maxEdge: 1_568).flatMap { jpegData($0, quality: 0.85) }
        default:
            mediaType = "image/jpeg"
            encoded = downscaled(image, maxEdge: 1_568).flatMap { jpegData($0, quality: 0.85) }
        }
        guard let encoded, encoded.count <= SessionStore.maxImageBytes else { return nil }
        let size = NSImage(data: encoded)?.size ?? CGSize(width: 800, height: 600)
        return IDEAttachedImage(mediaType: mediaType, data: encoded, pixelSize: size)
    }

    var thumbnail: NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        let edge: CGFloat = 96
        let scale = min(1, edge / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        thumb.unlockFocus()
        return thumb
    }

    // MARK: - Downscaling

    private static func downscaled(_ image: NSImage, maxEdge: CGFloat) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        let scale = min(1, maxEdge / max(width, height))
        let size = CGSize(width: max(1, width * scale), height: max(1, height * scale))
        let scaled = NSImage(size: size)
        scaled.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        scaled.unlockFocus()
        return scaled
    }

    private static func jpegData(_ image: NSImage, quality: CGFloat) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

private extension Data {
    var pixelSize: CGSize {
        NSImage(data: self)?.size ?? CGSize(width: 800, height: 600)
    }
}
