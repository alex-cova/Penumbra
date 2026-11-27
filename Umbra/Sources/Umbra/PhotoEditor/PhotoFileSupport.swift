import AppKit
import UniformTypeIdentifiers

/// Image files the photo editor opens, mirroring the reference `PhotoEditorImport`.
@MainActor
enum PhotoEditorImport {
    static var contentTypes: [UTType] {
        var types: [UTType] = [.image]
        if let raw = UTType("public.camera-raw-image") {
            types.append(raw)
        }
        return types
    }
}

/// Thin `NSOpenPanel` / `NSSavePanel` wrappers for the photo editor. Umbra has no shared file-panel
/// helper, so the editor owns these two small builders.
@MainActor
enum PhotoFilePanel {
    static func save(
        suggestedName: String,
        contentTypes: [UTType],
        completion: @escaping (URL) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = contentTypes
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }

    static func openFiles(
        message: String,
        contentTypes: [UTType],
        allowsMultipleSelection: Bool,
        completion: @escaping ([URL]) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.message = message
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            completion(panel.urls)
        }
    }

    static func openDirectory(
        message: String,
        completion: @escaping (URL?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.message = message
        panel.allowedContentTypes = [.folder]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.begin { response in
            completion(response == .OK ? panel.url : nil)
        }
    }
}
