import Foundation

// Settings ▸ Terminal. Pure values (no AppKit): the pane edits them, `IDEPreferences` stores them,
// and the terminal view and the shell launch read them. Every field is named after the Ghostty
// configuration key it stands for (`ghosttyKey` in the doc comments) so the pane's search finds it.

/// The sixteen ANSI colours plus the four special ones, as `0xRRGGBB`.
struct IDETerminalPalette: Codable, Equatable, Sendable {
    /// `foreground` (Ghostty).
    var foreground: UInt32 = 0xD8DEE9
    /// `background`.
    var background: UInt32 = 0x1E2127
    /// `cursor-color`.
    var cursor: UInt32 = 0xFFCC66
    /// `selection-background`.
    var selection: UInt32 = 0x3E4A63
    /// `palette = 0…15`: eight normal colours, then their bright variants.
    var ansi: [UInt32] = IDETerminalPalette.defaultANSI

    static let defaultANSI: [UInt32] = [
        0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
        0x666666, 0xD54E53, 0xB9CA4A, 0xE7C547, 0x7AA6DA, 0xC397D8, 0x70C0B1, 0xEAEAEA,
    ]

    static let ansiNames = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        foreground = try c.decodeIfPresent(UInt32.self, forKey: .foreground) ?? 0xD8DEE9
        background = try c.decodeIfPresent(UInt32.self, forKey: .background) ?? 0x1E2127
        cursor = try c.decodeIfPresent(UInt32.self, forKey: .cursor) ?? 0xFFCC66
        selection = try c.decodeIfPresent(UInt32.self, forKey: .selection) ?? 0x3E4A63
        let stored = try c.decodeIfPresent([UInt32].self, forKey: .ansi) ?? []
        // A palette is all sixteen entries or the default; a short list would shift every colour.
        ansi = stored.count == 16 ? stored : Self.defaultANSI
    }
}

/// How a program's bell is shown. `bell-features`.
enum IDETerminalBell: String, Codable, CaseIterable, Identifiable, Sendable {
    case visual, sound, both, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .visual: "Flash"
        case .sound: "Sound"
        case .both: "Flash and Sound"
        case .none: "None"
        }
    }
    var flashes: Bool { self == .visual || self == .both }
    var beeps: Bool { self == .sound || self == .both }
}

/// `cursor-style`.
enum IDETerminalCursorStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case block, bar, underline, hollow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .block: "Block"
        case .bar: "Bar"
        case .underline: "Underline"
        case .hollow: "Hollow Block"
        }
    }
}

/// `macos-option-as-alt`.
enum IDETerminalOptionAsAlt: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, both, left, right
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off (types special characters)"
        case .both: "Both Option Keys"
        case .left: "Left Option Key"
        case .right: "Right Option Key"
        }
    }
}

/// `clipboard-read` / `clipboard-write`: what a program may do with the clipboard through OSC 52.
enum IDETerminalClipboardAccess: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask, allow, deny
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ask: "Ask"
        case .allow: "Allow"
        case .deny: "Deny"
        }
    }
}

/// The terminal's look and behaviour. Shared between Macs through the preferences snapshot.
struct IDETerminalSettings: Codable, Equatable, Sendable {
    // MARK: Font

    /// Use the editor's font (`font-family` unset).
    var fontFollowsEditor = true
    /// `font-family`.
    var fontFamily = IDETerminalSettings.defaultFontFamily
    /// `font-size`.
    var fontSize: Double = 13
    /// `adjust-cell-height`, as a percentage of the font's line height.
    var cellHeightAdjustPercent = 0
    /// `window-padding-x`: the space left of the text.
    var paddingX: Double = 8
    /// `window-padding-y`: the space above and below the text.
    var paddingY: Double = 0

    // MARK: Colours and cursor

    /// Use `palette` instead of the UI colour scheme's colours.
    var usesCustomColors = false
    var palette = IDETerminalPalette()
    /// `cursor-style`.
    var cursorStyle = IDETerminalCursorStyle.bar
    /// `cursor-style-blink`.
    var cursorBlinks = false
    /// `faint-opacity`.
    var faintOpacity: Double = 0.6

    // MARK: Behaviour

    /// `scrollback-limit`, in lines.
    var scrollbackLines = 10_000
    /// `macos-option-as-alt`.
    var optionAsAlt = IDETerminalOptionAsAlt.both
    /// `copy-on-select`.
    var copyOnSelect = false
    /// `mouse-hide-while-typing`.
    var hideMouseWhileTyping = false
    /// `scroll-to-bottom = keystroke`.
    var scrollToBottomOnKeystroke = true
    /// `scroll-to-bottom = no-output`, inverted: new output leaves a parked viewport alone by default.
    var scrollToBottomOnOutput = false
    /// `bell-features`.
    var bell = IDETerminalBell.visual
    /// `clipboard-paste-protection`.
    var confirmUnsafePaste = true

    // MARK: Integrations and security

    /// `clipboard-read`.
    var clipboardRead = IDETerminalClipboardAccess.ask
    /// `clipboard-write`; `ask` is not offered, so this is `allow` or `deny`.
    var clipboardWrite = IDETerminalClipboardAccess.allow
    /// `desktop-notifications` (OSC 9 and OSC 777).
    var desktopNotifications = true
    /// Whether programs may set the tab's title (OSC 0 and 2).
    var allowTitleChange = true
    /// `title-report`: answer CSI 21 t with the title. Off because a program can use it to type into the shell.
    var allowTitleReport = false

    static let defaultFontFamily = "Menlo"
    static let scrollbackRange = 1_000...100_000
    static let cellHeightRange = -20...60

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        let d = IDETerminalSettings()
        fontFollowsEditor = try value(.fontFollowsEditor, d.fontFollowsEditor)
        fontFamily = try value(.fontFamily, d.fontFamily)
        fontSize = try value(.fontSize, d.fontSize)
        cellHeightAdjustPercent = try value(.cellHeightAdjustPercent, d.cellHeightAdjustPercent)
        paddingX = try value(.paddingX, d.paddingX)
        paddingY = try value(.paddingY, d.paddingY)
        usesCustomColors = try value(.usesCustomColors, d.usesCustomColors)
        palette = try value(.palette, d.palette)
        // An unknown raw value (a newer build wrote it) falls back to the default, not a failed decode.
        cursorStyle = (try? c.decodeIfPresent(IDETerminalCursorStyle.self, forKey: .cursorStyle)) ?? d.cursorStyle
        cursorBlinks = try value(.cursorBlinks, d.cursorBlinks)
        faintOpacity = try value(.faintOpacity, d.faintOpacity)
        scrollbackLines = try value(.scrollbackLines, d.scrollbackLines)
        optionAsAlt = (try? c.decodeIfPresent(IDETerminalOptionAsAlt.self, forKey: .optionAsAlt)) ?? d.optionAsAlt
        copyOnSelect = try value(.copyOnSelect, d.copyOnSelect)
        hideMouseWhileTyping = try value(.hideMouseWhileTyping, d.hideMouseWhileTyping)
        scrollToBottomOnKeystroke = try value(.scrollToBottomOnKeystroke, d.scrollToBottomOnKeystroke)
        scrollToBottomOnOutput = try value(.scrollToBottomOnOutput, d.scrollToBottomOnOutput)
        bell = (try? c.decodeIfPresent(IDETerminalBell.self, forKey: .bell)) ?? d.bell
        confirmUnsafePaste = try value(.confirmUnsafePaste, d.confirmUnsafePaste)
        clipboardRead = (try? c.decodeIfPresent(IDETerminalClipboardAccess.self, forKey: .clipboardRead)) ?? d.clipboardRead
        clipboardWrite = (try? c.decodeIfPresent(IDETerminalClipboardAccess.self, forKey: .clipboardWrite)) ?? d.clipboardWrite
        desktopNotifications = try value(.desktopNotifications, d.desktopNotifications)
        allowTitleChange = try value(.allowTitleChange, d.allowTitleChange)
        allowTitleReport = try value(.allowTitleReport, d.allowTitleReport)
        self = self.clamped()
    }

    /// The same settings with every number inside the range the pane offers.
    func clamped() -> IDETerminalSettings {
        var copy = self
        copy.fontSize = min(max(fontSize, 8), 40)
        copy.cellHeightAdjustPercent = min(max(cellHeightAdjustPercent, Self.cellHeightRange.lowerBound), Self.cellHeightRange.upperBound)
        copy.paddingX = min(max(paddingX, 0), 64)
        copy.paddingY = min(max(paddingY, 0), 64)
        copy.faintOpacity = min(max(faintOpacity, 0.2), 1)
        copy.scrollbackLines = min(max(scrollbackLines, Self.scrollbackRange.lowerBound), Self.scrollbackRange.upperBound)
        if copy.clipboardWrite == .ask { copy.clipboardWrite = .allow }
        return copy
    }
}

// MARK: - Shell

/// One `NAME=value` the shell starts with.
struct IDETerminalEnvironmentVariable: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var value = ""

    /// POSIX names: a letter or underscore, then letters, digits and underscores.
    var isValidName: Bool {
        guard let first = name.unicodeScalars.first else { return false }
        func isHead(_ s: Unicode.Scalar) -> Bool { s == "_" || ("A"..."Z").contains(s) || ("a"..."z").contains(s) }
        return isHead(first) && name.unicodeScalars.allSatisfy { isHead($0) || ("0"..."9").contains($0) }
    }
}

/// Where a new shell starts. `working-directory`.
enum IDETerminalStartDirectory: String, Codable, CaseIterable, Identifiable, Sendable {
    case project, home, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .project: "Project Folder"
        case .home: "Home Folder"
        case .custom: "Custom Folder"
        }
    }
}

/// What starts in a terminal tab. Kept on this Mac (paths and environment differ from machine to machine),
/// so it is not part of the preferences snapshot.
struct IDETerminalShellSettings: Codable, Equatable, Sendable {
    /// `command`: empty is the account's login shell.
    var command = ""
    /// Arguments after the command, split like a shell would (quotes and backslashes).
    var arguments = ""
    /// Start the shell as a login shell (`-zsh` as `argv[0]`).
    var loginShell = true
    /// `env`.
    var environment: [IDETerminalEnvironmentVariable] = []
    var startingDirectory = IDETerminalStartDirectory.project
    var customDirectory = ""
    /// `term`.
    var termName = IDETerminalShellSettings.defaultTermName

    static let defaultTermName = "xterm-256color"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IDETerminalShellSettings()
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? d.command
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? d.arguments
        loginShell = try c.decodeIfPresent(Bool.self, forKey: .loginShell) ?? d.loginShell
        environment = try c.decodeIfPresent([IDETerminalEnvironmentVariable].self, forKey: .environment) ?? d.environment
        startingDirectory = (try? c.decodeIfPresent(IDETerminalStartDirectory.self, forKey: .startingDirectory)) ?? d.startingDirectory
        customDirectory = try c.decodeIfPresent(String.self, forKey: .customDirectory) ?? d.customDirectory
        termName = try c.decodeIfPresent(String.self, forKey: .termName) ?? d.termName
    }
}

/// Splits a command line into words the way a POSIX shell would for quoting: whitespace separates,
/// `'…'` is literal, `"…"` allows `\"` and `\\`, and a backslash outside quotes escapes the next character.
/// No expansion of any kind (`$VAR`, globs, `~`) happens.
enum IDETerminalCommandLine {
    static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                // Inside double quotes a backslash only escapes `"` and `\`; anywhere else it is literal.
                if quote == "\"", character != "\"", character != "\\" { current.append("\\") }
                current.append(character)
                escaped = false
                continue
            }
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"" {
                    escaped = true
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                inWord = true
            case "\\":
                escaped = true
                inWord = true
            case " ", "\t", "\n":
                if inWord { words.append(current) }
                current = ""
                inWord = false
            default:
                current.append(character)
                inWord = true
            }
        }
        if escaped { current.append("\\") }
        if inWord { words.append(current) }
        return words
    }
}

/// Everything `GhosttyPtyProcess.start` needs, decided from the settings.
struct IDETerminalLaunch: Equatable, Sendable {
    var executable: String
    /// `argv[0]`.
    var execName: String
    /// `argv[1…]`.
    var arguments: [String]
    /// Merged over the parent environment by the process.
    var environment: [String: String]
    var directory: String

    /// - Parameters:
    ///   - resolvedLoginShell: The account's shell (`IDETerminalShell.resolvedShell()`), used when `command` is empty or unusable.
    ///   - projectDirectory: The window's folder; nil falls back to the home folder.
    ///   - searchPath: `PATH`, to find a bare command name.
    ///   - isExecutable: Whether a path is an executable file (the tests replace it).
    ///   - isDirectory: Whether a path is a folder.
    static func make(
        shell: IDETerminalShellSettings,
        resolvedLoginShell: String,
        projectDirectory: URL?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        isDirectory: (String) -> Bool = {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        }
    ) -> IDETerminalLaunch {
        let custom = resolveCommand(shell.command, searchPath: searchPath, isExecutable: isExecutable)
        // A custom command that does not resolve falls back to the account's shell with its own
        // arguments dropped: they were written for the other program.
        let executable = custom ?? resolvedLoginShell
        let arguments = custom == nil ? [] : IDETerminalCommandLine.split(shell.arguments)
        let baseName = (executable as NSString).lastPathComponent
        let execName = shell.loginShell ? "-" + baseName : baseName

        var environment: [String: String] = [:]
        let term = shell.termName.trimmingCharacters(in: .whitespaces)
        environment["TERM"] = term.isEmpty ? IDETerminalShellSettings.defaultTermName : term
        environment["COLORTERM"] = "truecolor"
        for variable in shell.environment where variable.isValidName {
            environment[variable.name] = variable.value
        }

        let project = (projectDirectory ?? home).path
        let directory: String
        switch shell.startingDirectory {
        case .project: directory = project
        case .home: directory = home.path
        case .custom:
            let expanded = (shell.customDirectory.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            directory = !expanded.isEmpty && isDirectory(expanded) ? expanded : project
        }
        return IDETerminalLaunch(
            executable: executable, execName: execName, arguments: arguments,
            environment: environment, directory: directory)
    }

    private static func resolveCommand(
        _ command: String, searchPath: String, isExecutable: (String) -> Bool
    ) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.contains("/") { return isExecutable(expanded) ? expanded : nil }
        for entry in searchPath.split(separator: ":") {
            let candidate = (String(entry) as NSString).appendingPathComponent(expanded)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }
}
