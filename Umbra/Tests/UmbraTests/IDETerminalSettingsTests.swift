import XCTest
@testable import Umbra

/// Settings ▸ Terminal: the stored values, what an older or hand-edited file decodes to, the shell
/// launch they produce, and how they map onto the terminal view's configuration.
final class IDETerminalSettingsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: Storage

    func testSettingsRoundTrip() throws {
        var settings = IDETerminalSettings()
        settings.fontFollowsEditor = false
        settings.fontFamily = "Monaco"
        settings.usesCustomColors = true
        settings.palette.ansi[3] = 0x010203
        settings.cursorStyle = .hollow
        settings.optionAsAlt = .right
        settings.clipboardRead = .deny
        let decoded = try JSONDecoder().decode(IDETerminalSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    func testAnEmptyOrPartialFileDecodesToTheDefaults() throws {
        XCTAssertEqual(try decode(IDETerminalSettings.self, "{}"), IDETerminalSettings())
        let partial = try decode(IDETerminalSettings.self, #"{"copyOnSelect": true}"#)
        var expected = IDETerminalSettings()
        expected.copyOnSelect = true
        XCTAssertEqual(partial, expected)
        XCTAssertEqual(try decode(IDETerminalShellSettings.self, "{}"), IDETerminalShellSettings())
    }

    func testDefaultsKeepTheLookTheTerminalAlwaysHad() {
        let defaults = IDETerminalSettings()
        XCTAssertTrue(defaults.fontFollowsEditor)
        XCTAssertFalse(defaults.usesCustomColors)
        XCTAssertEqual(defaults.cursorStyle, .bar)
        XCTAssertFalse(defaults.cursorBlinks)
        XCTAssertEqual(defaults.optionAsAlt, .both)
        XCTAssertEqual(defaults.bell, .visual)
        XCTAssertEqual(defaults.paddingX, 8, "the left inset the terminal always had (Spacing.sm)")
        XCTAssertFalse(defaults.allowTitleReport)
    }

    func testValuesOutsideTheOfferedRangeAreClamped() throws {
        let wild = try decode(IDETerminalSettings.self, """
            {"scrollbackLines": 5, "fontSize": 500, "cellHeightAdjustPercent": -99, "paddingX": -3,
             "faintOpacity": 7, "clipboardWrite": "ask"}
            """)
        XCTAssertEqual(wild.scrollbackLines, 1_000)
        XCTAssertEqual(wild.fontSize, 40)
        XCTAssertEqual(wild.cellHeightAdjustPercent, -20)
        XCTAssertEqual(wild.paddingX, 0)
        XCTAssertEqual(wild.faintOpacity, 1)
        XCTAssertEqual(wild.clipboardWrite, .allow, "writes are allowed or denied; there is no asking")
    }

    func testAnUnknownChoiceFallsBackInsteadOfLosingTheFile() throws {
        let decoded = try decode(IDETerminalSettings.self, #"{"cursorStyle": "sparkle", "copyOnSelect": true}"#)
        XCTAssertEqual(decoded.cursorStyle, .bar)
        XCTAssertTrue(decoded.copyOnSelect)
    }

    func testAShortPaletteIsReplacedByTheDefault() throws {
        let decoded = try decode(IDETerminalSettings.self, #"{"palette": {"ansi": [1, 2, 3], "foreground": 255}}"#)
        XCTAssertEqual(decoded.palette.ansi, IDETerminalPalette.defaultANSI)
        XCTAssertEqual(decoded.palette.foreground, 255)
        XCTAssertEqual(IDETerminalPalette.defaultANSI.count, 16)
    }

    // MARK: Command line

    func testCommandLineSplitting() {
        XCTAssertEqual(IDETerminalCommandLine.split(""), [])
        XCTAssertEqual(IDETerminalCommandLine.split("   "), [])
        XCTAssertEqual(IDETerminalCommandLine.split("-l -i"), ["-l", "-i"])
        XCTAssertEqual(IDETerminalCommandLine.split(#"a "b c" 'd e' f\ g"#), ["a", "b c", "d e", "f g"])
        XCTAssertEqual(IDETerminalCommandLine.split(#""say \"hi\"""#), [#"say "hi""#])
        XCTAssertEqual(IDETerminalCommandLine.split("''"), [""], "an empty quoted word is still a word")
        XCTAssertEqual(IDETerminalCommandLine.split("'$HOME *'"), ["$HOME *"], "nothing is expanded")
        XCTAssertEqual(IDETerminalCommandLine.split(#"a\"#), [#"a\"#], "a trailing backslash is kept")
        XCTAssertEqual(IDETerminalCommandLine.split(#""a\nb""#), [#"a\nb"#], "inside quotes only \" and \\ are escapes")
    }

    // MARK: Launch

    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    private let project = URL(fileURLWithPath: "/work/project", isDirectory: true)

    private func launch(
        _ shell: IDETerminalShellSettings = IDETerminalShellSettings(),
        project: URL? = nil,
        executables: Set<String> = [],
        directories: Set<String> = [],
        searchPath: String = "/usr/local/bin:/usr/bin"
    ) -> IDETerminalLaunch {
        IDETerminalLaunch.make(
            shell: shell, resolvedLoginShell: "/bin/zsh", projectDirectory: project, home: home,
            searchPath: searchPath, isExecutable: { executables.contains($0) }, isDirectory: { directories.contains($0) })
    }

    func testDefaultsStartTheAccountsShellAsALoginShellInTheProject() {
        let result = launch(project: project)
        XCTAssertEqual(result.executable, "/bin/zsh")
        XCTAssertEqual(result.execName, "-zsh")
        XCTAssertEqual(result.arguments, [])
        XCTAssertEqual(result.directory, "/work/project")
        XCTAssertEqual(result.environment["TERM"], "xterm-256color")
        XCTAssertEqual(result.environment["COLORTERM"], "truecolor")
    }

    func testNoProjectMeansTheHomeFolder() {
        XCTAssertEqual(launch(project: nil).directory, "/Users/tester")
    }

    func testACustomCommandWithArgumentsAndNoLogin() {
        var shell = IDETerminalShellSettings()
        shell.command = "/opt/homebrew/bin/fish"
        shell.arguments = #"--no-config -C "echo hi""#
        shell.loginShell = false
        let result = launch(shell, executables: ["/opt/homebrew/bin/fish"])
        XCTAssertEqual(result.executable, "/opt/homebrew/bin/fish")
        XCTAssertEqual(result.execName, "fish")
        XCTAssertEqual(result.arguments, ["--no-config", "-C", "echo hi"])
    }

    func testABareCommandIsFoundOnThePath() {
        var shell = IDETerminalShellSettings()
        shell.command = "fish"
        let result = launch(shell, executables: ["/usr/bin/fish"])
        XCTAssertEqual(result.executable, "/usr/bin/fish")
        XCTAssertEqual(result.execName, "-fish")
    }

    func testAnUnusableCommandFallsBackToTheAccountsShellWithoutItsArguments() {
        var shell = IDETerminalShellSettings()
        shell.command = "/nope/fish"
        shell.arguments = "--private"
        let result = launch(shell)
        XCTAssertEqual(result.executable, "/bin/zsh")
        XCTAssertEqual(result.execName, "-zsh")
        XCTAssertEqual(result.arguments, [], "they were written for another program")
    }

    func testEnvironmentVariablesMergeAndInvalidNamesAreSkipped() {
        var shell = IDETerminalShellSettings()
        shell.termName = "xterm-kitty"
        shell.environment = [
            IDETerminalEnvironmentVariable(name: "EDITOR", value: "vim"),
            IDETerminalEnvironmentVariable(name: "bad name", value: "x"),
            IDETerminalEnvironmentVariable(name: "", value: "x"),
            IDETerminalEnvironmentVariable(name: "1ST", value: "x"),
            IDETerminalEnvironmentVariable(name: "COLORTERM", value: "24bit"),
        ]
        let environment = launch(shell).environment
        XCTAssertEqual(environment["TERM"], "xterm-kitty")
        XCTAssertEqual(environment["EDITOR"], "vim")
        XCTAssertEqual(environment["COLORTERM"], "24bit", "an explicit variable wins over the default")
        XCTAssertNil(environment["bad name"])
        XCTAssertNil(environment["1ST"])
        XCTAssertEqual(environment.count, 3)
    }

    func testABlankTermNameFallsBackToTheDefault() {
        var shell = IDETerminalShellSettings()
        shell.termName = "  "
        XCTAssertEqual(launch(shell).environment["TERM"], "xterm-256color")
    }

    func testStartingFolderChoices() {
        var shell = IDETerminalShellSettings()
        shell.startingDirectory = .home
        XCTAssertEqual(launch(shell, project: project).directory, "/Users/tester")

        shell.startingDirectory = .custom
        shell.customDirectory = "/srv/data"
        XCTAssertEqual(launch(shell, project: project, directories: ["/srv/data"]).directory, "/srv/data")
        XCTAssertEqual(
            launch(shell, project: project).directory, "/work/project",
            "a folder that does not exist falls back to the project")

        shell.customDirectory = "~/code"
        XCTAssertEqual(
            launch(shell, project: project, directories: [(("~/code") as NSString).expandingTildeInPath]).directory,
            ("~/code" as NSString).expandingTildeInPath)
    }

    // MARK: View configuration

    private let scheme = (foreground: UInt32(0xEEEEEE), background: UInt32(0x111111), cursor: UInt32(0xFF8800))

    func testTheViewFollowsTheSchemeUnlessColorsAreCustom() {
        let followed = GhosttyTerminalViewConfiguration(settings: IDETerminalSettings(), scheme: scheme, termName: "xterm-256color")
        XCTAssertEqual(followed.vt.foreground, 0xEEEEEE)
        XCTAssertEqual(followed.vt.background, 0x111111)
        XCTAssertEqual(followed.vt.cursorColor, 0xFF8800)
        XCTAssertNil(followed.vt.ansiPalette)
        XCTAssertNil(followed.selectionColor)

        var custom = IDETerminalSettings()
        custom.usesCustomColors = true
        custom.palette.foreground = 0x00FF00
        custom.palette.selection = 0x333333
        let own = GhosttyTerminalViewConfiguration(settings: custom, scheme: scheme, termName: "xterm-256color")
        XCTAssertEqual(own.vt.foreground, 0x00FF00)
        XCTAssertEqual(own.vt.ansiPalette, custom.palette.ansi)
        XCTAssertEqual(own.selectionColor, 0x333333)
    }

    func testBehaviourSettingsReachTheViewConfiguration() {
        var settings = IDETerminalSettings()
        settings.optionAsAlt = .left
        settings.copyOnSelect = true
        settings.bell = .none
        settings.confirmUnsafePaste = false
        settings.allowTitleChange = false
        settings.clipboardWrite = .deny
        settings.clipboardRead = .allow
        settings.scrollbackLines = 4_000
        settings.cursorStyle = .underline
        let config = GhosttyTerminalViewConfiguration(settings: settings, scheme: scheme, termName: "xterm-kitty")
        XCTAssertEqual(config.optionAsAlt, .left)
        XCTAssertTrue(config.copyOnSelect)
        XCTAssertEqual(config.bell, IDETerminalBell.none)
        XCTAssertFalse(config.confirmUnsafePaste)
        XCTAssertFalse(config.allowTitleChange)
        XCTAssertFalse(config.vt.clipboardWriteAllowed)
        XCTAssertEqual(config.vt.clipboardRead, .allow)
        XCTAssertEqual(config.vt.scrollbackLines, 4_000)
        XCTAssertEqual(config.vt.cursorStyle, .underline)
        XCTAssertEqual(config.vt.termName, "xterm-kitty")
    }

    // MARK: Settings page

    func testTheTerminalPageIsFoundByGhosttysOwnKeyNames() {
        for term in ["scrollback", "macos-option-as-alt", "clipboard", "window-padding", "palette", "osc 52", "ghostty", "Terminal"] {
            XCTAssertTrue(IDEPreferencesDomain.terminal.matches(term), term)
        }
        XCTAssertFalse(IDEPreferencesDomain.terminal.matches("hugging face"))
    }

    func testTheTerminalPageSitsAfterAppearance() {
        let order = IDEPreferencesDomain.ordered(with: []).map(\.id)
        let terminal = order.firstIndex(of: "terminal")
        XCTAssertNotNil(terminal)
        XCTAssertEqual(order.firstIndex(of: "appearance").map { $0 + 1 }, terminal)
    }
}
