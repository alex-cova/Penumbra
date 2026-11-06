import Foundation

/// Everything Settings ▸ Terminal decides that `GhosttyTerminalView` acts on, as plain values.
/// `vt` goes to the parser; the rest is read by the view itself. The font is separate
/// (`GhosttyTerminalView.applyFont`) because it is an `NSFont`.
struct GhosttyTerminalViewConfiguration: Equatable, Sendable {
    var vt = GhosttyVtConfiguration()
    var faintOpacity = 0.6
    var cellHeightAdjustPercent = 0
    /// `0xRRGGBB`, or nil for the system selection colour.
    var selectionColor: UInt32?
    var optionAsAlt = IDETerminalOptionAsAlt.both
    var copyOnSelect = false
    var hideMouseWhileTyping = false
    var scrollToBottomOnKeystroke = true
    var scrollToBottomOnOutput = false
    var bell = IDETerminalBell.visual
    var confirmUnsafePaste = true
    var allowTitleChange = true

    init() {}

    /// - Parameters:
    ///   - scheme: The UI colour scheme's terminal colours, used unless the settings choose their own.
    ///   - termName: `term` from the shell settings, which the parser reports to XTGETTCAP.
    init(
        settings: IDETerminalSettings,
        scheme: (foreground: UInt32, background: UInt32, cursor: UInt32),
        termName: String
    ) {
        let custom = settings.usesCustomColors
        vt = GhosttyVtConfiguration(
            foreground: custom ? settings.palette.foreground : scheme.foreground,
            background: custom ? settings.palette.background : scheme.background,
            cursorColor: custom ? settings.palette.cursor : scheme.cursor,
            ansiPalette: custom ? settings.palette.ansi : nil,
            cursorStyle: settings.cursorStyle,
            cursorBlinks: settings.cursorBlinks,
            scrollbackLines: settings.scrollbackLines,
            termName: termName,
            titleReport: settings.allowTitleReport,
            clipboardRead: settings.clipboardRead,
            clipboardWriteAllowed: settings.clipboardWrite != .deny,
            desktopNotifications: settings.desktopNotifications)
        faintOpacity = settings.faintOpacity
        cellHeightAdjustPercent = settings.cellHeightAdjustPercent
        selectionColor = custom ? settings.palette.selection : nil
        optionAsAlt = settings.optionAsAlt
        copyOnSelect = settings.copyOnSelect
        hideMouseWhileTyping = settings.hideMouseWhileTyping
        scrollToBottomOnKeystroke = settings.scrollToBottomOnKeystroke
        scrollToBottomOnOutput = settings.scrollToBottomOnOutput
        bell = settings.bell
        confirmUnsafePaste = settings.confirmUnsafePaste
        allowTitleChange = settings.allowTitleChange
    }
}
