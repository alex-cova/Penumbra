import Foundation

struct HTTPPreparedRequest: Equatable, Sendable {
    let method: String
    let url: URL
    var headers: [String: String]
    let body: Data?
    /// `@no-redirect`, `@no-cookie-jar`, and `@no-auto-encoding` for this request.
    let options: HTTPRequestOptions
    /// `client.global.set` handlers to run after the response arrives.
    let bindings: [HTTPResponseBinding]
    /// `>>` / `>>!` response file, already checked so it stays in an allowed folder.
    let output: HTTPResponseOutput?
    /// Plain `Authorization: Digest user pass`. The header is not sent until the 401 challenge.
    let digest: HTTPDigestLogin?

    init(
        method: String,
        url: URL,
        headers: [String: String],
        body: Data?,
        options: HTTPRequestOptions = HTTPRequestOptions(),
        bindings: [HTTPResponseBinding] = [],
        output: HTTPResponseOutput? = nil,
        digest: HTTPDigestLogin? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.options = options
        self.bindings = bindings
        self.output = output
        self.digest = digest
    }
}

enum HTTPRequestParserError: Error, Equatable, LocalizedError {
    case parseFailed
    case noRequestAtCaret
    case unknownVariable(String)
    case cyclicVariable(String)
    case invalidTemplate(String)
    case missingHostHeader
    case invalidURL(String)
    case externalBodyNotFound(String)
    case responsePathNotAllowed(String)
    case unsupportedFeature(String)

    var errorDescription: String? {
        switch self {
        case .parseFailed:
            return "Could not parse the HTTP request file."
        case .noRequestAtCaret:
            return "No HTTP request found at the caret."
        case .unknownVariable(let name):
            return "Unknown variable {{\(name)}}."
        case .cyclicVariable(let name):
            return "Variable {{\(name)}} refers to itself."
        case .invalidTemplate(let expression):
            return "Could not evaluate {{\(expression)}}."
        case .missingHostHeader:
            return "Origin-form requests require a Host header."
        case .invalidURL(let value):
            return "Invalid request URL: \(value)"
        case .externalBodyNotFound(let path):
            return "External body file not found: \(path)"
        case .responsePathNotAllowed(let path):
            return "Response file must stay in the request folder or the HTTP history folder: \(path)"
        case .unsupportedFeature(let feature):
            return "Unsupported HTTP request feature: \(feature)"
        }
    }
}
