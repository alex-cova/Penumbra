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
}
