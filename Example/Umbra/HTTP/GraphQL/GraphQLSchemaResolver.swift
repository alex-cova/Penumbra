import Foundation

/// Turns a `###@scheme:` line into something the store can fetch: templates expanded with the
/// file's variables and the window's globals, a path made absolute against the file's folder, and
/// the headers of the first request below the line.
enum GraphQLSchemaResolver {
    enum ResolveError: Error, LocalizedError, Equatable {
        case unknownVariable(String)
        case notAnAddress(String)
        case needsSavedFile(String)

        var errorDescription: String? {
            switch self {
            case .unknownVariable(let name): "The variable {{\(name)}} is not defined."
            case .notAnAddress(let text): "“\(text)” is not an address."
            case .needsSavedFile(let text): "Save the file to read the schema at “\(text)”: the path is relative to it."
            }
        }
    }

    static func resolve(
        _ directive: HTTPGraphQLDirective,
        in text: String,
        fileURL: URL?,
        globals: [String: String]
    ) -> Result<GraphQLSchemaRequest, ResolveError> {
        let environment = HTTPTemplateEnvironment(
            fileVariables: HTTPSyntax.fileVariables(in: text),
            globals: globals,
            now: Date(),
            random: SystemHTTPRandom(),
            historyFolder: HTTPSyntax.historyDirectory()
        )
        let expanded: String
        do {
            expanded = try HTTPSyntax.expand(directive.url, in: environment).trimmingCharacters(in: .whitespaces)
        } catch let HTTPRequestParserError.unknownVariable(name) {
            return .failure(.unknownVariable(name))
        } catch {
            return .failure(.notAnAddress(directive.url))
        }
        guard let url = address(from: expanded, fileURL: fileURL) else {
            if expanded.hasPrefix("/") || expanded.hasPrefix("~") || expanded.contains("://") {
                return .failure(.notAnAddress(expanded))
            }
            return .failure(fileURL == nil ? .needsSavedFile(expanded) : .notAnAddress(expanded))
        }
        return .success(GraphQLSchemaRequest(
            url: url,
            headers: headers(forSchemaAt: url, after: directive, in: text, fileURL: fileURL, globals: globals)
        ))
    }

    private static func address(from text: String, fileURL: URL?) -> URL? {
        guard !text.isEmpty else { return nil }
        let lowered = text.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("file://") {
            guard let url = URL(string: text), url.host != nil || url.isFileURL else { return nil }
            return url
        }
        if text.contains("://") {
            return nil
        }
        let expanded = (text as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return URL(fileURLWithPath: expanded)
        }
        guard let fileURL else { return nil }
        return URL(fileURLWithPath: expanded, relativeTo: fileURL.deletingLastPathComponent()).standardizedFileURL
    }

    /// The first request after the directive, when it goes to the schema's own server: its
    /// credentials are the ones that server expects, and they are not sent anywhere else.
    private static func headers(
        forSchemaAt schemaURL: URL,
        after directive: HTTPGraphQLDirective,
        in text: String,
        fileURL: URL?,
        globals: [String: String]
    ) -> [String: String] {
        guard !schemaURL.isFileURL,
              let location = HTTPRequestParser.requestLocations(in: text)
                  .first(where: { $0.utf16Range.lowerBound >= directive.lineRange.upperBound }),
              let prepared = try? HTTPRequestParser.parse(
                  text: text, caretUTF16Offset: location.utf16Range.lowerBound, fileURL: fileURL, globals: globals
              ),
              prepared.url.scheme?.lowercased() == schemaURL.scheme?.lowercased(),
              prepared.url.host?.lowercased() == schemaURL.host?.lowercased(),
              prepared.url.port == schemaURL.port else {
            return [:]
        }
        return prepared.headers
    }
}
