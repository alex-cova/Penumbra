import Foundation
import Observation

@MainActor
@Observable
final class IDEHTTPSupport {
    /// `client.global.set` values for this window. They are not written to disk.
    let globals = HTTPGlobalStore()
    /// Cookies collected by requests in this window. `@no-cookie-jar` skips it.
    let cookieJar = HTTPCookieJar()
    private(set) var responseLog = HTTPResponseLog()
    private(set) var isSending = false
    private var sendTask: Task<Void, Never>?

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
}
