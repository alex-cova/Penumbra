import Foundation
@preconcurrency import AppKit

/// Resolves local markdown image references for the preview. Blocks remote `http(s)` URLs by default.
enum MarkdownPreviewImageLoader {
    static func loadImage(at reference: String, baseURL: URL?) -> CGImage? {
        guard let url = fileURL(for: reference, baseURL: baseURL) else { return nil }
        return loadImage(at: url)
    }

    /// The local file a reference points at; `nil` for remote or unresolvable references.
    static func fileURL(for reference: String, baseURL: URL?) -> URL? {
        guard let url = resolveURL(reference, baseURL: baseURL), url.isFileURL else { return nil }
        return url
    }

    /// Decodes eagerly, so the first draw of the image (on the main thread, or a tile raster)
    /// doesn't pay for decompression.
    static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    /// A loaded image's natural size, in points — treats one pixel as one point (there is no
    /// resolution-tagging convention for markdown image references), matching how the same image
    /// is rasterized 1:1 for the preview.
    static func naturalSize(of image: CGImage) -> CGSize {
        CGSize(width: image.width, height: image.height)
    }

    static func resolveURL(_ reference: String, baseURL: URL?) -> URL? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            if absolute.scheme == "http" || absolute.scheme == "https" {
                return nil
            }
            return absolute
        }

        guard let baseURL else { return URL(fileURLWithPath: trimmed) }
        return URL(string: trimmed, relativeTo: baseURL)?.standardizedFileURL
    }
}
