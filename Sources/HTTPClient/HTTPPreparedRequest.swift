import Foundation

public struct HTTPPreparedRequest: Equatable, Sendable {
    public let method: String
    public let url: URL
    public var headers: [String: String]
    public let body: Data?

    public init(method: String, url: URL, headers: [String: String], body: Data?) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public enum HTTPRequestParserError: Error, Equatable, LocalizedError {
    case parseFailed
    case noRequestAtCaret
    case unsupportedVariable
    case missingHostHeader
    case invalidURL(String)
    case externalBodyNotFound(String)
    case unsupportedFeature(String)

    public var errorDescription: String? {
        switch self {
        case .parseFailed:
            return "Could not parse the HTTP request file."
        case .noRequestAtCaret:
            return "No HTTP request found at the caret."
        case .unsupportedVariable:
            return "Environment variables ({{name}}) are not supported yet."
        case .missingHostHeader:
            return "Origin-form requests require a Host header."
        case .invalidURL(let value):
            return "Invalid request URL: \(value)"
        case .externalBodyNotFound(let path):
            return "External body file not found: \(path)"
        case .unsupportedFeature(let feature):
            return "Unsupported HTTP request feature: \(feature)"
        }
    }
}
