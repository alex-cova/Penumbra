import Foundation
import GhosttyVt

/// Events a ``GhosttyVtTerminal`` emits while processing PTY output.
///
/// Handlers run synchronously on the terminal's internal serial queue,
/// inside `ghostty_terminal_vt_write`. They must not call back into the
/// terminal (no reentrancy) and must hop to another queue for slow work.
enum GhosttyVtEvent: Sendable {
    /// OSC 0/2 changed the window title. The payload is the new title.
    case titleChanged(String)
    /// OSC 7/9/1337 changed the working directory. The payload is the new path.
    case pwdChanged(String)
    /// The program emitted BEL (0x07).
    case bell
    /// The terminal answered a device query (DSR, DECRQM, XTWINOPS, …).
    /// Send these bytes back to the PTY master.
    case writePty(Data)
    /// A program wrote text to the clipboard (OSC 52) and the configuration allows it.
    case clipboardWrite(String)
    /// A program asked to read the clipboard while the policy is "ask". The request was refused;
    /// the host may prompt and, on consent, call ``GhosttyVtTerminal/grantClipboardRead()``.
    case clipboardReadRequested
    /// OSC 9 / OSC 777, while desktop notifications are on.
    case desktopNotification(title: String, body: String)
}

/// What Settings ▸ Terminal decides about the parser itself: colours, the default cursor, scrollback,
/// and what a program may do through escape sequences. Applied with ``GhosttyVtTerminal/configure(_:)``.
struct GhosttyVtConfiguration: Equatable, Sendable {
    /// `0xRRGGBB`. Answered to OSC 10/11/12 queries and used for cells with no colour of their own.
    var foreground: UInt32 = 0xD8DEE9
    var background: UInt32 = 0x1E2127
    var cursorColor: UInt32 = 0xFFCC66
    /// The sixteen ANSI entries; nil keeps libghostty's built-in palette. Entries 16-255 always stay the built-in cube and ramp.
    var ansiPalette: [UInt32]?
    /// What `CSI 0 q` and a reset return the cursor to.
    var cursorStyle = IDETerminalCursorStyle.bar
    var cursorBlinks = false
    var scrollbackLines = 10_000
    /// The name XTGETTCAP reports (`term`).
    var termName = IDETerminalShellSettings.defaultTermName
    var titleReport = false
    var clipboardRead = IDETerminalClipboardAccess.ask
    var clipboardWriteAllowed = true
    var desktopNotifications = true
}

/// DEC/ANSI mode numbers for `GhosttyVtTerminal.isModeSet`, packed per
/// `modes.h` (bits 0–14 value, bit 15 ANSI flag).
enum GhosttyTerminalModes {
    static func dec(_ number: UInt16) -> GhosttyMode {
        GhosttyMode(number & 0x7FFF)
    }

    /// Application cursor keys (DECCKM, 1).
    static var cursorKeys: GhosttyMode { dec(1) }
    /// X10 mouse reporting (9).
    static var x10Mouse: GhosttyMode { dec(9) }
    /// Normal mouse tracking (1000).
    static var normalMouse: GhosttyMode { dec(1000) }
    /// Button-event tracking (1002).
    static var buttonMouse: GhosttyMode { dec(1002) }
    /// Any-event tracking (1003).
    static var anyMouse: GhosttyMode { dec(1003) }
    /// SGR mouse format (1006).
    static var sgrMouse: GhosttyMode { dec(1006) }
    /// Bracketed paste (2004).
    static var bracketedPaste: GhosttyMode { dec(2004) }
}

/// Swift ownership wrapper around one `GhosttyTerminal` (libghostty-vt).
///
/// No AppKit, no process: bytes go in through ``write(_:)``, plain-text
/// snapshots come out through ``plainText()``, and OSC title/directory
/// reports arrive as ``GhosttyVtEvent`` values. All C calls happen on one
/// private serial queue; the C terminal is assumed not thread-safe.
///
/// The process side (PTY master, shell spawn, window size) lives in
/// `GhosttyPtyProcess`. Rendering lives in the future `GhosttyTerminalView`.
final class GhosttyVtTerminal: @unchecked Sendable {
    /// Called synchronously on the terminal's serial queue for every event.
    /// Must be lock-free with respect to this terminal: queue the payload
    /// and return, never call back into `GhosttyVtTerminal` from it.
    var onEvent: (@Sendable (GhosttyVtEvent) -> Void)?

    // Module-internal so GhosttyRenderSnapshot.swift can pull snapshots
    // on the same serial queue; never touch these off `queue`.
    let queue = DispatchQueue(label: "com.umbra.GhosttyVtTerminal", qos: .userInitiated)
    var terminal: GhosttyTerminal?
    var renderState: GhosttyRenderState?
    private let eventBox = GhosttyVtEventBox()
    /// Kept alive for the C side, which may borrow the XTGETTCAP name instead of copying it.
    private var termNameStorage: UnsafeMutablePointer<CChar>?

    /// Where a clipboard read is answered from. Called on the terminal queue while the stream is paused,
    /// so it must not wait on the main thread (`NSPasteboard.string(forType:)` does not).
    func setClipboardReader(_ reader: (@Sendable () -> String?)?) {
        queue.sync { eventBox.clipboardReader = reader }
    }

    /// Lets this terminal's programs read the clipboard from now on (the user said yes to the prompt that
    /// ``GhosttyVtEvent/clipboardReadRequested`` raised). The program has to ask again.
    func grantClipboardRead() {
        queue.sync { eventBox.readPolicy = .allow }
    }

    /// Creates a terminal with the given grid size in cells.
    init?(cols: Int = 80, rows: Int = 24) {
        guard cols > 0, rows > 0 else { return nil }
        var term: GhosttyTerminal?
        let result = ghostty_terminal_new(nil, &term, UInt16(clamping: cols), UInt16(clamping: rows))
        guard result == GHOSTTY_SUCCESS, let term else { return nil }
        terminal = term
        var state: GhosttyRenderState?
        guard ghostty_render_state_new(nil, &state) == GHOSTTY_SUCCESS, let state else {
            ghostty_terminal_free(term)
            terminal = nil
            return nil
        }
        renderState = state
        eventBox.owner = self
        let userdata = Unmanaged.passUnretained(eventBox).toOpaque()
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_USERDATA, UnsafeRawPointer(userdata))
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_WRITE_PTY, vtWritePtyCallbackPointer)
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_BELL, vtBellCallbackPointer)
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, vtTitleCallbackPointer)
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, vtPwdCallbackPointer)
    }

    deinit {
        let term = terminal
        let state = renderState
        // Never runs on `queue` (all queue work is self-free), so sync is safe.
        queue.sync {
            if let state { ghostty_render_state_free(state) }
            if let term { ghostty_terminal_free(term) }
        }
        if let termNameStorage { free(termNameStorage) }
    }

    /// Applies Settings ▸ Terminal to the parser. Safe to call again whenever the settings change; the
    /// terminal keeps its contents. A cursor that is already showing keeps its shape until the next
    /// `CSI 0 q` (a program may have chosen it), so the host writes that after a change.
    func configure(_ config: GhosttyVtConfiguration) {
        queue.sync {
            guard let term = self.terminal else { return }
            eventBox.readPolicy = config.clipboardRead
            eventBox.writeAllowed = config.clipboardWriteAllowed
            eventBox.notificationsEnabled = config.desktopNotifications

            func rgb(_ hex: UInt32) -> GhosttyColorRgb {
                GhosttyColorRgb(r: UInt8((hex >> 16) & 0xFF), g: UInt8((hex >> 8) & 0xFF), b: UInt8(hex & 0xFF))
            }
            var foreground = rgb(config.foreground)
            var background = rgb(config.background)
            var cursorColor = rgb(config.cursorColor)
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground)
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background)
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursorColor)

            // NULL resets to the built-in palette, which is also where entries 16-255 come from.
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, nil)
            if let ansi = config.ansiPalette, ansi.count == 16 {
                var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(r: 0, g: 0, b: 0), count: 256)
                let readable = palette.withUnsafeMutableBufferPointer { buffer -> Bool in
                    ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, buffer.baseAddress) == GHOSTTY_SUCCESS
                }
                if readable {
                    for (index, hex) in ansi.enumerated() { palette[index] = rgb(hex) }
                    palette.withUnsafeBufferPointer { buffer in
                        _ = ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, buffer.baseAddress)
                    }
                }
            }

            var style: GhosttyTerminalCursorStyle = switch config.cursorStyle {
            case .block: GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK
            case .bar: GHOSTTY_TERMINAL_CURSOR_STYLE_BAR
            case .underline: GHOSTTY_TERMINAL_CURSOR_STYLE_UNDERLINE
            case .hollow: GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK_HOLLOW
            }
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &style)
            var blinks = config.cursorBlinks
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &blinks)

            // Both limits apply, whichever is reached first. The byte limit is a guard against very wide,
            // heavily styled lines, sized so it does not cut the line limit short for ordinary output.
            var lines = max(config.scrollbackLines, 0)
            var bytes = lines * 2048
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines)
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &bytes)

            var report = config.titleReport
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_TITLE_REPORT, &report)

            if let previous = termNameStorage { free(previous) }
            let name = config.termName.isEmpty ? IDETerminalShellSettings.defaultTermName : config.termName
            let storage = strdup(name)
            termNameStorage = storage
            var termInfo = GhosttyString(ptr: UnsafeRawPointer(storage).map { $0.assumingMemoryBound(to: UInt8.self) }, len: strlen(name))
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, &termInfo)

            // A NULL callback makes libghostty ignore the request, which is what "deny" should look like
            // to the program. "Ask" needs the callback: it refuses and tells the host.
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE,
                                 config.clipboardWriteAllowed ? vtClipboardWriteCallbackPointer : nil)
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ,
                                 config.clipboardRead == .deny ? nil : vtClipboardReadCallbackPointer)
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION,
                                 config.desktopNotifications ? vtNotificationCallbackPointer : nil)
        }
    }

    /// Feeds raw PTY bytes through the VT parser. Synchronous: when this
    /// returns, `onEvent` has fired for every event in `data`.
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.sync {
            guard let term = self.terminal else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                ghostty_terminal_vt_write(term, base, data.count)
            }
        }
    }

    /// Resizes the grid. Content reflows when wraparound mode is on.
    func resize(cols: Int, rows: Int, cellWidthPx: Int = 0, cellHeightPx: Int = 0) {
        queue.sync {
            guard let term = self.terminal else { return }
            ghostty_terminal_resize(
                term,
                UInt16(clamping: max(cols, 1)),
                UInt16(clamping: max(rows, 1)),
                UInt32(clamping: max(cellWidthPx, 0)),
                UInt32(clamping: max(cellHeightPx, 0))
            )
        }
    }

    /// Full reset (RIS): modes, scrollback, regions and screen cleared.
    /// Dimensions are preserved.
    func reset() {
        queue.sync {
            guard let term = self.terminal else { return }
            ghostty_terminal_reset(term)
        }
    }

    /// Plain-text snapshot of the active screen, for `recentText(lines:)`
    /// parity: trailing whitespace trimmed, trailing blank lines dropped.
    /// Scrollback is included when the formatter emits it.
    func plainText() -> String? {
        queue.sync {
            guard let term = self.terminal else { return nil }
            var options = GhosttyFormatterTerminalOptions()
            options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
            options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
            options.trim = true
            var formatter: GhosttyFormatter?
            guard ghostty_formatter_terminal_new(nil, &formatter, term, options) == GHOSTTY_SUCCESS,
                  let formatter
            else { return nil }
            defer { ghostty_formatter_free(formatter) }
            var buf: UnsafeMutablePointer<UInt8>?
            var len = 0
            guard ghostty_formatter_format_alloc(formatter, nil, &buf, &len) == GHOSTTY_SUCCESS,
                  let buf
            else { return nil }
            defer { ghostty_free(nil, buf, len) }
            return String(bytes: UnsafeBufferPointer(start: buf, count: len), encoding: .utf8)
        }
    }

    /// Runs `body` with the raw terminal handle on the terminal queue.
    ///
    /// Encoder configuration and encoding must happen here: the C terminal
    /// is not thread-safe, and `setopt_from_terminal` reads live modes that
    /// `vt_write` on the PTY thread may be changing.
    func withTerminal<T>(_ body: (GhosttyTerminal?) -> T) -> T {
        queue.sync { body(terminal) }
    }

    /// Whether a DEC/ANSI mode is currently set (e.g. `.bracketedPaste`,
    /// `.normalMouse`). See `GhosttyTerminalModes`.
    func isModeSet(_ mode: GhosttyMode) -> Bool {
        queue.sync {
            guard let term = self.terminal else { return false }
            var config = GhosttyTerminalModeConfig()
            config.mode = mode
            config.value = false
            guard ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS else {
                return false
            }
            return config.value
        }
    }

    /// Last `lines` non-empty lines, trimmed of trailing blanks — the same
    /// tail rule `IDETerminalHostView.recentText(lines:)` applies today.
    func recentText(lines: Int) -> String? {
        guard let text = plainText() else { return nil }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        var end = all.count
        while end > 0, all[end - 1].allSatisfy(\.isWhitespace) { end -= 1 }
        let tail = all[max(0, end - lines)..<end]
        return tail.isEmpty ? nil : tail.joined(separator: "\n")
    }

    /// Scrollback geometry: total scrollable rows, the viewport's offset
    /// from the top of that area, and the viewport length in rows. Nil
    /// when the terminal is gone. Poll once per frame/write batch and diff
    /// (there is intentionally no change notification).
    func scrollbar() -> (total: UInt64, offset: UInt64, length: UInt64)? {
        queue.sync {
            guard let term = self.terminal else { return nil }
            var sb = GhosttyTerminalScrollbar(total: 0, offset: 0, len: 0)
            guard ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb) == GHOSTTY_SUCCESS else {
                return nil
            }
            return (sb.total, sb.offset, sb.len)
        }
    }

    /// Scrolls the viewport by `lines` rows; negative scrolls up into
    /// scrollback, positive back toward the live area. Clamped by the
    /// library; a no-op on the alternate screen.
    func scrollViewport(lines: Int) {
        queue.sync {
            guard let term = self.terminal else { return }
            var behavior = GhosttyTerminalScrollViewport(
                tag: GHOSTTY_SCROLL_VIEWPORT_DELTA,
                value: GhosttyTerminalScrollViewportValue())
            behavior.value.delta = lines
            ghostty_terminal_scroll_viewport(term, behavior)
        }
    }

    /// Scrolls the viewport to an absolute row offset from the top of the
    /// scrollable area (the scrollbar's row space). Clamped to the active
    /// area; a no-op on the alternate screen.
    func scrollViewport(toRow row: UInt64) {
        queue.sync {
            guard let term = self.terminal else { return }
            var behavior = GhosttyTerminalScrollViewport(
                tag: GHOSTTY_SCROLL_VIEWPORT_ROW,
                value: GhosttyTerminalScrollViewportValue())
            behavior.value.row = numericCast(row)
            ghostty_terminal_scroll_viewport(term, behavior)
        }
    }

    /// Scrolls back to the live (bottom) area.
    func scrollViewportToBottom() {
        queue.sync {
            guard let term = self.terminal else { return }
            let behavior = GhosttyTerminalScrollViewport(
                tag: GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
                value: GhosttyTerminalScrollViewportValue())
            ghostty_terminal_scroll_viewport(term, behavior)
        }
    }

    fileprivate func emit(_ event: GhosttyVtEvent) {
        onEvent?(event)
    }

    fileprivate func string(for data: GhosttyTerminalData) -> String? {
        guard let term = terminal else { return nil }
        var value = GhosttyString()
        guard ghostty_terminal_get(term, data, &value) == GHOSTTY_SUCCESS,
              let ptr = value.ptr, value.len > 0
        else { return nil }
        let buffer = UnsafeBufferPointer(start: ptr, count: value.len)
        return String(bytes: buffer, encoding: .utf8)
    }
}

/// Carries events from C callbacks (which only get an opaque pointer) back
/// to the owning ``GhosttyVtTerminal``. Retained by the terminal; the C
/// side holds it unretained.
private final class GhosttyVtEventBox {
    weak var owner: GhosttyVtTerminal?

    // Read and written on the terminal queue only (callbacks run inside `vt_write`, and
    // `configure` / `grantClipboardRead` / `setClipboardReader` take the queue too).
    var readPolicy = IDETerminalClipboardAccess.ask
    var writeAllowed = true
    var notificationsEnabled = true
    var clipboardReader: (@Sendable () -> String?)?

    func emit(_ event: GhosttyVtEvent) {
        owner?.emit(event)
    }

    func handleClipboardRead(_ read: UnsafePointer<GhosttyClipboardRead>) {
        var reply = GhosttyClipboardReadReply()
        reply.size = MemoryLayout<GhosttyClipboardReadReply>.size
        // Only the standard clipboard exists on macOS; text is the only representation served.
        guard readPolicy == .allow, read.pointee.location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD else {
            reply.result = GHOSTTY_CLIPBOARD_READ_RESULT_DENIED
            read.pointee.reply?(read, &reply)
            // The program is refused either way; under "ask" the host hears about it once per request.
            if readPolicy == .ask { emit(.clipboardReadRequested) }
            return
        }
        guard let text = clipboardReader?() else {
            reply.result = GHOSTTY_CLIPBOARD_READ_RESULT_SUCCESS
            reply.contents_len = 0
            read.pointee.reply?(read, &reply)
            return
        }
        let mime = Array("text/plain".utf8)
        let data = Array(text.utf8)
        mime.withUnsafeBufferPointer { mimeBuffer in
            data.withUnsafeBufferPointer { dataBuffer in
                let content = GhosttyClipboardContent(
                    mime: GhosttyString(ptr: mimeBuffer.baseAddress, len: mimeBuffer.count),
                    data: GhosttyString(ptr: dataBuffer.baseAddress, len: dataBuffer.count))
                withUnsafePointer(to: content) { contentPointer in
                    reply.result = GHOSTTY_CLIPBOARD_READ_RESULT_SUCCESS
                    reply.contents = contentPointer
                    reply.contents_len = 1
                    read.pointee.reply?(read, &reply)
                }
            }
        }
    }

    func handleClipboardWrite(_ write: UnsafePointer<GhosttyClipboardWrite>) {
        var reply = GhosttyClipboardWriteReply()
        reply.size = MemoryLayout<GhosttyClipboardWriteReply>.size
        guard writeAllowed, write.pointee.location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD else {
            reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED
            write.pointee.reply?(write, &reply)
            return
        }
        if let contents = write.pointee.contents, write.pointee.contents_len > 0 {
            for index in 0..<write.pointee.contents_len {
                let content = contents[index]
                guard vtString(content.mime).hasPrefix("text/") else { continue }
                emit(.clipboardWrite(vtString(content.data)))
                break
            }
        }
        reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
        write.pointee.reply?(write, &reply)
    }
}

private func vtString(_ string: GhosttyString) -> String {
    guard let pointer = string.ptr, string.len > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: pointer, count: string.len), as: UTF8.self)
}

// MARK: - C callbacks (run on the terminal queue during vt_write)

private func vtBox(_ userdata: UnsafeMutableRawPointer?) -> GhosttyVtEventBox? {
    guard let userdata else { return nil }
    return Unmanaged<GhosttyVtEventBox>.fromOpaque(userdata).takeUnretainedValue()
}

private let vtWritePtyCallback: GhosttyTerminalWritePtyFn = { _, userdata, data, len in
    guard let data, len > 0 else { return }
    vtBox(userdata)?.emit(.writePty(Data(bytes: data, count: len)))
}

private let vtBellCallback: GhosttyTerminalBellFn = { _, userdata in
    vtBox(userdata)?.emit(.bell)
}

private let vtTitleCallback: GhosttyTerminalTitleChangedFn = { terminal, userdata in
    guard let box = vtBox(userdata), let owner = box.owner else { return }
    if let title = owner.string(for: GHOSTTY_TERMINAL_DATA_TITLE) {
        box.emit(.titleChanged(title))
    }
}

private let vtPwdCallback: GhosttyTerminalPwdChangedFn = { terminal, userdata in
    guard let box = vtBox(userdata), let owner = box.owner else { return }
    if let pwd = owner.string(for: GHOSTTY_TERMINAL_DATA_PWD) {
        box.emit(.pwdChanged(pwd))
    }
}

private let vtClipboardReadCallback: GhosttyTerminalClipboardReadFn = { _, userdata, read in
    guard let read, let box = vtBox(userdata) else { return }
    box.handleClipboardRead(read)
}

private let vtClipboardWriteCallback: GhosttyTerminalClipboardWriteFn = { _, userdata, write in
    guard let write, let box = vtBox(userdata) else { return }
    box.handleClipboardWrite(write)
}

private let vtNotificationCallback: GhosttyTerminalDesktopNotificationFn = { _, userdata, notification in
    guard let notification, let box = vtBox(userdata), box.notificationsEnabled else { return }
    box.emit(.desktopNotification(
        title: vtString(notification.pointee.title), body: vtString(notification.pointee.body)))
}

private var vtClipboardReadCallbackPointer: UnsafeRawPointer {
    unsafeBitCast(vtClipboardReadCallback, to: UnsafeRawPointer.self)
}

private var vtClipboardWriteCallbackPointer: UnsafeRawPointer {
    unsafeBitCast(vtClipboardWriteCallback, to: UnsafeRawPointer.self)
}

private var vtNotificationCallbackPointer: UnsafeRawPointer {
    unsafeBitCast(vtNotificationCallback, to: UnsafeRawPointer.self)
}

private var vtWritePtyCallbackPointer: UnsafeRawPointer {
    unsafeBitCast(vtWritePtyCallback, to: UnsafeRawPointer.self)
}

private var vtBellCallbackPointer: UnsafeRawPointer {
    unsafeBitCast(vtBellCallback, to: UnsafeRawPointer.self)
}

private var vtTitleCallbackPointer: UnsafeRawPointer {
    unsafeBitCast(vtTitleCallback, to: UnsafeRawPointer.self)
}

private var vtPwdCallbackPointer: UnsafeRawPointer {
    unsafeBitCast(vtPwdCallback, to: UnsafeRawPointer.self)
}
