import AppKit
import SwiftUI

/// File ▸ New Project…: pick a template, name it, choose where it goes. Templates come from
/// `IDEProjectTemplates`, so a new family (Gradle) shows up here without changes to this view.
struct IDENewProjectSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var model = IDENewProjectModel()

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            Text("New Project")
                .font(IDEAppearance.Typography.brandTitle)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)

            HStack(alignment: .top, spacing: IDEAppearance.Spacing.lg) {
                templateList
                    .frame(width: 240)
                details
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 380)

            footer
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(width: 780)
    }

    // MARK: - Template list

    private var templateList: some View {
        List(selection: $model.templateID) {
            ForEach(IDEProjectTemplates.families, id: \.self) { family in
                Section(family.title) {
                    ForEach(IDEProjectTemplates.templates(in: family), id: \.id) { template in
                        Label(template.title, systemImage: template.systemImage)
                            .font(IDEAppearance.Typography.body)
                            .tag(template.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(IDEAppearance.ColorToken.sidebar, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Form

    private var details: some View {
        let template = model.template
        return VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text(template.summary)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: IDEAppearance.Spacing.md,
                 verticalSpacing: IDEAppearance.Spacing.sm) {
                GridRow {
                    label("Name")
                    TextField("MyProject", text: $model.name)
                        .textFieldStyle(.roundedBorder)
                }
                if template.fields.contains(.organizationIdentifier) {
                    GridRow {
                        label("Organization")
                        TextField("com.example", text: $model.organizationIdentifier)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if template.fields.contains(.minimumMacOS) {
                    GridRow {
                        label("Minimum macOS")
                        Picker("", selection: $model.minimumMacOS) {
                            ForEach(IDENewProjectModel.macOSVersions, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 140, alignment: .leading)
                    }
                }
                GridRow {
                    label("Location")
                    HStack(spacing: IDEAppearance.Spacing.sm) {
                        Text(model.parentDirectory.map { ($0.path as NSString).abbreviatingWithTildeInPath }
                            ?? "Choose a folder…")
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(model.parentDirectory == nil
                                ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.foreground)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…", action: chooseLocation)
                    }
                }
            }

            ForEach(model.issues.filter { $0 != .noLocation || model.parentDirectory != nil }, id: \.message) { issue in
                Text(issue.message)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(.red)
            }

            Text("Files")
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .padding(.top, IDEAppearance.Spacing.xs)
            preview
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .gridColumnAlignment(.trailing)
    }

    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.previewRows) { row in
                    HStack(spacing: 4) {
                        Image(systemName: row.isDirectory ? "folder" : "doc")
                            .foregroundStyle(row.isDirectory
                                ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.muted)
                        Text(row.name)
                    }
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .padding(.leading, CGFloat(row.depth) * IDEAppearance.Spacing.md)
                    .help(row.path)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(IDEAppearance.Spacing.sm)
        }
        .background(IDEAppearance.ColorToken.editor, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            if let message = model.errorMessage {
                Text(message)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { workspace.dismissNewProject() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCreate)
            }
        }
    }

    // MARK: - Actions

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where to create the project."
        if let current = model.parentDirectory { panel.directoryURL = current }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.parentDirectory = url
    }

    private func create() {
        Task {
            guard let created = await model.create() else { return }
            if let relative = created.template.primaryFile(for: created.options) {
                IDENewProjectOpenRequests.register(root: created.root, relativePath: relative)
            }
            workspace.dismissNewProject()
            IDEWindowRegistry.shared.open(urls: [created.root], origin: .window(workspace.windowID))
        }
    }
}
