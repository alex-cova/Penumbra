import AppKit
import SwiftUI

/// Settings ▸ Terminal: the terminal's font, colours, behaviour, shell and what programs in it may do.
/// Each setting stands for a Ghostty configuration key; the keys are in the page's search terms.
struct IDEPreferencesTerminalPane: View {
    @Bindable var preferences: IDEPreferences

    var body: some View {
        fontSection
        colorsSection
        cursorSection
        behaviorSection
        shellSection
        integrationsSection
        resetSection
    }

    // MARK: Font

    private var fontSection: some View {
        IDESettingsSection(
            "Font",
            footer: "The terminal draws a fixed grid, so only monospaced fonts are offered."
        ) {
            IDESettingsToggle("Use the editor's font", isOn: $preferences.terminal.fontFollowsEditor)
            if !preferences.terminal.fontFollowsEditor {
                IDESettingsPicker("Font", selection: $preferences.terminal.fontFamily) {
                    ForEach(IDEEditorFonts.choices(including: preferences.terminal.fontFamily), id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                IDEPreferencesStepper(
                    title: "Font Size", value: $preferences.terminal.fontSize, range: 8...40, step: 1,
                    fractionLength: 0, valueWidth: 24)
            }
            IDEPreferencesStepper(
                title: "Row Height", value: $preferences.terminal.cellHeightAdjustPercent,
                range: IDETerminalSettings.cellHeightRange, step: 5, valueWidth: 48, valueSuffix: "%")
            IDEPreferencesStepper(
                title: "Left Padding", value: $preferences.terminal.paddingX, range: 0...64, step: 1,
                fractionLength: 0, valueWidth: 24)
            IDEPreferencesStepper(
                title: "Vertical Padding", value: $preferences.terminal.paddingY, range: 0...64, step: 1,
                fractionLength: 0, valueWidth: 24)
        }
    }

    // MARK: Colors

    private var colorsSection: some View {
        IDESettingsSection(
            "Colors",
            footer: "Follow the UI theme uses the interface colours and the standard ANSI palette. Custom lets you set all of them."
        ) {
            IDESettingsPicker("Colors", selection: $preferences.terminal.usesCustomColors) {
                Text("Follow UI Theme").tag(false)
                Text("Custom").tag(true)
            }
            if preferences.terminal.usesCustomColors {
                IDESettingsColorWell(title: "Foreground", hex: $preferences.terminal.palette.foreground)
                IDESettingsColorWell(title: "Background", hex: $preferences.terminal.palette.background)
                IDESettingsColorWell(title: "Cursor", hex: $preferences.terminal.palette.cursor)
                IDESettingsColorWell(title: "Selection", hex: $preferences.terminal.palette.selection)
                IDETerminalPaletteGrid(palette: $preferences.terminal.palette)
                IDETerminalPalettePreview(palette: preferences.terminal.palette)
                HStack {
                    Button("Reset Palette") { preferences.terminal.palette = IDETerminalPalette() }
                        .disabled(preferences.terminal.palette == IDETerminalPalette())
                    Spacer(minLength: 0)
                }
            }
            IDEPreferencesStepper(
                title: "Faint Text Opacity", value: $preferences.terminal.faintOpacity, range: 0.2...1, step: 0.05,
                fractionLength: 2, valueWidth: 36)
        }
    }

    // MARK: Cursor

    private var cursorSection: some View {
        IDESettingsSection("Cursor", footer: "A program can still choose its own cursor, as editors in the terminal do.") {
            IDESettingsPicker("Style", selection: $preferences.terminal.cursorStyle) {
                ForEach(IDETerminalCursorStyle.allCases) { Text($0.title).tag($0) }
            }
            IDESettingsToggle("Blink the cursor", isOn: $preferences.terminal.cursorBlinks)
        }
    }

    // MARK: Behavior

    private var behaviorSection: some View {
        IDESettingsSection("Behavior") {
            IDEPreferencesStepper(
                title: "Scrollback", value: $preferences.terminal.scrollbackLines,
                range: IDETerminalSettings.scrollbackRange, step: 1_000, valueWidth: 72, valueSuffix: " lines")
            IDESettingsPicker("Option as Meta", selection: $preferences.terminal.optionAsAlt) {
                ForEach(IDETerminalOptionAsAlt.allCases) { Text($0.title).tag($0) }
            }
            IDESettingsPicker("Bell", selection: $preferences.terminal.bell) {
                ForEach(IDETerminalBell.allCases) { Text($0.title).tag($0) }
            }
            IDESettingsToggle("Copy on select", isOn: $preferences.terminal.copyOnSelect,
                              detail: "Selecting text with the mouse copies it right away.")
            IDESettingsToggle("Hide the mouse pointer while typing", isOn: $preferences.terminal.hideMouseWhileTyping)
            IDESettingsToggle("Scroll to the bottom when typing", isOn: $preferences.terminal.scrollToBottomOnKeystroke)
            IDESettingsToggle("Scroll to the bottom on new output", isOn: $preferences.terminal.scrollToBottomOnOutput,
                              detail: "Off keeps the view where you scrolled while a command is still printing.")
            IDESettingsToggle("Confirm before pasting text that may run commands",
                              isOn: $preferences.terminal.confirmUnsafePaste,
                              detail: "Text with line breaks, pasted into a prompt that does not hold it back.")
        }
    }

    // MARK: Shell

    private var shellSection: some View {
        IDESettingsSection(
            "Shell",
            footer: "Applies to shells started after the change. Restart a terminal tab to use it there. These settings stay on this Mac."
        ) {
            IDESettingsRow("Command") {
                TextField(IDETerminalShell.resolvedShell(), text: $preferences.terminalShell.command)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .accessibilityLabel("Shell command")
            }
            IDESettingsRow("Arguments") {
                TextField("none", text: $preferences.terminalShell.arguments)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .accessibilityLabel("Shell arguments")
            }
            IDESettingsToggle("Start as a login shell", isOn: $preferences.terminalShell.loginShell,
                              detail: "Reads your profile files, as Terminal.app does.")
            IDESettingsPicker("Starting Folder", selection: $preferences.terminalShell.startingDirectory) {
                ForEach(IDETerminalStartDirectory.allCases) { Text($0.title).tag($0) }
            }
            if preferences.terminalShell.startingDirectory == .custom {
                IDESettingsRow("Folder") {
                    TextField("~/", text: $preferences.terminalShell.customDirectory)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .accessibilityLabel("Starting folder")
                    Button("Choose…", action: chooseStartingFolder)
                }
            }
            IDESettingsRow("TERM") {
                TextField(IDETerminalShellSettings.defaultTermName, text: $preferences.terminalShell.termName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .accessibilityLabel("TERM")
            }
            environmentEditor
        }
    }

    private var environmentEditor: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            HStack {
                Text("Environment Variables")
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                Spacer(minLength: 0)
                IDEIconButton(systemImage: "plus", help: "Add Variable") {
                    preferences.terminalShell.environment.append(IDETerminalEnvironmentVariable())
                }
                .ideIconButtonSize(.compact)
            }
            ForEach($preferences.terminalShell.environment) { $variable in
                HStack(spacing: IDEAppearance.Spacing.sm) {
                    TextField("NAME", text: $variable.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .foregroundStyle(variable.name.isEmpty || variable.isValidName
                            ? IDEAppearance.ColorToken.foreground : Color.red)
                        .accessibilityLabel("Variable name")
                    Text("=")
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .accessibilityHidden(true)
                    TextField("value", text: $variable.value)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Variable value")
                    IDEIconButton(systemImage: "minus.circle", help: "Remove Variable") {
                        preferences.terminalShell.environment.removeAll { $0.id == variable.id }
                    }
                    .ideIconButtonSize(.compact)
                }
            }
            if preferences.terminalShell.environment.isEmpty {
                Text("None. The shell starts with Umbra's environment, plus TERM and COLORTERM.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
    }

    private func chooseStartingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            preferences.terminalShell.customDirectory = url.path
        }
    }

    // MARK: Integrations

    private var integrationsSection: some View {
        IDESettingsSection(
            "Integrations & Security",
            footer: "Programs reach these through escape sequences, so a remote host or a file you print can use them."
        ) {
            IDESettingsPicker("Programs reading the clipboard", selection: $preferences.terminal.clipboardRead) {
                ForEach(IDETerminalClipboardAccess.allCases) { Text($0.title).tag($0) }
            }
            IDESettingsPicker("Programs writing the clipboard", selection: $preferences.terminal.clipboardWrite) {
                Text(IDETerminalClipboardAccess.allow.title).tag(IDETerminalClipboardAccess.allow)
                Text(IDETerminalClipboardAccess.deny.title).tag(IDETerminalClipboardAccess.deny)
            }
            IDESettingsToggle("Show desktop notifications from programs",
                              isOn: $preferences.terminal.desktopNotifications,
                              detail: "Programs ask with OSC 9 or OSC 777. They appear in the notification bell under Terminal.")
            IDESettingsToggle("Let programs set the tab title", isOn: $preferences.terminal.allowTitleChange)
            IDESettingsToggle("Let programs read back the title",
                              isOn: $preferences.terminal.allowTitleReport,
                              detail: "A program could put text in the title and have it typed into the shell. Leave off unless you need it.")
        }
    }

    private var resetSection: some View {
        HStack {
            Button("Restore Terminal Defaults") { preferences.terminal = IDETerminalSettings() }
                .disabled(preferences.terminal == IDETerminalSettings())
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Palette editor

private func terminalColor(_ hex: UInt32) -> Color {
    Color(
        .sRGB,
        red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255, opacity: 1)
}

/// The sixteen ANSI colours: normal on the first row, bright on the second.
private struct IDETerminalPaletteGrid: View {
    @Binding var palette: IDETerminalPalette

    private func binding(_ index: Int) -> Binding<Color> {
        Binding(
            get: { terminalColor(palette.ansi[index]) },
            set: { palette.ansi[index] = $0.sRGBHex ?? palette.ansi[index] }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text("ANSI Colors")
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            Grid(horizontalSpacing: IDEAppearance.Spacing.sm, verticalSpacing: IDEAppearance.Spacing.xs) {
                GridRow {
                    ForEach(0..<8, id: \.self) { column in
                        Text(IDETerminalPalette.ansiNames[column])
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                    }
                }
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<8, id: \.self) { column in
                            let index = row * 8 + column
                            ColorPicker(
                                "\(row == 1 ? "Bright " : "")\(IDETerminalPalette.ansiNames[column])",
                                selection: binding(index), supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                }
            }
        }
    }
}

/// The palette as the terminal will show it: sample text in the foreground and the sixteen colours as blocks.
private struct IDETerminalPalettePreview: View {
    let palette: IDETerminalPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("user@umbra ~ % ls --color")
                .font(.system(size: 12, design: .monospaced)) // token-exempt: a fixed-size sample, not chrome
                .foregroundStyle(terminalColor(palette.foreground))
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.top, IDEAppearance.Spacing.sm)
            HStack(spacing: 0) {
                ForEach(0..<16, id: \.self) { index in
                    Rectangle().fill(terminalColor(palette.ansi[index])).frame(height: 14)
                }
            }
            .padding(IDEAppearance.Spacing.sm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(terminalColor(palette.background), in: .rect(cornerRadius: IDEAppearance.Radius.control))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Palette preview")
    }
}
