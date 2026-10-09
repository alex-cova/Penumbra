import JavaIntelligence
import SwiftUI

/// Run ▸ Edit Configurations…: every configuration of the project by kind and folder on the left,
/// the selected one's settings on the right, and the templates new configurations start from.
/// Edits stay in `IDERunConfigurationsEditor` until OK or Apply writes them.
struct IDERunConfigurationsWindow: View {
    @Environment(IDEWorkspace.self) private var workspace
    let editor: IDERunConfigurationsEditor
    @State private var folderPromptFor: UUID?
    @State private var folderName = ""

    var body: some View {
        VStack(spacing: 0) {
            SplitPanes(minPrimary: 200, idealPrimary: 250, minSecondary: 360, defaultFraction: 0.28, storageKey: "umbra.runConfigurations.split") {
                list
            } secondary: {
                detail
            } divider: {
                Splitter.rule()
            }
            Divider().overlay(IDEAppearance.ColorToken.border)
            buttons
        }
        .frame(minWidth: 860, idealWidth: 920, minHeight: 560, idealHeight: 640)
        .background(IDEAppearance.ColorToken.workbench)
        .alert("Move into New Folder", isPresented: Binding(get: { folderPromptFor != nil }, set: { if !$0 { folderPromptFor = nil } })) {
            TextField("Folder name", text: $folderName)
            Button("Move") {
                if let id = folderPromptFor { editor.move(id, toFolder: folderName) }
                folderPromptFor = nil
            }
            Button("Cancel", role: .cancel) { folderPromptFor = nil }
        }
    }

    // MARK: - List

    private var allConfigurations: [JavaRunConfiguration] { editor.configurations }

    private func problems(of configuration: JavaRunConfiguration) -> [JavaRunConfigurationValidator.Problem] {
        workspace.validationProblems(for: configuration, among: allConfigurations)
    }

    private var list: some View {
        VStack(spacing: 0) {
            listToolbar
            Divider().overlay(IDEAppearance.ColorToken.border)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(JavaRunConfiguration.Kind.allCases, id: \.self) { kind in
                        let groups = editor.groups(of: kind)
                        if !groups.isEmpty {
                            sectionHeader(kind.title)
                            ForEach(groups, id: \.folder) { group in
                                if let folder = group.folder {
                                    Label(folder, systemImage: "folder")
                                        .font(IDEAppearance.Typography.caption)
                                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                                        .padding(.leading, 18)
                                        .padding(.top, 4)
                                }
                                ForEach(group.configurations, id: \.id) { configuration in
                                    row(configuration, indent: group.folder == nil ? 18 : 32)
                                }
                            }
                        }
                    }
                    sectionHeader("Templates")
                    ForEach(JavaRunConfiguration.Kind.allCases, id: \.self) { kind in
                        templateRow(kind)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(IDEAppearance.ColorToken.sidebar)
    }

    private var listToolbar: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Menu {
                ForEach(JavaRunConfiguration.Kind.allCases, id: \.self) { kind in
                    Button(kind.title) { editor.add(kind: kind, target: workspace.defaultTarget(for: kind)) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add New Configuration")
            toolbarButton("minus", help: "Remove Configuration", enabled: editor.selectedConfigurationID != nil) {
                if let id = editor.selectedConfigurationID { editor.remove(id) }
            }
            toolbarButton("plus.square.on.square", help: "Duplicate", enabled: editor.selectedConfigurationID != nil) {
                if let id = editor.selectedConfigurationID { editor.duplicate(id) }
            }
            toolbarButton("folder.badge.plus", help: "Move into New Folder", enabled: editor.selectedConfigurationID != nil) {
                folderName = ""
                folderPromptFor = editor.selectedConfigurationID
            }
            if let id = editor.selectedConfigurationID, editor.selected?.isTemporary == true {
                toolbarButton("checkmark.circle", help: "Save Configuration", enabled: true) { editor.keep(id) }
            }
            Spacer()
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, 6)
    }

    private func toolbarButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .help(help)
            .accessibilityLabel(help)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(IDEAppearance.Typography.caption.weight(.semibold))
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func row(_ configuration: JavaRunConfiguration, indent: CGFloat) -> some View {
        let isSelected = editor.selection == .configuration(configuration.id)
        let broken = !problems(of: configuration).isEmpty
        return HStack(spacing: 6) {
            Image(systemName: icon(for: configuration.kind))
                .font(.system(size: 11))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 14)
            Text(configuration.displayName)
                .lineLimit(1)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            if configuration.storeAsProjectFile {
                Image(systemName: "person.2")
                    .font(.system(size: 9))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .help("Shared in .umbra/runConfigurations")
            }
            Spacer(minLength: 0)
            if editor.isChanged(configuration.id) {
                Circle().fill(IDEAppearance.ColorToken.accent).frame(width: 6, height: 6).help("Changed")
            }
            if broken {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .help(problems(of: configuration).map(\.message).joined(separator: "\n"))
            }
        }
        .opacity(configuration.isTemporary ? 0.55 : 1)
        .padding(.leading, indent)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(isSelected ? IDEAppearance.ColorToken.accent.opacity(0.22) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { editor.selection = .configuration(configuration.id) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(configuration.displayName)\(configuration.isTemporary ? ", temporary" : "")\(broken ? ", has errors" : "")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func templateRow(_ kind: JavaRunConfiguration.Kind) -> some View {
        let isSelected = editor.selection == .template(kind)
        return HStack(spacing: 6) {
            Image(systemName: icon(for: kind))
                .font(.system(size: 11))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 14)
            Text(kind.title)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            Spacer()
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(isSelected ? IDEAppearance.ColorToken.accent.opacity(0.22) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { editor.selection = .template(kind) }
        .accessibilityLabel("\(kind.title) template")
    }

    private func icon(for kind: JavaRunConfiguration.Kind) -> String {
        switch kind {
        case .application: return "play.rectangle"
        case .javaFile: return "doc.text"
        case .gradle: return "hammer"
        case .junit: return "flask"
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let selected = editor.selected {
            let isTemplate: Bool = { if case .template = editor.selection { return true } else { return false } }()
            IDERunConfigurationForm(
                configuration: Binding(get: { editor.selected ?? selected }, set: { editor.selected = $0 }),
                problems: isTemplate ? [] : problems(of: selected),
                otherConfigurations: allConfigurations,
                isTemplate: isTemplate
            )
            .id(editor.selection)
        } else {
            VStack(spacing: IDEAppearance.Spacing.sm) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 28))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Text("No run configurations yet")
                    .font(IDEAppearance.Typography.body)
                Text("Press + to add one, or run a class from its gutter button.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Buttons

    private var canLaunch: Bool {
        guard let id = editor.selectedConfigurationID, let configuration = editor.configurations.first(where: { $0.id == id }) else { return false }
        return problems(of: configuration).isEmpty
    }

    private var buttons: some View {
        HStack {
            if case .template = editor.selection {
                Button("Reset Template") {
                    if case .template(let kind) = editor.selection { editor.resetTemplate(kind) }
                }
            }
            Spacer()
            Button("Cancel", role: .cancel) { workspace.dismissRunConfigurationSheet() }
                .keyboardShortcut(.cancelAction)
            Button("Apply") { apply() }
                .disabled(!editor.hasChanges)
            if editor.selected?.supportsDebugLaunch == true, editor.selectedConfigurationID != nil {
                Button("Debug") { launch(debug: true) }
                    .disabled(!canLaunch)
            }
            if editor.selectedConfigurationID != nil {
                Button("Run") { launch(debug: false) }
                    .disabled(!canLaunch)
            }
            Button("OK") {
                apply()
                workspace.dismissRunConfigurationSheet()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(IDEAppearance.Spacing.md)
    }

    private func apply() {
        workspace.applyRunConfigurationEdits(editor.changes(), select: editor.selectedConfigurationID)
        editor.markApplied()
    }

    private func launch(debug: Bool) {
        guard let id = editor.selectedConfigurationID,
              let configuration = editor.configurations.first(where: { $0.id == id }) else { return }
        apply()
        workspace.dismissRunConfigurationSheet()
        workspace.launch(configuration, mode: debug ? .debug : .run)
    }
}
