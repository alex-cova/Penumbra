import Foundation

public struct HTTPResponseLog: Sendable {
    public enum Line: Sendable {
        case note(String)
        case response(String)
        case error(String)

        public var text: String {
            switch self {
            case .note(let text), .response(let text), .error(let text):
                return text
            }
        }
    }

    public static let maxLines = 10_000

    public private(set) var lines: [Line] = []
    public private(set) var runID = UUID()
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    public private(set) var statusCode: Int?
    public private(set) var duration: TimeInterval?

    public init() {}

    public var latestLine: String? {
        lines.last?.text
    }

    public mutating func reset() {
        lines = []
        runID = UUID()
        startedAt = Date()
        finishedAt = nil
        statusCode = nil
        duration = nil
    }

    public mutating func appendNote(_ text: String) {
        append(.note(text))
    }

    public mutating func appendResponse(_ text: String) {
        append(.response(text))
    }

    public mutating func appendError(_ text: String) {
        append(.error(text))
    }

    public mutating func markFinished(statusCode: Int?, duration: TimeInterval) {
        self.statusCode = statusCode
        self.duration = duration
        finishedAt = Date()
        appendNote(String(format: "Completed in %.0f ms", duration * 1000))
    }

    private mutating func append(_ line: Line) {
        lines.append(line)
        guard lines.count > Self.maxLines else { return }
        lines.removeFirst(lines.count - Self.maxLines)
    }
}

public enum HTTPClientError: Error, LocalizedError {
    case invalidResponse
    case transport(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an invalid HTTP response."
        case .transport(let error):
            return error.localizedDescription
        }
    }
}

public enum HTTPClient {
    public static let requestTimeout: TimeInterval = 30

    public static func send(
        _ request: HTTPPreparedRequest,
        session: URLSession = .shared
    ) async throws -> (HTTPURLResponse, Data) {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: requestTimeout)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw HTTPClientError.invalidResponse
            }
            return (httpResponse, data)
        } catch let error as HTTPClientError {
            throw error
        } catch {
            throw HTTPClientError.transport(error)
        }
    }

    public static func formatResponse(_ response: HTTPURLResponse, data: Data) -> String {
        var lines: [String] = []
        let version = "HTTP/1.1"
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        lines.append("\(version) \(response.statusCode) \(reason)")

        for (key, value) in response.allHeaderFields.sorted(by: { String(describing: $0.key) < String(describing: $1.key) }) {
            lines.append("\(key): \(value)")
        }

        lines.append("")

        if data.isEmpty {
            return lines.joined(separator: "\n")
        }

        if let contentType = response.value(forHTTPHeaderField: "Content-Type"),
           contentType.lowercased().contains("json"),
           let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let prettyText = String(data: pretty, encoding: .utf8) {
            lines.append(prettyText)
        } else if let text = String(data: data, encoding: .utf8) {
            lines.append(text)
        } else {
            lines.append("<\(data.count) bytes of binary data>")
        }

        return lines.joined(separator: "\n")
    }
}
