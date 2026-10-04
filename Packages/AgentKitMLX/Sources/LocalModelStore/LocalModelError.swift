import Foundation

public enum LocalModelError: Error, LocalizedError, Sendable, Equatable {
    case invalidRepositoryID(String)
    case searchFailed(status: Int)
    case malformedResponse
    case gatedModel(String)
    case modelNotFound(String)
    case noModelFiles(String)
    case unsafeFilePath(String)
    case downloadFailed(file: String, status: Int)
    case incompleteDownload(file: String, expected: Int64, actual: Int64)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case storageAccessDenied(path: String)
    case storageBookmarkStale
    case unsupportedHardware
    case notInstalled(String)
    case loadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let id):
            "“\(id)” is not a valid Hugging Face repository ID."
        case .searchFailed(let status):
            "Hugging Face search failed (HTTP \(status))."
        case .malformedResponse:
            "Hugging Face returned a response The response could not be read."
        case .gatedModel(let id):
            "“\(id)” is gated and needs an access token."
        case .modelNotFound(let id):
            "“\(id)” was not found on Hugging Face."
        case .noModelFiles(let id):
            "“\(id)” has no model weights that MLX can load."
        case .unsafeFilePath(let path):
            "The repository lists a file path The app refuses to write: \(path)"
        case .downloadFailed(let file, let status):
            "Downloading \(file) failed (HTTP \(status))."
        case .incompleteDownload(let file, let expected, let actual):
            "\(file) arrived incomplete (\(actual) of \(expected) bytes)."
        case .insufficientDiskSpace(let required, let available):
            "Not enough free disk space: \(Self.format(required)) needed, \(Self.format(available)) available."
        case .storageAccessDenied(let path):
            "The app can no longer access the models folder at \(path)."
        case .storageBookmarkStale:
            "Permission for the models folder has expired."
        case .unsupportedHardware:
            "Local models run on MLX, which needs an Apple silicon Mac."
        case .notInstalled(let id):
            "“\(id)” is not downloaded."
        case .loadFailed(let reason):
            "The model could not be loaded: \(reason)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidRepositoryID:
            "Use the form owner/name, for example mlx-community/Qwen3-4B-4bit."
        case .searchFailed, .malformedResponse:
            "Check your connection and try again."
        case .gatedModel:
            "Accept the model’s license on huggingface.co, then add a read token in the model settings."
        case .modelNotFound:
            "Check the spelling, or search for the model instead."
        case .noModelFiles:
            "Pick a repository tagged “mlx” with safetensors weights."
        case .unsafeFilePath:
            "Do not download this repository."
        case .downloadFailed, .incompleteDownload:
            "Check your connection and start the download again."
        case .insufficientDiskSpace:
            "Free up space or choose another models folder in the model settings."
        case .storageAccessDenied, .storageBookmarkStale:
            "Choose the models folder again in the model settings."
        case .unsupportedHardware:
            "Use a Mac with an M-series chip."
        case .notInstalled:
            "Download the model first."
        case .loadFailed:
            "The architecture may not be supported yet. Try a different model."
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
