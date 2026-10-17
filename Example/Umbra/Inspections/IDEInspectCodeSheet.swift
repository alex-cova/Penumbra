import AppKit
import JavaIntelligence
import SwiftUI

/// Code ▸ Inspect Code… (and the second step of Run Inspection by Name…): which files, with
/// which profile. Analyze lists the findings in a Problems tab; Fix All applies a named
/// inspection's fixes straight away.
struct IDEInspectCodeSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    let request: IDEInspectCodeRequest

    private enum Choice: Hashable {
        case project, module, directory, currentFile, selectedFiles, uncommitted, openFiles
    }

    @State private var choice: Choice = .project
    @State private var modulePath = ""
    @State private var directory: URL?
    @State private var includeTests = true
    @State private var masks = ""
    @State private var includeProjectRules = false
    @State private var source: IDEWorkspaceInspections.Source = .global(IDEInspectionProfiles.defaultName)
    @State private var isBusy = false

    private var inspections: IDEWorkspaceInspections { workspace.inspections }

    private var modules: [(path: String, directory: URL)] {
        (workspace.javaSupport.projectModel?.subprojects ?? [])
            .filter { !$0.sourceSets.isEmpty }
            .map { ($0.path, $0.directory) }
    }

    private var openFiles: [URL] {
        workspace.workbench.allDocuments().compactMap(\.url).filter { $0.pathExtension == "java" }
    }

    private var uncommittedFiles: [URL] {
        guard let root = workspace.project.rootURL else { return [] }
        return workspace.gitStatus.changes
            .map { URL(fileURLWithPath: $0.path, relativeTo: root).standardizedFileURL }
            .filter { $0.pathExtension == "java" }
    }

    private var scope: JavaInspectionScope? {
        let kind: JavaInspectionScope.Kind
        switch choice {
        case .project: kind = .project
        case .module:
            guard let match = modules.first(where: { $0.path == modulePath }) else { return nil }
            kind = .module(directory: match.directory)
        case .directory:
            guard let target = directory ?? workspace.project.rootURL else { return nil }
            kind = .directory(target)
        case .currentFile:
            guard let file = request.currentFile else { return nil }
            kind = .files([file])
        case .selectedFiles:
            guard !request.selectedFiles.isEmpty else { return nil }
            kind = .files(request.selectedFiles)
        case .uncommitted: kind = .uncommitted(uncommittedFiles)
        case .openFiles: kind = .openFiles(openFiles)
        }
        return JavaInspectionScope(kind: kind, includeTests: includeTests, fileMasks: masks)
    }

    private var title: String {
        request.rule.map { "Run Inspection: \($0.title)" } ?? "Inspect Code"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            Text(title).font(IDEAppearance.Typography.sidebarHeader)
            if let rule = request.rule {
                Text(rule.summary)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Scope", selection: $choice) {
                Text("Whole project").tag(Choice.project)
                if !modules.isEmpty { Text("Module").tag(Choice.module) }
                Text("Directory").tag(Choice.directory)
                if request.currentFile != nil { Text("Current file").tag(Choice.currentFile) }
                if !request.selectedFiles.isEmpty { Text("Selected files (\(request.selectedFiles.count))").tag(Choice.selectedFiles) }
                Text("Uncommitted files (\(uncommittedFiles.count))").tag(Choice.uncommitted)
                Text("Open files (\(openFiles.count))").tag(Choice.openFiles)
            }
            if choice == .module {
                Picker("Module", selection: $modulePath) {
                    ForEach(modules, id: \.path) { Text($0.path).tag($0.path) }
                }
            }
            if choice == .directory {
                HStack {
                    Text(directory?.path ?? workspace.project.rootURL?.path ?? "No folder")
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                    Spacer()
                    Button("Choose…") { chooseDirectory() }
                }
            }
            Toggle("Include test sources", isOn: $includeTests)
            HStack {
                Text("File masks")
                TextField("*.java, !**/generated/**", text: $masks)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Include project-wide inspections (slower)", isOn: $includeProjectRules)
                .help("Unused declaration, weaker access, void return and constant parameter checks search the whole project")
            Picker("Profile", selection: $source) {
                if inspections.hasProjectProfile { Text("Project").tag(IDEWorkspaceInspections.Source.project) }
                ForEach(inspections.store.names, id: \.self) { Text($0).tag(IDEWorkspaceInspections.Source.global($0)) }
            }
            HStack {
                Button("Configure Profile…") {
                    close()
                    workspace.requestedSettingsDomain = .inspections
                    workspace.showSettings()
                }
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                if let rule = request.rule, rule.hasQuickFix {
                    Button("Fix All") { fixAll(rule: rule) }
                        .disabled(scope == nil || isBusy)
                }
                Button("Analyze") { analyze() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(scope == nil || isBusy)
            }
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(width: 460)
        .onAppear { configureDefaults() }
    }

    private func configureDefaults() {
        source = inspections.activeSource
        modulePath = modules.first?.path ?? ""
        directory = request.directory
        if request.directory != nil {
            choice = .directory
        } else if !request.selectedFiles.isEmpty {
            choice = .selectedFiles
        } else if request.rule != nil, request.currentFile != nil {
            choice = .currentFile
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = directory ?? workspace.project.rootURL
        if panel.runModal() == .OK { directory = panel.url }
    }

    private func close() {
        workspace.inspectionRuns.pendingScopeRequest = nil
    }

    private func launch() -> IDEInspectionLaunch? {
        guard let scope else { return nil }
        let profile = inspections.profile(for: source) ?? inspections.activeProfile
        return IDEInspectionLaunch(
            scope: scope, profile: profile, profileName: inspections.title(for: source),
            onlyRules: request.rule.map { [$0] }, includeProjectRules: includeProjectRules
        )
    }

    private func analyze() {
        guard let launch = launch() else { return }
        close()
        workspace.startInspection(launch)
    }

    private func fixAll(rule: JavaInspectionRule) {
        guard let launch = launch() else { return }
        isBusy = true
        let root = workspace.project.rootURL
        let classifier = JavaInspectionFileClassifier(projectRoot: root, testRoots: workspace.javaTestSourceRoots)
        Task {
            let files = await Task.detached(priority: .userInitiated) {
                launch.scope.resolve(projectRoots: root.map { [$0] } ?? [], classifier: classifier)
            }.value
            let outcome = await workspace.fixAll(rules: [rule], in: files)
            close()
            if outcome.fixedCount == 0 {
                workspace.notifications.post("Nothing to fix", detail: rule.title)
            } else {
                workspace.notifications.post(
                    "Fixed \(outcome.fixedCount) problem\(outcome.fixedCount == 1 ? "" : "s") in \(outcome.fileCount) file\(outcome.fileCount == 1 ? "" : "s")",
                    detail: rule.title, action: .showSourceControl
                )
            }
        }
    }
}

/// Code ▸ Run Inspection by Name…: a search over every inspection; Return picks one and asks for
/// the scope.
struct IDEInspectionByNameSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var query = ""
    @State private var highlighted: JavaInspectionRule?

    private var matches: [JavaInspectionRule] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let all = JavaInspectionRule.allCases
        guard !words.isEmpty else { return all.sorted { $0.title < $1.title } }
        return all.filter { rule in
            let haystack = (rule.title + " " + rule.code + " " + rule.group.title).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        .sorted { $0.title < $1.title }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text("Run Inspection by Name").font(IDEAppearance.Typography.sidebarHeader)
            TextField("Inspection name", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { pick(highlighted ?? matches.first) }
            HStack(alignment: .top, spacing: IDEAppearance.Spacing.md) {
                List(matches.prefix(200).map { $0 }, id: \.self, selection: $highlighted) { rule in
                    HStack {
                        Text(rule.title)
                        Spacer()
                        Text(rule.group.title)
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                    }
                    .tag(rule)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { pick(rule) }
                }
                .frame(minHeight: 260)
                VStack(alignment: .leading, spacing: 6) {
                    if let rule = highlighted ?? matches.first {
                        Text(rule.title).font(IDEAppearance.Typography.sidebarHeader)
                        Text(rule.summary).font(IDEAppearance.Typography.body)
                        Text(rule.hasQuickFix ? "Has a quick fix" : "No quick fix")
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                    }
                    Spacer()
                }
                .frame(width: 200, alignment: .topLeading)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { workspace.inspectionRuns.isNamePickerPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { pick(highlighted ?? matches.first) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(matches.isEmpty)
            }
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(width: 640)
    }

    private func pick(_ rule: JavaInspectionRule?) {
        guard let rule else { return }
        workspace.inspectionRuns.isNamePickerPresented = false
        workspace.inspectionRuns.pendingScopeRequest = IDEInspectCodeRequest(
            rule: rule,
            currentFile: workspace.workbench.activePane.selectedDocument?.url.flatMap { $0.pathExtension == "java" ? $0 : nil }
        )
    }
}
