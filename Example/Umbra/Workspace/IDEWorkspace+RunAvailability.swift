import AppKit
import EditorIntelligence
import Foundation
import JavaIntelligence
import Penumbra

/// What the window works out about the active editor once typing pauses: whether Run and Test apply,
/// the gutter's send and run buttons, and the `main` methods of a buffer. The Run button catches up
/// a debounce after an edit, never on the keystroke.
extension IDEWorkspace {
    /// Only clears the flag for a non-HTTP editor. Whether an HTTP file has a request to send comes
    /// from `refreshHTTPGutter`, on the same debounce as the Java run button: parsing the whole
    /// buffer on every caret move or keystroke would put document size on the typing path.
    func refreshHTTPSendAvailability(from textView: TextView) {
        if workbench.activePane.selectedDocument?.languageIdentifier != "http" {
            httpFileCanSend = false
        }
    }

    /// Puts a `play.fill` button in the gutter on the first line of every request in an `.http`
    /// file. Clicking one sends that request, wherever the caret is.
    func refreshHTTPGutter(from textView: TextView, fileURL: URL?) {
        let stamp = HTTPGutterStamp(
            view: ObjectIdentifier(textView),
            documentID: workbench.activePane.selectedDocument?.id,
            generation: textView.contentGeneration
        )
        guard stamp != httpGutterStamp else { return }
        httpGutterStamp = stamp
        let text = textView.text
        let locations = HTTPRequestParser.requestLocations(in: text)
        httpFileCanSend = !locations.isEmpty
        httpSupport.prefetchSchemas(in: text, fileURL: fileURL)
        textView.reservedLineMarkerSlots = IDEEditorOverlayController.reservedLineMarkerSlots(languageIdentifier: "http", hasMarkerProvider: false)
        textView.setGutterDecorations(locations.map {
            GutterDecoration(line: $0.startLine, symbolName: "play.fill", accessibilityLabel: "Send Request", placement: .lineMarkerColumn)
        })
        textView.gutterDecorationHandler = { [weak self, weak textView] line in
            guard let self, let textView else { return }
            self.sendHTTPRequest(atLine: line, from: textView, fileURL: fileURL)
        }
        // A Java file shown here before left its breakpoint handlers; they must not see this file.
        textView.gutterLineClickHandler = nil
        textView.gutterDecorationsDidMove = nil
        textView.alwaysShowGutterDecorationColumn = false
    }

    /// Parses fresh at click time: the buttons may be one debounce behind an edit.
    func sendHTTPRequest(atLine line: Int, from textView: TextView, fileURL: URL?) {
        guard HTTPRequestParser.requestLocations(in: textView.text).contains(where: { $0.startLine == line }) else {
            return
        }
        showHTTPResponse()
        Task { @MainActor [weak self, weak textView] in
            await self?.saveHTTPFileBeforeSending(at: fileURL)
            guard let self, let textView else { return }
            // Parse again: the buffer may have changed while the file was being written.
            let text = textView.text
            guard let location = HTTPRequestParser.requestLocations(in: text).first(where: { $0.startLine == line }) else {
                return
            }
            self.httpSupport.send(text: text, caretUTF16Offset: location.utf16Range.lowerBound, fileURL: fileURL)
        }
    }

    func refreshJavaRunAvailability(from textView: TextView) {
        javaRunAvailability.schedule(after: .milliseconds(300)) { [weak self, weak textView] in
            guard let self, let textView else { return }
            self.refreshJavaRunAvailabilityNow(from: textView)
        }
    }

    /// `containsMain` copies the whole buffer. That stays off the keystroke; the Run button
    /// catches up once typing pauses.
    func refreshJavaRunAvailabilityNow(from textView: TextView) {
        let document = workbench.activePane.selectedDocument
        let isJava = document?.languageIdentifier == "java"
        let fileURL = document?.url
        if let provider = activeRunProvider {
            runFileCanRun = provider.canRun(IDERunDocument(
                url: fileURL, languageIdentifier: document?.languageIdentifier, text: textView.text
            ))
        } else {
            runFileCanRun = false
        }
        runFileURL = fileURL
        // One owner per editor for the gutter icons: query consoles get execute buttons, HTTP
        // files get send buttons, everything else goes through the Java path, which also clears
        // the gutter for non-Java files.
        if let document, databaseSupport.consoles[document.id] != nil {
            httpGutterStamp = nil
            refreshDatabaseGutter(from: textView)
        } else if document?.languageIdentifier == "http" {
            databaseGutterStamp = nil
            refreshHTTPGutter(from: textView, fileURL: fileURL)
        } else {
            httpGutterStamp = nil
            databaseGutterStamp = nil
            Task { await refreshJavaTestDecorations(from: textView, fileURL: fileURL, isJava: isJava) }
        }
    }

    /// Breakpoints on a Java file, and run buttons from the active run provider on any file. A click
    /// on a breakpoint removes it, a click on a run button opens its Run / Debug menu, and a click
    /// on any other Java line number adds a breakpoint. A file that is not Java gets run buttons
    /// only, and only when its provider names locations.
    func refreshJavaTestDecorations(from textView: TextView, fileURL: URL?, isJava: Bool) async {
        let language = isJava ? "java" : workbench.activePane.selectedDocument?.languageIdentifier
        let runDocument = IDERunDocument(
            url: fileURL, languageIdentifier: language,
            caretUTF16Offset: textView.selectedRange.location, text: textView.text
        )
        let provider = runProviders.provider(forLanguage: language)
        let locations = await provider?.runnableLocations(in: runDocument) ?? []
        let wantsBreakpoints = isJava || language == "swift" || language == "javascript" || language == "typescript"
        guard wantsBreakpoints, let fileURL else {
            javaFileCanTest = false
            activeJavaTestClass = nil
            guard let fileURL, !locations.isEmpty else {
                textView.setGutterDecorations([])
                textView.gutterDecorationHandler = nil
                textView.gutterLineClickHandler = nil
                textView.gutterDecorationsDidMove = nil
                textView.alwaysShowGutterDecorationColumn = false
                return
            }
            applyRunLocationGutter(fileURL: fileURL, locations: locations, to: textView)
            return
        }
        guard isJava else {
            javaFileCanTest = false
            activeJavaTestClass = nil
            applyJavaGutter(JavaGutterContent(fileURL: fileURL, locations: locations), to: textView)
            return
        }
        if await javaSupport.isTestSource(file: fileURL) {
            let testClass = await javaSupport.tests(for: fileURL)
            activeJavaTestClass = testClass
            javaFileCanTest = !(testClass?.methods.isEmpty ?? true)
        } else {
            javaFileCanTest = false
            activeJavaTestClass = nil
        }
        applyJavaGutter(JavaGutterContent(fileURL: fileURL, locations: locations), to: textView)
    }

    /// The `main` methods in `textView`'s buffer, parsed off the main thread and reused until the
    /// buffer changes. `containsMain` screens out the common file without one before parsing.
    func mainLocations(in textView: TextView, fileName: String?) async -> [JavaMainMethodLocation] {
        let view = ObjectIdentifier(textView)
        let generation = textView.contentGeneration
        if let cached = javaMainLocations, cached.view == view, cached.generation == generation {
            return cached.locations
        }
        let text = textView.text
        let locations = await Task.detached(priority: .utility) {
            JavaMainMethod.containsMain(in: text) ? JavaMainMethod.locations(in: text, fileName: fileName) : []
        }.value
        javaMainLocations = JavaMainLocations(view: view, generation: generation, locations: locations)
        return locations
    }
}
