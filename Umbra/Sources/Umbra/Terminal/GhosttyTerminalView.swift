import AppKit
import CoreText
import Foundation
import GhosttyVt

/// Ghostty-backed terminal view: owns one `GhosttyVtTerminal` (VT state),
/// one `GhosttyPtyProcess` (shell), and the key/mouse encoders, and renders
/// the viewport grid with CoreText.
///
/// Threading: the C terminal lives on its own serial queue (`withTerminal`);
/// PTY output arrives on the process I/O queue and is fed straight into the
/// terminal; drawing pulls value snapshots (`GhosttyRenderSnapshot`) on the
/// main thread. Redraws are coalesced by AppKit (`needsDisplay`).
///
/// Parity slices still to come (see the plan's checklist): scrollback
/// viewing + scrollbar, IME/marked text, VoiceOver, drag-and-drop,
/// context menu, scroll-wheel when the app is not tracking the mouse.
final class GhosttyTerminalView: NSView {
    // MARK: - Host callbacks

    var onTitleUpdate: ((String) -> Void)?
    var onDirectoryUpdate: ((URL) -> Void)?
    var onProcessTerminated: (() -> Void)?

    /// Whether Option acts as Meta (matches SwiftTerm's `optionAsMetaKey`).
    var optionAsMeta = true

    // MARK: - Backend

    private var terminal: GhosttyVtTerminal?
    private let process = GhosttyPtyProcess()
    private var keyEncoder: GhosttyKeystrokeEncoder?
    private var mouseEncoder: GhosttyMouseReportEncoder?
    private var mirrorsOutput = false
    private var started = false
    private var startConfig: (executable: String, execName: String, directory: String)?

    // MARK: - Appearance

    private var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var backgroundColor: NSColor = .textBackgroundColor
    private var foregroundColor: NSColor = .textColor
    private var cursorColor: NSColor = .controlAccentColor
    private var gridLayout = GhosttyGridLayout(cellWidth: 8, cellHeight: 16, cols: 80, rows: 24)
    private var baseCTFont: CTFont!
    private var styledFonts: [FontTraits: CTFont] = [:]
    private var colorCache: [UInt32: NSColor] = [:]
    private var bellFlashUntil = Date.distantPast

    // MARK: - Scrollback viewing

    /// Overlay scrollbar; created lazily so headless tests never touch it.
    private var scroller: NSScroller?
    /// Accumulated precise wheel pixels waiting to cross one full row.
    private var wheelRemainder: CGFloat = 0
    /// True while the viewport is parked above the live area. New output
    /// does not yank it back (Apple Terminal behavior); typing does.
    private var isScrolledUp = false

    private struct FontTraits: Hashable {
        var bold = false
        var italic = false
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        rebuildFonts()
        ensureBlinkTimer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Host API

    func setMirrorsOutput(_ mirror: Bool) {
        mirrorsOutput = mirror
    }

    func applyFont(_ newFont: NSFont) {
        font = newFont
        rebuildFonts()
        relayout()
        needsDisplay = true
    }

    func applyColors(background: NSColor, foreground: NSColor, cursor: NSColor) {
        backgroundColor = background
        foregroundColor = foreground
        cursorColor = cursor
        needsDisplay = true
    }

    /// Starts the shell. Idempotent: safe to call on every layout while the
    /// process is already running.
    func startProcess(executable: String, execName: String, currentDirectory: String) {
        startConfig = (executable, execName, currentDirectory)
        guard !mirrorsOutput else { return }
        guard !process.running else { return }
        ensureBackend()
        process.start(
            executable: executable,
            execName: execName,
            currentDirectory: currentDirectory,
            environment: nil,
            cols: gridLayout.cols,
            rows: gridLayout.rows)
        started = true
    }

    /// Mirror-tab path: parses bytes with no process behind them.
    func feedOutput(_ text: String) {
        ensureBackend()
        terminal?.write(Data(text.utf8))
        needsDisplay = true
    }

    /// Sends raw bytes to the shell (Ctrl-L after clear, query replies).
    func send(_ data: Data) {
        if process.running {
            process.write(data)
        }
    }

    func recentText(lines: Int) -> String? {
        terminal?.recentText(lines: lines)
    }

    func restartProcess() {
        guard !mirrorsOutput else { return }
        process.terminate()
        started = false
        if let config = startConfig {
            startProcess(
                executable: config.executable,
                execName: config.execName,
                currentDirectory: config.directory)
        }
    }

    func terminateProcess() {
        process.terminate()
        started = false
    }

    // MARK: - Backend wiring

    /// Whether the shell is currently running.
    var isProcessRunning: Bool { process.running }

    /// The shell pid while running, -1 otherwise (for SIGHUP parity).
    var shellPid: pid_t { process.shellPid }

    /// View-level default cursor, matching the old SwiftTerm
    /// `setCursorStyle(.steadyBar)`. Apps may override it; RIS returns to
    /// the parser default (a divergence from SwiftTerm, which restores the
    /// view default — recorded in the plan's Risks).
    private var initialCursorSequence = "\u{1B}[6 q"

    private func ensureBackend() {
        if terminal == nil {
            terminal = GhosttyVtTerminal(cols: gridLayout.cols, rows: gridLayout.rows)
            keyEncoder = GhosttyKeystrokeEncoder()
            mouseEncoder = GhosttyMouseReportEncoder()
            terminal?.onEvent = { [weak self] event in
                DispatchQueue.main.async { [weak self] in self?.handleTerminalEvent(event) }
            }
            process.onOutput = { [weak self] data in
                self?.terminal?.write(data)
                DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
            }
            process.onExit = { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.started = false
                    self?.needsDisplay = true
                    self?.onProcessTerminated?()
                }
            }
            terminal?.write(Data(initialCursorSequence.utf8))
        }
    }

    private func handleTerminalEvent(_ event: GhosttyVtEvent) {
        // Already on the main thread (hopped in onEvent).
        switch event {
        case let .titleChanged(title):
            onTitleUpdate?(title)
        case let .pwdChanged(path):
            if let url = GhosttyTerminalView.directoryURL(fromOSC7: path) {
                onDirectoryUpdate?(url)
            }
        case .bell:
            // Visual bell: NSBeep is unavailable to Swift in this SDK, and a
            // flash suits an editor better than a system beep anyway.
            bellFlashUntil = Date().addingTimeInterval(0.15)
            needsDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.needsDisplay = true
            }
        case let .writePty(data):
            process.write(data)
        }
    }

    /// OSC 7 payloads arrive as `file://host/path`, `file:///path` or a bare
    /// path depending on the shell; normalize to a file URL.
    static func directoryURL(fromOSC7 payload: String) -> URL? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("file://") {
            guard let url = URL(string: trimmed), url.isFileURL else { return nil }
            return url
        }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        relayout()
    }

    private func rebuildFonts() {
        baseCTFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        styledFonts.removeAll()
    }

    private func relayout() {
        let metrics = Self.cellMetrics(for: baseCTFont)
        let newLayout = GhosttyGridLayout.fitting(
            boundsSize: bounds.size,
            cellWidth: metrics.width,
            cellHeight: metrics.height)
        let sizeChanged = newLayout.cols != gridLayout.cols || newLayout.rows != gridLayout.rows
        gridLayout = newLayout
        scroller?.frame = scrollerFrame()
        guard sizeChanged else { return }
        // A resize can clamp a parked viewport; re-read so the flag and
        // knob never describe a stale offset.
        refreshScrollState()
        colorCache.removeAll()
        if let term = terminal {
            let px = newLayout.pixelCellSize(scale: window?.backingScaleFactor ?? 1)
            term.resize(cols: newLayout.cols, rows: newLayout.rows,
                        cellWidthPx: Int(px.width), cellHeightPx: Int(px.height))
        }
        process.setWindowSize(cols: newLayout.cols, rows: newLayout.rows)
        needsDisplay = true
    }

    private static func cellMetrics(for ctFont: CTFont) -> (width: CGFloat, height: CGFloat) {
        let sample = NSAttributedString(string: "MMMMMMMMMM", attributes: [.font: ctFont])
        let line = CTLineCreateWithAttributedString(sample)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil) / 10
        let height = ceil(CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont))
        return (max(width, 1), max(height, 1))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        backgroundColor.setFill()
        context.fill(bounds)

        guard let term = terminal,
              let snapshot = term.renderSnapshot(),
              !snapshot.grid.isEmpty
        else { return }
        refreshScrollState()

        // CoreText draws glyphs in text space: under AppKit's flipped CTM
        // (this view isFlipped) the identity text matrix renders every glyph
        // upside down. Flipping the text matrix makes outlines upright while
        // keeping textPosition and advances in the view's coordinates
        // (horizontal advances are unaffected by a y-flip). Fills are
        // unaffected — only CTLineDraw reads the text matrix.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        let rows = min(snapshot.grid.count, gridLayout.rows)
        for row in 0..<rows {
            drawRow(snapshot.grid[row], row: row, snapshot: snapshot, context: context)
        }
        drawSelection(snapshot: snapshot, context: context)
        drawCursor(snapshot.cursor, context: context)
        lastCursorBlinking = snapshot.cursor.blinking
        if bellFlashUntil > Date() {
            cursorColor.withAlphaComponent(0.12).setFill()
            context.fill(bounds)
        }
    }

    private func drawRow(
        _ row: GhosttySnapshotRow,
        row y: Int,
        snapshot: GhosttyRenderSnapshot,
        context: CGContext
    ) {
        let yOrigin = CGFloat(y) * gridLayout.cellHeight
        var col = 0
        while col < row.cells.count {
            let first = row.cells[col]
            var end = col + 1
            while end < row.cells.count, GhosttyTerminalView.sameRun(row.cells[end], first) {
                end += 1
            }
            drawRun(cells: row.cells[col..<end], col: col, row: y, yOrigin: yOrigin,
                    snapshot: snapshot, context: context)
            col = end
        }
    }

    private static func sameRun(_ a: GhosttySnapshotCell, _ b: GhosttySnapshotCell) -> Bool {
        a.fg == b.fg && a.bg == b.bg && a.bold == b.bold && a.italic == b.italic
            && a.underline == b.underline && a.inverse == b.inverse
            && a.strikethrough == b.strikethrough && a.faint == b.faint
            && a.blink == b.blink && a.invisible == b.invisible
    }

    private func drawRun(
        cells: ArraySlice<GhosttySnapshotCell>,
        col: Int,
        row _: Int,
        yOrigin: CGFloat,
        snapshot: GhosttyRenderSnapshot,
        context: CGContext
    ) {
        guard let first = cells.first else { return }
        var fg: NSColor = first.fg.map(nsColor) ?? foregroundColor
        var bg: NSColor? = first.bg.map(nsColor)
        if first.inverse {
            let oldFG = fg
            fg = bg ?? backgroundColor
            bg = oldFG
        }
        let resolvedBG = bg ?? backgroundColor
        if resolvedBG != backgroundColor {
            resolvedBG.setFill()
            context.fill(CGRect(x: CGFloat(col) * gridLayout.cellWidth, y: yOrigin,
                                width: CGFloat(cells.count) * gridLayout.cellWidth,
                                height: gridLayout.cellHeight))
        }
        if first.invisible { return }
        let text = cells.map(\.text).joined()
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: styledFont(bold: first.bold, italic: first.italic),
            .foregroundColor: first.faint ? fg.withAlphaComponent(0.6) : fg,
        ]
        if first.underline != 0 { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if first.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: CGFloat(col) * gridLayout.cellWidth, y: yOrigin + CTFontGetAscent(baseCTFont))
        // Blinking text hides on the off phase; steady otherwise.
        if !first.blink || blinkPhaseOn {
            CTLineDraw(line, context)
        }
    }

    private var blinkPhaseOn = true

    private func styledFont(bold: Bool, italic: Bool) -> CTFont {
        let traits = FontTraits(bold: bold, italic: italic)
        if let cached = styledFonts[traits] { return cached }
        var symbolic = CTFontSymbolicTraits()
        if bold { symbolic.insert(.boldTrait) }
        if italic { symbolic.insert(.italicTrait) }
        let derived = CTFontCreateCopyWithSymbolicTraits(
            baseCTFont, 0, nil, symbolic, symbolic) ?? baseCTFont!
        styledFonts[traits] = derived
        return derived
    }

    private func nsColor(_ rgb: GhosttyRGB) -> NSColor {
        let key = (UInt32(rgb.r) << 16) | (UInt32(rgb.g) << 8) | UInt32(rgb.b)
        if let cached = colorCache[key] { return cached }
        let color = NSColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255,
                            blue: CGFloat(rgb.b) / 255, alpha: 1)
        colorCache[key] = color
        return color
    }

    private func drawSelection(snapshot: GhosttyRenderSnapshot, context: CGContext) {
        guard hasSelection, let selection = orderedSelection() else { return }
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35).setFill()
        let lastRow = min(selection.to.row, snapshot.grid.count - 1)
        for row in selection.from.row...max(lastRow, selection.from.row) {
            guard row < snapshot.grid.count, row < gridLayout.rows else { break }
            let cells = snapshot.grid[row].cells.count
            let startCol = (row == selection.from.row) ? selection.from.col : 0
            let endCol = (row == selection.to.row) ? min(selection.to.col, cells - 1) : cells - 1
            guard startCol <= endCol, startCol < cells else { continue }
            context.fill(gridLayout.rectForCells(col: startCol, row: row, count: endCol - startCol + 1))
        }
    }

    private func drawCursor(_ cursor: GhosttySnapshotCursor, context: CGContext) {
        guard cursor.hasPosition, cursor.visible,
              cursor.y < gridLayout.rows, cursor.x < gridLayout.cols
        else { return }
        if cursor.blinking, !blinkPhaseOn, window?.firstResponder == self { return }
        let rect = CGRect(x: CGFloat(cursor.x) * gridLayout.cellWidth,
                          y: CGFloat(cursor.y) * gridLayout.cellHeight,
                          width: gridLayout.cellWidth, height: gridLayout.cellHeight)
        cursorColor.setFill()
        switch cursor.style {
        case .block:
            context.fill(rect)
        case .bar:
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: max(2, gridLayout.cellWidth / 8), height: rect.height))
        case .underline:
            context.fill(CGRect(x: rect.minX, y: rect.maxY - max(2, gridLayout.cellHeight / 8), width: rect.width, height: max(2, gridLayout.cellHeight / 8)))
        case .hollow:
            context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard !mirrorsOutput else { return }
        ensureBackend()
        guard let term = terminal, let keyEncoder else { return }
        if hasSelection { clearSelection() }
        // Typing resumes at the prompt: park the viewport back at live.
        snapToBottom()
        let keystroke = GhosttyKeystroke(
            keyCode: UInt16(event.keyCode),
            modifiers: GhosttyModifiers(appKitFlags: event.modifierFlags),
            text: event.characters ?? "",
            unshiftedText: event.charactersIgnoringModifiers,
            isRepeat: event.isARepeat)
        let bytes: Data? = term.withTerminal { terminal in
            keyEncoder.syncToTerminal(terminal, optionAsMeta: optionAsMeta)
            return keyEncoder.encode(keystroke)
        }
        if let bytes {
            process.write(bytes)
        }
        // Swallow the key: the shell echoes.
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        needsDisplay = true
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        needsDisplay = true
        return ok
    }

    // MARK: - Cursor blink

    private var blinkTimer: Timer?
    private var lastCursorBlinking = false

    private func ensureBlinkTimer() {
        guard blinkTimer == nil else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self, self.lastCursorBlinking, self.window?.firstResponder == self else { return }
            self.blinkPhaseOn.toggle()
            self.needsDisplay = true
        }
    }

    // MARK: - Selection

    /// Viewport-cell selection anchor/active ends, ordered on read.
    private var selectionAnchor: (col: Int, row: Int)?
    private var selectionActive: (col: Int, row: Int)?

    private var hasSelection: Bool {
        selectionAnchor != nil && selectionActive != nil
    }

    private func orderedSelection() -> (from: (col: Int, row: Int), to: (col: Int, row: Int))? {
        guard let a = selectionAnchor, let b = selectionActive else { return nil }
        if (a.row, a.col) <= (b.row, b.col) { return (a, b) }
        return (b, a)
    }

    func clearSelection() {
        selectionAnchor = nil
        selectionActive = nil
        needsDisplay = true
    }

    func selectAll() {
        selectionAnchor = (0, 0)
        selectionActive = (gridLayout.cols - 1, gridLayout.rows - 1)
        needsDisplay = true
    }

    /// Selected text honoring soft wraps (see `GhosttySelectionText`).
    func selectedText() -> String? {
        guard let selection = orderedSelection(),
              let snapshot = terminal?.renderSnapshot()
        else { return nil }
        return GhosttySelectionText.text(in: snapshot, from: selection.from, to: selection.to)
    }

    func copySelectionToPasteboard() {
        guard let text = selectedText() else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    func pasteFromPasteboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        var payload = text.replacingOccurrences(of: "\r\n", with: "\n")
        payload = payload.replacingOccurrences(of: "\r", with: "\n")
        if terminal?.isModeSet(GhosttyTerminalModes.bracketedPaste) == true {
            payload = "\u{1B}[200~" + payload + "\u{1B}[201~"
        }
        process.write(Data(payload.utf8))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder == self else { return false }
        // Command-only shortcuts (Shift tolerated for keyboards that need it).
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.option),
           !event.modifierFlags.contains(.function)
        {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                copySelectionToPasteboard()
                return true
            case "v":
                pasteFromPasteboard()
                return true
            case "a":
                selectAll()
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Mouse

    private var pressedButtons: Set<Int> = []

    private func encoderGeometry() -> (screenW: UInt32, screenH: UInt32, cellW: UInt32, cellH: UInt32, scale: CGFloat) {
        let scale = window?.backingScaleFactor ?? 1
        return (
            UInt32(clamping: Int((bounds.width * scale).rounded(.down))),
            UInt32(clamping: Int((bounds.height * scale).rounded(.down))),
            UInt32(clamping: Int((gridLayout.cellWidth * scale).rounded(.down))),
            UInt32(clamping: Int((gridLayout.cellHeight * scale).rounded(.down))),
            scale)
    }

    private func mousePosition(from event: NSEvent) -> (x: Float, y: Float) {
        let scale = window?.backingScaleFactor ?? 1
        let point = convert(event.locationInWindow, from: nil)
        return (Float(point.x * scale), Float(point.y * scale))
    }

    private func appWantsMouse() -> Bool {
        guard let term = terminal else { return false }
        return term.isModeSet(GhosttyTerminalModes.x10Mouse)
            || term.isModeSet(GhosttyTerminalModes.normalMouse)
            || term.isModeSet(GhosttyTerminalModes.buttonMouse)
            || term.isModeSet(GhosttyTerminalModes.anyMouse)
    }

    private func sendMouseReport(_ report: GhosttyMouseReport) {
        guard let term = terminal, let mouseEncoder else { return }
        let geo = encoderGeometry()
        let bytes: Data? = term.withTerminal { terminal in
            mouseEncoder.syncToTerminal(
                terminal, screenWidth: geo.screenW, screenHeight: geo.screenH,
                cellWidth: geo.cellW, cellHeight: geo.cellH,
                anyButtonPressed: !self.pressedButtons.isEmpty)
            return mouseEncoder.encode(report)
        }
        if let bytes { process.write(bytes) }
    }

    private func mouseButton(for event: NSEvent) -> GhosttyMouseReport.Button? {
        switch event.buttonNumber {
        case 0: return .left
        case 1: return .right
        case 2: return .middle
        default: return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        ensureBackend()
        if appWantsMouse() {
            pressedButtons.insert(event.buttonNumber)
            guard let button = mouseButton(for: event) else { return }
            let pos = mousePosition(from: event)
            sendMouseReport(GhosttyMouseReport(action: .press, button: button,
                                               modifiers: GhosttyModifiers(appKitFlags: event.modifierFlags),
                                               x: pos.x, y: pos.y))
            return
        }
        let cell = gridLayout.cellAt(point: convert(event.locationInWindow, from: nil))
        selectionAnchor = cell
        selectionActive = cell
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if appWantsMouse() {
            guard mouseButton(for: event) != nil || !pressedButtons.isEmpty else { return }
            let pos = mousePosition(from: event)
            let button: GhosttyMouseReport.Button? = mouseButton(for: event)
            sendMouseReport(GhosttyMouseReport(action: .motion, button: button,
                                               modifiers: GhosttyModifiers(appKitFlags: event.modifierFlags),
                                               x: pos.x, y: pos.y))
            return
        }
        guard selectionAnchor != nil else { return }
        selectionActive = gridLayout.cellAt(point: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if appWantsMouse(), pressedButtons.contains(event.buttonNumber) {
            pressedButtons.remove(event.buttonNumber)
            guard let button = mouseButton(for: event) else { return }
            let pos = mousePosition(from: event)
            sendMouseReport(GhosttyMouseReport(action: .release, button: button,
                                               modifiers: GhosttyModifiers(appKitFlags: event.modifierFlags),
                                               x: pos.x, y: pos.y))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        mouseDown(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseDragged(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        mouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        mouseDown(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        mouseDragged(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        mouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard !mirrorsOutput else { return }
        ensureBackend()
        if appWantsMouse() {
            let delta = event.scrollingDeltaY
            guard delta != 0 else { return }
            let pos = mousePosition(from: event)
            // AppKit: positive deltaY is scroll-up.
            let button: GhosttyMouseReport.Button = delta > 0 ? .wheelUp : .wheelDown
            sendMouseReport(GhosttyMouseReport(action: .press, button: button,
                                               modifiers: GhosttyModifiers(appKitFlags: event.modifierFlags),
                                               x: pos.x, y: pos.y))
            return
        }
        // Scrollback viewing. AppKit positive deltaY is scroll-up; the
        // terminal's delta space is negative-up.
        var rows = 0
        if event.hasPreciseScrollingDeltas {
            wheelRemainder += event.scrollingDeltaY
            let cellH = max(gridLayout.cellHeight, 1)
            rows = Int((wheelRemainder / cellH).rounded(.towardZero))
            if rows != 0 { wheelRemainder -= CGFloat(rows) * cellH }
        } else {
            let lines = Int(event.deltaY.rounded(.towardZero))
            if lines != 0 {
                rows = lines
            } else if event.deltaY > 0 {
                rows = 1
            } else if event.deltaY < 0 {
                rows = -1
            }
        }
        guard rows != 0, let term = terminal else { return }
        term.scrollViewport(lines: -rows)
        refreshScrollState()
        needsDisplay = true
    }

    // MARK: - Scrollback viewing (continued)

    /// Snaps a parked viewport back to the live area (on typing).
    private func snapToBottom() {
        guard isScrolledUp else { return }
        isScrolledUp = false
        terminal?.scrollViewportToBottom()
        refreshScrollState()
        needsDisplay = true
    }

    /// Re-reads the scrollbar, updates the parked flag and the overlay knob.
    private func refreshScrollState() {
        guard let term = terminal, let sb = term.scrollbar() else {
            scroller?.isHidden = true
            return
        }
        isScrolledUp = sb.total > sb.length && sb.offset + sb.length < sb.total
        updateScroller(total: sb.total, offset: sb.offset, length: sb.length)
    }

    private func updateScroller(total: UInt64, offset: UInt64, length: UInt64) {
        guard total > length else {
            scroller?.isHidden = true
            return
        }
        if scroller == nil {
            let scroller = NSScroller(frame: scrollerFrame())
            scroller.target = self
            scroller.action = #selector(scrollerDidScroll(_:))
            scroller.isHidden = total <= length
            addSubview(scroller)
            self.scroller = scroller
        }
        guard let scroller, total > length else { return }
        let maxOffset = total - length
        scroller.knobProportion = CGFloat(length) / CGFloat(total)
        scroller.doubleValue = maxOffset == 0 ? 1 : CGFloat(offset) / CGFloat(maxOffset)
        scroller.isHidden = false
    }

    private func scrollerFrame() -> NSRect {
        let width: CGFloat = 14
        return NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
    }

    @objc private func scrollerDidScroll(_ sender: NSScroller) {
        guard let term = terminal, let sb = term.scrollbar(), sb.total > sb.length else { return }
        let maxOffset = sb.total - sb.length
        let row = UInt64((CGFloat(maxOffset) * sender.doubleValue).rounded())
        term.scrollViewport(toRow: min(row, maxOffset))
        refreshScrollState()
        needsDisplay = true
    }
}
