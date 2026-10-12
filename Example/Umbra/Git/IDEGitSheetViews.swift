import GitIntelligence
import SwiftUI

/// Renders the git sheet that is current in the window's `IDEGitSheetQueue`.
struct IDEGitSheetHost: View {
    @Environment(IDEWorkspace.self) private var workspace
    let sheet: IDEGitSheet

    var body: some View {
        Group {
            switch sheet {
            case .credential(let request): IDEGitCredentialSheet(request: request, sheetID: sheet.id)
            case .smartCheckout(let request): IDEGitSmartCheckoutSheet(request: request, sheetID: sheet.id)
            case .update(let request): IDEGitUpdateSheet(request: request, sheetID: sheet.id)
            case .push(let request): IDEGitPushSheet(request: request, sheetID: sheet.id)
            case .textPrompt(let prompt): IDEGitTextPromptSheet(prompt: prompt, sheetID: sheet.id)
            case .confirm(let confirmation): IDEGitConfirmationSheet(confirmation: confirmation, sheetID: sheet.id)
            case .deleteMerged(let request): IDEGitDeleteMergedSheet(request: request, sheetID: sheet.id)
            case .stash(let request): IDEGitStashSheet(request: request, sheetID: sheet.id)
            case .reset(let request): IDEGitResetSheet(request: request, sheetID: sheet.id)
            case .rebase(let request): IDEGitRebaseSheet(request: request, sheetID: sheet.id)
            case .commitChecks(let request): IDEGitCommitChecksSheet(request: request, sheetID: sheet.id)
            case .clone(let request): IDEGitCloneSheet(model: request.model, sheetID: sheet.id)
            }
        }
        .padding(IDEAppearance.Spacing.lg)
        .environment(workspace)
        .preferredColorScheme(IDEAppearance.preferredColorScheme)
    }
}

/// Title, body and a trailing button row, so every git sheet looks alike.
private struct IDEGitSheetLayout<Content: View, Buttons: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = 460
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(IDEAppearance.Typography.sectionHeader)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                if let subtitle {
                    Text(subtitle)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            content
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Spacer(minLength: 0)
                buttons
            }
        }
        .frame(width: width)
    }
}

// MARK: - Credentials

struct IDEGitCredentialSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    let request: IDEGitCredentialRequest
    let sheetID: String
    @State private var text = ""
    @FocusState private var focused: Bool

    private var title: String {
        switch request.kind {
        case .username: "Git Needs a User Name"
        case .secret: "Git Needs a Password"
        case .confirmation: "Confirm Connection"
        case .text: "Git Needs an Answer"
        }
    }

    var body: some View {
        IDEGitSheetLayout(title: title) {
            Text(request.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch request.kind {
            case .confirmation:
                EmptyView()
            case .secret:
                SecureField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
            case .username, .text:
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
            }
        } buttons: {
            if request.kind == .confirmation {
                Button("No") { finish { request.answer("no") } }
                Button("Yes") { finish { request.answer("yes") } }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { finish { request.resolve(.cancel) } }
                    .keyboardShortcut(.cancelAction)
                Button("OK", action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { focused = true }
    }

    private func submit() { finish { request.answer(text) } }

    private func finish(_ action: () -> Void) {
        action()
        workspace.gitStatus.sheets.finish(sheetID)
    }
}

// MARK: - Smart checkout

struct IDEGitSmartCheckoutSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    let request: IDEGitSmartCheckoutRequest
    let sheetID: String

    var body: some View {
        IDEGitSheetLayout(
            title: "Local Changes Would Be Overwritten",
            subtitle: "Checking out \(request.branch) would overwrite these files:"
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(request.files, id: \.self) { file in
                        Text(file)
                            .font(IDEAppearance.Typography.monoSmall)
                            .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            Text("Smart Checkout saves your changes, switches branches, and puts them back on the new branch.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        } buttons: {
            Button("Cancel") { finish {} }
                .keyboardShortcut(.cancelAction)
            Button("Force Checkout…", role: .destructive) {
                finish {
                    let branch = request.branch
                    workspace.gitStatus.sheets.present(.confirm(IDEGitConfirmation(
                        title: "Discard Local Changes?",
                        message: "Your changes to \(request.files.count) \(request.files.count == 1 ? "file" : "files") will be lost.",
                        confirmTitle: "Discard and Checkout",
                        isDestructive: true,
                        action: { workspace.gitStatus.forceCheckout(branch: request.isRemote ? branch : branch) }
                    )))
                }
            }
            .disabled(request.isRemote)
            Button("Smart Checkout") {
                finish { workspace.gitStatus.smartCheckout(request) }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func finish(_ action: () -> Void) {
        workspace.gitStatus.sheets.finish(sheetID)
        action()
    }
}

// MARK: - Update project

struct IDEGitUpdateSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    let request: IDEGitUpdateRequest
    let sheetID: String
    @State private var rebase: Bool
    @State private var autostash = true
    @State private var dontAskAgain = false

    init(request: IDEGitUpdateRequest, sheetID: String) {
        self.request = request
        self.sheetID = sheetID
        _rebase = State(initialValue: request.strategy == .rebase)
    }

    var body: some View {
        IDEGitSheetLayout(
            title: "Update Project",
            subtitle: subtitle
        ) {
            Picker("How to update", selection: $rebase) {
                Text("Merge incoming changes").tag(false)
                Text("Rebase onto incoming changes").tag(true)
            }
            .pickerStyle(.radioGroup)
            Toggle("Save and restore uncommitted changes", isOn: $autostash)
            Toggle("Don't ask again", isOn: $dontAskAgain)
                .font(IDEAppearance.Typography.caption)
        } buttons: {
            Button("Cancel") { workspace.gitStatus.sheets.finish(sheetID) }
                .keyboardShortcut(.cancelAction)
            Button("Update") {
                let strategy: GitPullStrategy = rebase ? .rebase : .merge
                IDEGitPreferences.updateStrategy = strategy
                if dontAskAgain { IDEGitPreferences.asksBeforeUpdate = false }
                workspace.gitStatus.sheets.finish(sheetID)
                workspace.gitStatus.update(strategy: strategy, autostash: autostash)
                workspace.showSourceControl()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var subtitle: String {
        switch (request.branch, request.upstream) {
        case (let branch?, let upstream?): "\(branch) ← \(upstream)"
        case (let branch?, nil): "\(branch) has no upstream branch yet"
        default: "Fetch and integrate the remote changes"
        }
    }
}

// MARK: - Push

struct IDEGitPushSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    let request: IDEGitPushRequest
    let sheetID: String

    @State private var remote: String
    @State private var target: String
    @State private var setUpstream: Bool
    @State private var force = false
    @State private var tags: GitPushOptions.Tags = .none
    @State private var commits: [GitCommit] = []
    @State private var isLoading = true
    @State private var expanded: String?
    @State private var files: [String: [GitChangedFile]] = [:]

    init(request: IDEGitPushRequest, sheetID: String) {
        self.request = request
        self.sheetID = sheetID
        _remote = State(initialValue: request.remote)
        _target = State(initialValue: request.targetBranch)
        _setUpstream = State(initialValue: request.setsUpstream)
    }

    private var gitStatus: IDEGitStatusModel { workspace.gitStatus }

    private var forceIsRefused: Bool {
        force && IDEGitPreferences.isProtected(target)
    }

    private var canPush: Bool {
        !remote.isEmpty && !target.trimmingCharacters(in: .whitespaces).isEmpty && !forceIsRefused
    }

    var body: some View {
        IDEGitSheetLayout(title: "Push Commits", subtitle: "\(request.branch) → \(remote)/\(target)", width: 560) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Picker("Remote", selection: $remote) {
                    ForEach(request.remotes, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                TextField("Branch", text: $target)
                    .textFieldStyle(.roundedBorder)
            }
            commitList
            HStack(spacing: IDEAppearance.Spacing.md) {
                Toggle("Set as upstream", isOn: $setUpstream)
                Toggle("Force (with lease)", isOn: $force)
                Picker("Tags", selection: $tags) {
                    Text("No tags").tag(GitPushOptions.Tags.none)
                    Text("Tags on pushed commits").tag(GitPushOptions.Tags.following)
                    Text("All tags").tag(GitPushOptions.Tags.all)
                }
                .fixedSize()
            }
            .font(IDEAppearance.Typography.caption)
            if forceIsRefused {
                Text("\(target) is a protected branch: force push is not allowed.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
            }
        } buttons: {
            Button("Cancel") { gitStatus.sheets.finish(sheetID) }
                .keyboardShortcut(.cancelAction)
            Button(force ? "Force Push" : "Push") {
                let options = GitPushOptions(
                    remote: remote, source: request.branch, targetBranch: target.trimmingCharacters(in: .whitespaces),
                    setUpstream: setUpstream, forceWithLease: force, tags: tags)
                gitStatus.sheets.finish(sheetID)
                gitStatus.push(options)
                workspace.showSourceControl()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canPush)
        }
        .task(id: "\(remote)/\(target)") {
            isLoading = true
            commits = await gitStatus.outgoingCommits(source: request.branch, remote: remote, target: target)
            isLoading = false
        }
    }

    private var commitList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if commits.isEmpty {
                    Text(isLoading ? "Loading…" : "Nothing to push: \(remote)/\(target) already has these commits.")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .padding(IDEAppearance.Spacing.sm)
                }
                ForEach(commits) { commit in
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            toggle(commit)
                        } label: {
                            HStack(spacing: IDEAppearance.Spacing.sm) {
                                Image(systemName: expanded == commit.hash ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                                    .frame(width: 10)
                                Text(commit.subject).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(commit.shortHash)
                                    .font(IDEAppearance.Typography.monoSmall)
                                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                            }
                            .font(IDEAppearance.Typography.caption)
                            .padding(.vertical, 3)
                            .padding(.horizontal, IDEAppearance.Spacing.sm)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if expanded == commit.hash {
                            ForEach(files[commit.hash] ?? []) { file in
                                Button {
                                    workspace.openCommitDiff(
                                        hash: commit.hash, shortHash: commit.shortHash, file: file,
                                        files: files[commit.hash] ?? [])
                                } label: {
                                    Text("\(String(file.status))  \(file.path)")
                                        .font(IDEAppearance.Typography.monoSmall)
                                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                                        .padding(.leading, IDEAppearance.Spacing.xl)
                                        .padding(.vertical, 2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 200)
        .background(IDEAppearance.ColorToken.editor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
    }

    private func toggle(_ commit: GitCommit) {
        if expanded == commit.hash {
            expanded = nil
            return
        }
        expanded = commit.hash
        guard files[commit.hash] == nil else { return }
        Task { files[commit.hash] = await gitStatus.commitFiles(hash: commit.hash) }
    }
}

// MARK: - Text prompt, confirmation

struct IDEGitTextPromptSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    let prompt: IDEGitTextPrompt
    let sheetID: String
    @State private var text: String
    @FocusState private var focused: Bool

    init(prompt: IDEGitTextPrompt, sheetID: String) {
        self.prompt = prompt
        self.sheetID = sheetID
        _text = State(initialValue: prompt.initial)
    }

    private var problem: String? { prompt.validate(text) }

    var body: some View {
        IDEGitSheetLayout(title: prompt.title, subtitle: prompt.message.isEmpty ? nil : prompt.message, width: 380) {
            TextField(prompt.placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(confirm)
            if let problem, !text.isEmpty {
                Text(problem)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
            }
        } buttons: {
            Button("Cancel") { workspace.gitStatus.sheets.finish(sheetID) }
                .keyboardShortcut(.cancelAction)
            Button(prompt.confirmTitle, action: confirm)
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
        }
        .onAppear { focused = true }
    }

    private func confirm() {
        guard problem == nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        workspace.gitStatus.sheets.finish(sheetID)
        prompt.action(value)
    }
}

struct IDEGitConfirmationSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    let confirmation: IDEGitConfirmation
    let sheetID: String

    var body: some View {
        IDEGitSheetLayout(title: confirmation.title, subtitle: confirmation.message, width: 380) {
            EmptyView()
        } buttons: {
            Button("Cancel") { workspace.gitStatus.sheets.finish(sheetID) }
                .keyboardShortcut(.cancelAction)
            Button(confirmation.confirmTitle, role: confirmation.isDestructive ? .destructive : nil) {
                workspace.gitStatus.sheets.finish(sheetID)
                confirmation.action()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Delete merged branches

struct IDEGitDeleteMergedSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    let request: IDEGitDeleteMergedRequest
    let sheetID: String
    @State private var selected: Set<String>

    init(request: IDEGitDeleteMergedRequest, sheetID: String) {
        self.request = request
        self.sheetID = sheetID
        _selected = State(initialValue: Set(request.candidates))
    }

    var body: some View {
        IDEGitSheetLayout(
            title: "Delete Merged Branches",
            subtitle: "These local branches are fully merged into \(request.base)."
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(request.candidates, id: \.self) { name in
                        Toggle(name, isOn: Binding(
                            get: { selected.contains(name) },
                            set: { if $0 { selected.insert(name) } else { selected.remove(name) } }
                        ))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        } buttons: {
            Button("Cancel") { workspace.gitStatus.sheets.finish(sheetID) }
                .keyboardShortcut(.cancelAction)
            Button("Delete \(selected.count)", role: .destructive) {
                let names = request.candidates.filter { selected.contains($0) }
                workspace.gitStatus.sheets.finish(sheetID)
                workspace.gitStatus.deleteBranches(names)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selected.isEmpty)
        }
    }
}

// MARK: - Stash

struct IDEGitStashSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    let request: IDEGitStashRequest
    let sheetID: String
    @State private var message = ""
    @State private var includeUntracked = true
    @State private var keepIndex = false
    @FocusState private var focused: Bool

    var body: some View {
        IDEGitSheetLayout(
            title: "Stash Changes",
            subtitle: request.branch.map { "Saves the changes on \($0) and restores a clean working tree." }
                ?? "Saves the changes and restores a clean working tree."
        ) {
            TextField("Message (optional)", text: $message)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(stash)
            Toggle("Include untracked files", isOn: $includeUntracked)
            Toggle("Keep staged changes in the working tree", isOn: $keepIndex)
        } buttons: {
            Button("Cancel") { workspace.gitStatus.sheets.finish(sheetID) }
                .keyboardShortcut(.cancelAction)
            Button("Stash", action: stash)
                .keyboardShortcut(.defaultAction)
        }
        .onAppear { focused = true }
    }

    private func stash() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        workspace.gitStatus.sheets.finish(sheetID)
        workspace.gitStatus.stashChanges(message: text, includeUntracked: includeUntracked, keepIndex: keepIndex)
    }
}

// MARK: - Reset

struct IDEGitResetSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    let request: IDEGitResetRequest
    let sheetID: String
    @State private var mode: GitResetMode = .mixed

    private static let descriptions: [GitResetMode: String] = [
        .soft: "Soft: keep every change, staged",
        .mixed: "Mixed: keep the changes in the working tree, unstaged",
        .hard: "Hard: discard every change since that commit (cannot be undone)",
        .keep: "Keep: keep local changes, refusing if the move would touch them"
    ]

    var body: some View {
        IDEGitSheetLayout(
            title: "Reset Current Branch",
            subtitle: "\(request.branch ?? "HEAD") → \(request.shortHash) \(request.subject)"
        ) {
            Picker("Mode", selection: $mode) {
                ForEach([GitResetMode.soft, .mixed, .hard, .keep], id: \.self) { option in
                    Text(Self.descriptions[option] ?? option.rawValue).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if mode == .hard {
                Text("Uncommitted changes and the commits above \(request.shortHash) will be lost from this branch.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
            }
            if !request.publishedOn.isEmpty {
                Text("The commits being removed are already on \(request.publishedOn.joined(separator: ", ")): a force push will be needed.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.gitConflict)
            }
        } buttons: {
            Button("Cancel") { workspace.gitStatus.sheets.finish(sheetID) }
                .keyboardShortcut(.cancelAction)
            Button("Reset", role: mode == .hard ? .destructive : nil) {
                workspace.gitStatus.sheets.finish(sheetID)
                workspace.gitStatus.reset(to: request.hash, mode: mode)
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Interactive rebase

struct IDEGitRebaseSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    let request: IDEGitRebaseRequest
    let sheetID: String
    /// Oldest first, as git replays them; the list shows them newest first, as the log does.
    @State private var steps: [GitRebaseStep]

    init(request: IDEGitRebaseRequest, sheetID: String) {
        self.request = request
        self.sheetID = sheetID
        _steps = State(initialValue: request.steps)
    }

    private var plan: GitRebasePlan { GitRebasePlan(steps: steps) }
    private var problem: String? { plan.validationProblem() }
    private var isUnchanged: Bool { plan.changesNothing(originalOrder: request.steps.map(\.hash)) }

    var body: some View {
        IDEGitSheetLayout(
            title: "Interactively Rebase",
            subtitle: "Drag to reorder. The newest commit is at the top.",
            width: 620
        ) {
            List {
                ForEach(Array(steps.indices.reversed()), id: \.self) { index in
                    row(at: index)
                }
                .onMove { source, destination in
                    var shown = Array(steps.reversed())
                    shown.move(fromOffsets: source, toOffset: destination)
                    steps = shown.reversed()
                }
            }
            .frame(height: 280)
            if let problem {
                Text(problem)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
            } else if !request.publishedOn.isEmpty {
                Text("Some of these commits are already on \(request.publishedOn.joined(separator: ", ")): a force push will be needed afterwards.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.gitConflict)
            }
        } buttons: {
            Button("Cancel") { workspace.gitStatus.sheets.finish(sheetID) }
                .keyboardShortcut(.cancelAction)
            Button("Start Rebasing") {
                workspace.gitStatus.sheets.finish(sheetID)
                workspace.gitStatus.startInteractiveRebase(base: request.base, plan: plan)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(problem != nil || isUnchanged)
        }
    }

    private func row(at index: Int) -> some View {
        let step = steps[index]
        let headsGroup = [.pick, .reword, .edit].contains(step.action)
            && index + 1 < steps.count && [.squash, .fixup].contains(steps[index + 1].action)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Picker("", selection: Binding(
                    get: { steps[index].action },
                    set: { newAction in
                        steps[index].action = newAction
                        if newAction == .reword, steps[index].message == nil { steps[index].message = step.subject }
                    }
                )) {
                    ForEach(GitRebaseStep.Action.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Text(step.subject)
                    .lineLimit(1)
                    .strikethrough(step.action == .drop)
                    .foregroundStyle(step.action == .drop ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.foreground)
                Spacer(minLength: 0)
                Text(String(step.hash.prefix(7)))
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            if step.action == .reword {
                TextField("New message", text: Binding(
                    get: { steps[index].message ?? "" },
                    set: { steps[index].message = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            } else if headsGroup {
                TextField("Message of the combined commit (git's own if empty)", text: Binding(
                    get: { steps[index].message ?? "" },
                    set: { steps[index].message = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
        .font(IDEAppearance.Typography.caption)
        .padding(.vertical, 2)
    }
}

// MARK: - Commit checks

struct IDEGitCommitChecksSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    let request: IDEGitCommitChecksRequest
    let sheetID: String
    @State private var name = ""
    @State private var email = ""

    private var hasBlocking: Bool { IDEGitCommitChecks.hasBlocking(request.findings) }
    private var needsAuthor: Bool { request.findings.contains { $0.kind == .authorMissing } }

    var body: some View {
        IDEGitSheetLayout(
            title: "Check Before Committing",
            subtitle: hasBlocking ? "Fix what blocks the commit first." : "Review these, or commit anyway.",
            width: 520
        ) {
            ForEach(request.findings) { finding in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: IDEAppearance.Spacing.xs) {
                        Image(systemName: finding.severity == .blocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(finding.severity == .blocking ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.gitConflict)
                        Text(finding.title).font(IDEAppearance.Typography.tabLabel.weight(.semibold))
                    }
                    Text(finding.detail)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if finding.kind == .lineEndings {
                        Button("Convert to LF and Keep Them That Way") {
                            workspace.gitStatus.sheets.finish(sheetID)
                            workspace.gitStatus.normalizeLineEndings(paths: finding.paths) {
                                workspace.gitStatus.requestCommit(options: request.options)
                            }
                        }
                        .controlSize(.small)
                    }
                    if finding.kind == .detachedHead {
                        Button("New Branch…") {
                            workspace.gitStatus.sheets.finish(sheetID)
                            workspace.promptNewBranch()
                        }
                        .controlSize(.small)
                    }
                }
            }
            if needsAuthor {
                VStack(spacing: IDEAppearance.Spacing.xs) {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    TextField("Email", text: $email).textFieldStyle(.roundedBorder)
                }
            }
        } buttons: {
            Button("Cancel") { workspace.gitStatus.sheets.finish(sheetID) }
                .keyboardShortcut(.cancelAction)
            if needsAuthor {
                Button("Save for This Repository and Commit") {
                    workspace.gitStatus.sheets.finish(sheetID)
                    workspace.gitStatus.setAuthor(name: name, email: email) {
                        workspace.gitStatus.requestCommit(options: request.options)
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !email.contains("@"))
            }
            if !hasBlocking {
                Button("Commit Anyway") {
                    workspace.gitStatus.sheets.finish(sheetID)
                    workspace.gitStatus.performCommit(message: request.message, options: request.options)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Clone

struct IDEGitCloneSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    @Bindable var model: IDEGitCloneModel
    let sheetID: String

    var body: some View {
        IDEGitSheetLayout(title: "Clone Repository", subtitle: "Copy a repository from a server to this Mac.", width: 520) {
            TextField("https://github.com/owner/repo.git", text: $model.url)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isWorking)
                .onChange(of: model.url) { model.urlDidChange() }
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Text("Into").foregroundStyle(IDEAppearance.ColorToken.muted)
                Text(model.parentDirectory.path)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…") { chooseFolder() }
                    .disabled(model.isWorking)
            }
            .font(IDEAppearance.Typography.caption)
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Text("Folder name").foregroundStyle(IDEAppearance.ColorToken.muted)
                TextField("repo", text: $model.name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isWorking)
                    .onChange(of: model.name) { model.nameDidChange() }
            }
            .font(IDEAppearance.Typography.caption)
            Toggle("Clone submodules too", isOn: $model.recurseSubmodules)
                .disabled(model.isWorking)
            if model.isWorking {
                HStack(spacing: IDEAppearance.Spacing.sm) {
                    if let fraction = model.progress?.fraction {
                        ProgressView(value: fraction).frame(width: 140)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.progress?.phase ?? "Starting…")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .lineLimit(1)
                }
            }
            if let error = model.error {
                Text(error)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .textSelection(.enabled)
            } else if let result = model.checkResult {
                Text(result)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.gitAdded)
            }
        } buttons: {
            Button("Test") { model.check() }
                .disabled(model.isWorking || model.url.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") {
                model.cancel()
                workspace.gitStatus.sheets.finish(sheetID)
            }
            .keyboardShortcut(.cancelAction)
            Button("Clone") { model.clone() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canClone)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = model.parentDirectory
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { model.parentDirectory = url }
    }
}

