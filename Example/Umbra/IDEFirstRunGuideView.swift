import SwiftUI

/// First-launch overlay that teaches the keyboard-first workflow. Auto-shows until dismissed,
/// and can be reopened from Help → Welcome to Umbra.
struct IDEFirstRunGuideOverlay: View {
    @Environment(IDEWorkspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var page: IDEFirstRunGuidePage = .getStarted
    @State private var appeared = false

    var body: some View {
        ZStack {
            backdrop
            IDEFirstRunGuideCard(
                page: page,
                onSelectPage: selectPage,
                onSkip: dismiss,
                onAdvance: advance,
                onOpenFolder: openFolderAndDismiss,
                preferences: workspace.preferences,
                onKeymapChange: workspace.applyPreferencesToAllHosts
            )
            .opacity(appeared ? 1 : 0)
            .offset(y: reduceMotion || appeared ? 0 : 12)
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityElement(children: .contain)
        .onExitCommand(perform: dismiss)
        .task {
            appeared = true
        }
        .animation(appearAnimation, value: appeared)
        .animation(pageAnimation, value: page)
    }

    private var backdrop: some View {
        Color.black
            .opacity(reduceTransparency ? 0.78 : 0.52)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    private var appearAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(duration: 0.45, bounce: 0.08)
    }

    private var pageAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.1)
            : .snappy(duration: 0.22)
    }

    private func selectPage(_ newPage: IDEFirstRunGuidePage) {
        page = newPage
    }

    private func advance() {
        if let next = IDEFirstRunGuidePage(rawValue: page.rawValue + 1) {
            page = next
        } else {
            dismiss()
        }
    }

    private func dismiss() {
        workspace.dismissFirstRunGuide()
    }

    private func openFolderAndDismiss() {
        workspace.dismissFirstRunGuide()
        workspace.openFolder()
    }
}

private enum IDEFirstRunGuidePage: Int, CaseIterable, Identifiable {
    case getStarted
    case findAnything
    case edit
    case keymap

    var id: Int { rawValue }

    var stepNumber: Int { rawValue + 1 }

    var railTitle: String {
        switch self {
        case .getStarted: "Get started"
        case .findAnything: "Find anything"
        case .edit: "Edit faster"
        case .keymap: "Keymap"
        }
    }

    var heading: String {
        switch self {
        case .getStarted: "Open a folder"
        case .findAnything: "Jump without hunting"
        case .edit: "Split, search, extra carets"
        case .keymap: "Choose how keys behave"
        }
    }

    var isLast: Bool {
        self == IDEFirstRunGuidePage.allCases.last
    }
}

private struct IDEFirstRunGuideCard: View {
    let page: IDEFirstRunGuidePage
    let onSelectPage: (IDEFirstRunGuidePage) -> Void
    let onSkip: () -> Void
    let onAdvance: () -> Void
    let onOpenFolder: () -> Void
    @Bindable var preferences: IDEPreferences
    let onKeymapChange: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            IDEFirstRunGuideRail(page: page, onSelectPage: onSelectPage)

            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(width: 1)

            VStack(alignment: .leading, spacing: 0) {
                IDEFirstRunGuideHeader(title: page.heading, onClose: onSkip)

                ScrollView {
                    IDEFirstRunGuidePageBody(
                        page: page,
                        onOpenFolder: onOpenFolder,
                        preferences: preferences,
                        onKeymapChange: onKeymapChange
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, IDEAppearance.Spacing.xl)
                    .padding(.top, IDEAppearance.Spacing.md)
                    .padding(.bottom, IDEAppearance.Spacing.md)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                IDEFirstRunGuideFooter(
                    page: page,
                    onSkip: onSkip,
                    onAdvance: onAdvance
                )
            }
        }
        .frame(
            width: IDEAppearance.Spacing.firstRunGuideWidth,
            height: IDEAppearance.Spacing.firstRunGuideHeight
        )
        .background(IDEAppearance.ColorToken.editor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous)
                .stroke(IDEAppearance.ColorToken.border, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.45), radius: 28, y: 12)
    }
}

private struct IDEFirstRunGuideRail: View {
    let page: IDEFirstRunGuidePage
    let onSelectPage: (IDEFirstRunGuidePage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.lg) {
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
                Text("Umbra")
                    .font(IDEAppearance.Typography.brandTitle)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                Text("A short tour")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            .padding(.horizontal, IDEAppearance.Spacing.md)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(IDEFirstRunGuidePage.allCases) { guidePage in
                    IDEFirstRunGuideRailRow(
                        page: guidePage,
                        isSelected: guidePage == page,
                        action: { onSelectPage(guidePage) }
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, IDEAppearance.Spacing.xl)
        .padding(.bottom, IDEAppearance.Spacing.md)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .frame(width: IDEAppearance.Spacing.firstRunGuideRailWidth, alignment: .leading)
        .background(IDEAppearance.ColorToken.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tour steps")
    }
}

private struct IDEFirstRunGuideRailRow: View {
    let page: IDEFirstRunGuidePage
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Text(page.stepNumber, format: .number)
                    .font(IDEAppearance.Typography.monoCaption)
                    .monospacedDigit()
                    .foregroundStyle(
                        isSelected
                            ? IDEAppearance.ColorToken.accent
                            : IDEAppearance.ColorToken.muted
                    )
                    .frame(width: 16, alignment: .trailing)
                    .accessibilityHidden(true)

                Text(page.railTitle)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(
                        isSelected
                            ? IDEAppearance.ColorToken.foreground
                            : IDEAppearance.ColorToken.muted
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, IDEAppearance.Spacing.sm)
            .background(isSelected ? IDEAppearance.ColorToken.tabActive : Color.clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected ? IDEAppearance.ColorToken.accent : Color.clear)
                    .frame(width: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(page.stepNumber). \(page.railTitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct IDEFirstRunGuideHeader: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: IDEAppearance.Spacing.md) {
            Text(title)
                .font(IDEAppearance.Typography.brandTitle)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Close", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .buttonStyle(IDEFirstRunPlainButtonStyle())
                .help("Close")
                .keyboardShortcut(.cancelAction)
                .accessibilityHint("Dismiss the welcome tour")
        }
        .padding(.horizontal, IDEAppearance.Spacing.xl)
        .padding(.top, IDEAppearance.Spacing.xl)
        .padding(.bottom, IDEAppearance.Spacing.xs)
    }
}

private struct IDEFirstRunGuidePageBody: View {
    let page: IDEFirstRunGuidePage
    let onOpenFolder: () -> Void
    @Bindable var preferences: IDEPreferences
    let onKeymapChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.lg) {
            switch page {
            case .getStarted:
                IDEFirstRunGetStartedPage(onOpenFolder: onOpenFolder)
            case .findAnything:
                IDEFirstRunFindAnythingPage()
            case .edit:
                IDEFirstRunEditPage()
            case .keymap:
                IDEFirstRunKeymapPage(preferences: preferences, onKeymapChange: onKeymapChange)
            }
        }
    }
}

private struct IDEFirstRunGetStartedPage: View {
    let onOpenFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.lg) {
            Text("Umbra edits a project folder, not a pile of loose windows. Open a folder and the sidebar lists every file. Next launch, tabs and caret come back as you left them.")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Folder…", systemImage: "folder", action: onOpenFolder)
                .buttonStyle(IDEFirstRunPrimaryButtonStyle())
                .accessibilityHint("Keyboard shortcut Command Shift O")

            Text("Stay on the keyboard after that. The next steps cover the shortcuts that matter.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }
}

private struct IDEFirstRunFindAnythingPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            IDEFirstRunShortcutRow(
                keys: "⌘P",
                title: "Go to File",
                detail: "Open any file in the folder by name."
            )
            IDEFirstRunShortcutRow(
                keys: "⌘⇧P",
                title: "Command Palette",
                detail: "Run any action by typing its name."
            )
            IDEFirstRunShortcutRow(
                keys: "⌘R",
                title: "Go to Symbol",
                detail: "Jump to a function or type in the current file."
            )

            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                Text("Narrow the palette as you type")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)

                HStack(spacing: IDEAppearance.Spacing.md) {
                    IDEFirstRunSigilChip(sigil: ">", label: "commands")
                    IDEFirstRunSigilChip(sigil: "@", label: "symbols")
                    IDEFirstRunSigilChip(sigil: "/", label: "files")
                }
                HStack(spacing: IDEAppearance.Spacing.md) {
                    IDEFirstRunSigilChip(sigil: "#", label: "text")
                    IDEFirstRunSigilChip(sigil: ":", label: "line")
                }
            }
            .padding(.top, IDEAppearance.Spacing.xs)
        }
    }
}

private struct IDEFirstRunEditPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            IDEFirstRunLessonRow(
                systemImage: "rectangle.split.2x1",
                title: "Split the editor",
                detail: "⌘\\ opens a pane to the right. ⌘⇧\\ opens one below."
            )
            IDEFirstRunLessonRow(
                systemImage: "cursorarrow.rays",
                title: "Stack carets",
                detail: "Option-click adds another caret. ⌘D selects the next occurrence."
            )
            IDEFirstRunLessonRow(
                systemImage: "magnifyingglass",
                title: "Search the project",
                detail: "⌘F finds in the file. ⌘⇧F searches the whole folder."
            )
        }
    }
}

private struct IDEFirstRunKeymapPage: View {
    @Bindable var preferences: IDEPreferences
    let onKeymapChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            Text("Umbra ships with Sublime Text shortcuts. Switch now if your hands already know another set. You can change this later in Settings (⌘,).")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 2) {
                ForEach(KeymapPreset.allCases) { preset in
                    IDEFirstRunKeymapChoiceRow(
                        preset: preset,
                        isSelected: preferences.keymapPreset == preset,
                        action: { select(preset) }
                    )
                }
            }
            .background(IDEAppearance.ColorToken.tabActive)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
        }
    }

    private func select(_ preset: KeymapPreset) {
        preferences.keymapPreset = preset
        onKeymapChange()
    }
}

private struct IDEFirstRunKeymapChoiceRow: View {
    let preset: KeymapPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: IDEAppearance.Spacing.md) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        isSelected
                            ? IDEAppearance.ColorToken.accent
                            : IDEAppearance.ColorToken.muted
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                        .font(IDEAppearance.Typography.body)
                        .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    Text(caption)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.title)
        .accessibilityValue(caption)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var caption: String {
        switch preset {
        case .sublime: "Default. Go to File is ⌘P or double ⇧."
        case .default_: "Penumbra's original shortcut set."
        case .intelliJ: "Search Everywhere, expand selection, Go to Definition."
        }
    }
}

private struct IDEFirstRunShortcutRow: View {
    let keys: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: IDEAppearance.Spacing.md) {
            Text(keys)
                .font(IDEAppearance.Typography.monoCaption)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.vertical, IDEAppearance.Spacing.xs)
                .background(IDEAppearance.ColorToken.tabActive)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                .frame(width: 72, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                Text(detail)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(keys). \(detail)")
    }
}

private struct IDEFirstRunLessonRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                Text(detail)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.accent)
                .frame(width: 22, alignment: .center)
        }
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}

private struct IDEFirstRunSigilChip: View {
    let sigil: String
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Text(sigil)
                .font(IDEAppearance.Typography.monoCaption)
                .foregroundStyle(IDEAppearance.ColorToken.accent)
            Text(label)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .accessibilityLabel("\(sigil) \(label)")
    }
}

private struct IDEFirstRunGuideFooter: View {
    let page: IDEFirstRunGuidePage
    let onSkip: () -> Void
    let onAdvance: () -> Void
    @FocusState private var isAdvanceFocused: Bool

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.md) {
            Text("\(page.stepNumber) of \(IDEFirstRunGuidePage.allCases.count)")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .monospacedDigit()
                .accessibilityLabel("Step \(page.stepNumber) of \(IDEFirstRunGuidePage.allCases.count)")

            Spacer(minLength: 0)

            if !page.isLast {
                Button("Skip", action: onSkip)
                    .buttonStyle(IDEFirstRunPlainButtonStyle())
            }

            Button(page.isLast ? "Start Editing" : "Continue", action: onAdvance)
                .buttonStyle(IDEFirstRunPrimaryButtonStyle())
                .focused($isAdvanceFocused)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, IDEAppearance.Spacing.xl)
        .padding(.vertical, IDEAppearance.Spacing.md)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)
        }
        .task {
            isAdvanceFocused = true
        }
        .onChange(of: page) {
            isAdvanceFocused = true
        }
    }
}

private struct IDEFirstRunPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(IDEAppearance.Typography.body.bold())
            .foregroundStyle(IDEAppearance.ColorToken.workbench)
            .padding(.horizontal, IDEAppearance.Spacing.lg)
            .padding(.vertical, IDEAppearance.Spacing.sm)
            .background(
                configuration.isPressed
                    ? IDEAppearance.ColorToken.accent.opacity(0.82)
                    : IDEAppearance.ColorToken.accent
            )
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
            .opacity(configuration.isPressed ? 0.92 : 1)
    }
}

private struct IDEFirstRunPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(IDEAppearance.Typography.body)
            .foregroundStyle(
                configuration.isPressed
                    ? IDEAppearance.ColorToken.foreground
                    : IDEAppearance.ColorToken.muted
            )
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.sm)
            .contentShape(Rectangle())
    }
}

#Preview("First run guide") {
    IDEFirstRunGuideOverlay()
        .environment(IDEWorkspace())
        .preferredColorScheme(.dark)
        .frame(width: 960, height: 640)
}
