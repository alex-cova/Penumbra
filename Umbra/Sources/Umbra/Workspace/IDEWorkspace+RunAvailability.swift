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
            runEligibility.httpFileCanSend = false
        }
    }

    /// Puts a `play.fill` button in the gutter on the first line of every request in an `.http`
    /// file. Clicking one sends that request, wherever the caret is.
    func refreshHTTPGutter(from textView: TextView, fileURL: URL?, text: String) {
        let stamp = HTTPGutterStamp(
            view: ObjectIdentifier(textView),
            documentID: workbench.activePane.selectedDocument?.id,
            generation: textView.contentGeneration
        )
        guard stamp != httpGutterStamp else { return }
        httpGutterStamp = stamp
        let locations = HTTPRequestParser.requestLocations(in: text)
        runEligibility.httpFileCanSend = !locations.isEmpty
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
        documentSettle.schedule(textView: textView, id: "runAvailability", phase: .language, after: settleDelay) { [weak self] textView, snapshot in
            guard let self else { return }
            await self.refreshJavaRunAvailabilityNow(from: textView, snapshot: snapshot)
        }
    }

    /// Whether Run and Test apply and where the gutter's buttons go, for the buffer as it is once
    /// typing pauses. The run providers read the text (does this file have a `main`, where are its
    /// tests); on a piece-tree buffer that is a whole-document copy, so it is built once, off the
    /// main actor, for both the button and the gutter. A buffer edited again meanwhile is left to
    /// the refresh that edit scheduled.
    func refreshJavaRunAvailabilityNow(
        from textView: TextView, snapshot: DocumentSettleCoordinator.Snapshot? = nil
    ) async {
        let document = workbench.activePane.selectedDocument
        let documentID = document?.id
        let isJava = document?.languageIdentifier == "java"
        let fileURL = document?.url
        if let snapshot, (textView.contentGeneration != snapshot.generation
            || workbench.activePane.selectedDocument?.id != documentID) { return }
        let readsText = document.map { databaseSupport.consoles[$0.id] == nil && $0.languageIdentifier != "http" } ?? true
        var content = snapshot?.text
        if readsText, activeRunProvider != nil, content == nil {
            guard let taken = await textView.snapshotText(),
                  textView.contentGeneration == taken.generation,
                  workbench.activePane.selectedDocument?.id == documentID else { return }
            content = taken.text
        }
        if let provider = activeRunProvider {
            runEligibility.runFileCanRun = provider.canRun(IDERunDocument(
                url: fileURL, languageIdentifier: document?.languageIdentifier, text: content ?? ""
            ))
        } else {
            runEligibility.runFileCanRun = false
        }
        runEligibility.runFileURL = fileURL
        // One owner per editor for the gutter icons: query consoles get execute buttons, HTTP
        // files get send buttons, everything else goes through the Java path, which also clears
        // the gutter for non-Java files.
        if let document, databaseSupport.consoles[document.id] != nil {
            httpGutterStamp = nil
            refreshDatabaseGutter(from: textView)
        } else if document?.languageIdentifier == "http" {
            databaseGutterStamp = nil
            if let content {
                refreshHTTPGutter(from: textView, fileURL: fileURL, text: content)
            }
        } else {
            httpGutterStamp = nil
            databaseGutterStamp = nil
            await refreshJavaTestDecorations(from: textView, fileURL: fileURL, isJava: isJava, content: content)
        }
    }

    /// Breakpoints on a Java file, and run buttons from the active run provider on any file. A click
    /// on a breakpoint removes it, a click on a run button opens its Run / Debug menu, and a click
    /// on any other Java line number adds a breakpoint. A file that is not Java gets run buttons
    /// only, and only when its provider names locations.
    func refreshJavaTestDecorations(from textView: TextView, fileURL: URL?, isJava: Bool, content: String? = nil) async {
        let language = isJava ? "java" : workbench.activePane.selectedDocument?.languageIdentifier
        let runDocument = IDERunDocument(
            url: fileURL, languageIdentifier: language,
            caretUTF16Offset: textView.selectedRange.location, text: content ?? textView.text
        )
        let provider = runProviders.provider(forLanguage: language)
        let locations = await provider?.runnableLocations(in: runDocument) ?? []
        // Typing resumed while the locations were worked out: the pause after it refreshes again.
        guard !Task.isCancelled else { return }
        let wantsBreakpoints = isJava || language == "swift" || language == "javascript" || language == "typescript"
        guard wantsBreakpoints, let fileURL else {
            runEligibility.javaFileCanTest = false
            runEligibility.activeJavaTestClass = nil
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
            runEligibility.javaFileCanTest = false
            runEligibility.activeJavaTestClass = nil
            applyJavaGutter(JavaGutterContent(fileURL: fileURL, locations: locations), to: textView)
            return
        }
        if await javaSupport.isTestSource(file: fileURL) {
            let testClass = await javaSupport.tests(for: fileURL)
            runEligibility.activeJavaTestClass = testClass
            runEligibility.javaFileCanTest = !(testClass?.methods.isEmpty ?? true)
        } else {
            runEligibility.javaFileCanTest = false
            runEligibility.activeJavaTestClass = nil
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
        let locations = await runDetached(priority: .utility) {
            JavaMainMethod.containsMain(in: text) ? JavaMainMethod.locations(in: text, fileName: fileName) : []
        }
        javaMainLocations = JavaMainLocations(view: view, generation: generation, locations: locations)
        return locations
    }
}
