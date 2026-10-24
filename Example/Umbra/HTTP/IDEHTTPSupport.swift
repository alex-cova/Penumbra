import Foundation
import Observation
import SwiftUI

extension Color {
    /// Status colour for an HTTP response: 2xx green, 3xx blue, 4xx yellow, 5xx red, otherwise nil.
    static func httpStatus(_ code: Int) -> Color? {
        switch code {
        case 200..<300: .green
        case 300..<400: .blue
        case 400..<500: .yellow
        case 500..<600: .red
        default: nil
        }
    }
}

@MainActor
@Observable
final class IDEHTTPSupport {
    /// `client.global.set` values for this window. They are not written to disk.
    let globals = HTTPGlobalStore()
    /// Cookies collected by requests in this window. `@no-cookie-jar` skips it.
    let cookieJar = HTTPCookieJar()
    /// The schemas `###@scheme:` lines name, for GraphQL completion in this window's files.
    let graphQLSchemas = GraphQLSchemaStore()
    private(set) var responseLog = HTTPResponseLog()
    private(set) var isSending = false
    private var sendTask: Task<Void, Never>?
    /// What the last `send` was given, so the response panel can send the same request again.
    private var lastRequest: (text: String, caretUTF16Offset: Int, fileURL: URL?)?

    var canResend: Bool {
        lastRequest != nil && !isSending
    }

    func resend() {
        guard let lastRequest, !isSending else { return }
        send(text: lastRequest.text, caretUTF16Offset: lastRequest.caretUTF16Offset, fileURL: lastRequest.fileURL)
    }

    var lastStatusCode: Int? {
        responseLog.statusCode
    }

    var lastDuration: TimeInterval? {
        responseLog.duration
    }

    func cancel() {
        sendTask?.cancel()
        sendTask = nil
        isSending = false
    }

    func send(text: String, caretUTF16Offset: Int, fileURL: URL?) {
        cancel()
        lastRequest = (text, caretUTF16Offset, fileURL)
        responseLog.reset()
        isSending = true

        sendTask = Task { @MainActor in
            let started = Date()
            do {
                let prepared = try HTTPRequestParser.parse(
                    text: text,
                    caretUTF16Offset: caretUTF16Offset,
                    fileURL: fileURL,
                    globals: globals.snapshot(),
                    historyFolder: HTTPSyntax.historyDirectory()
                )
                responseLog.appendRequest(HTTPClient.formatRequest(prepared))
                let (response, data) = try await HTTPClient.send(
                    prepared,
                    cookies: prepared.options.useCookieJar ? cookieJar : nil
                )
                let formatted = HTTPClient.formatResponse(response, data: data)
                responseLog.appendResponse(formatted)
                let captured = HTTPResponseCapture.apply(bindings: prepared.bindings, data: data, store: globals)
                for note in captured.notes {
                    responseLog.appendNote(note)
                }
                for message in captured.errors {
                    responseLog.appendError(message)
                }
                let output = prepared.output ?? HTTPResponseDownload.output(
                    for: response,
                    data: data,
                    requestURL: prepared.url,
                    folder: HTTPSyntax.historyDirectory()
                )
                if let output {
                    do {
                        let written = try HTTPResponseFiles.write(data, to: output)
                        responseLog.appendSavedFile(written)
                    } catch {
                        responseLog.appendError(error.localizedDescription)
                    }
                }
                responseLog.markFinished(
                    statusCode: response.statusCode,
                    duration: Date().timeIntervalSince(started)
                )
            } catch let error as HTTPRequestParserError {
                responseLog.appendError(error.localizedDescription)
                responseLog.markFinished(statusCode: nil, duration: Date().timeIntervalSince(started))
            } catch let error as HTTPClientError {
                responseLog.appendError(error.localizedDescription)
                responseLog.markFinished(statusCode: nil, duration: Date().timeIntervalSince(started))
            } catch {
                responseLog.appendError(error.localizedDescription)
                responseLog.markFinished(statusCode: nil, duration: Date().timeIntervalSince(started))
            }
            isSending = false
            sendTask = nil
        }
    }

    // MARK: - GraphQL schemas

    /// Starts loading the schema of every `###@scheme:` line in `text`, so the first completion in a
    /// GraphQL body finds it. The store decides which addresses it may fetch on its own.
    func prefetchSchemas(in text: String, fileURL: URL?) {
        guard text.contains("@scheme") else { return }
        let directives = HTTPGraphQLDirective.directives(in: text)
        guard !directives.isEmpty else { return }
        let globals = self.globals.snapshot()
        let store = graphQLSchemas
        for directive in directives {
            guard case .success(let request) = GraphQLSchemaResolver.resolve(
                directive, in: text, fileURL: fileURL, globals: globals
            ) else { continue }
            Task { await store.prefetch(request) }
        }
    }

    /// HTTP: Refresh GraphQL Schema. Fetches the schema in effect at the caret now, and reports in the
    /// response log.
    func refreshSchema(text: String, caretUTF16Offset: Int, fileURL: URL?) {
        responseLog.reset()
        guard let directive = HTTPGraphQLDirective.directive(in: text, caretUTF16: caretUTF16Offset) else {
            responseLog.appendError("There is no ###@scheme:<url> line above the caret.")
            responseLog.markFinished(statusCode: nil, duration: 0)
            return
        }
        let request: GraphQLSchemaRequest
        switch GraphQLSchemaResolver.resolve(directive, in: text, fileURL: fileURL, globals: globals.snapshot()) {
        case .failure(let error):
            responseLog.appendError(error.localizedDescription)
            responseLog.markFinished(statusCode: nil, duration: 0)
            return
        case .success(let resolved):
            request = resolved
        }
        let address = request.url.isFileURL ? request.url.path : request.url.absoluteString
        responseLog.appendNote("Loading GraphQL schema from \(address)")
        let started = Date()
        let store = graphQLSchemas
        Task { @MainActor in
            do {
                let schema = try await store.refresh(request)
                let count = schema.types.values.filter { !$0.name.hasPrefix("__") }.count
                responseLog.appendNote("Loaded \(count) types from \(address)")
            } catch {
                responseLog.appendError("Could not load the schema: \(error.localizedDescription)")
            }
            responseLog.markFinished(statusCode: nil, duration: Date().timeIntervalSince(started))
        }
    }
}
