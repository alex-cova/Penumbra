import SwiftUI

struct IDEGitHubToolWindow: View {
    let workspace: IDEWorkspace
    let accounts: IDEGitHubAccounts
    let model: IDEGitHubWorkspaceModel

    @State private var reload = 0
    @FocusState private var hasFocus: Bool

    private struct Request: Equatable {
        let remotes: [IDEGitHubWorkspaceModel.Remote]
        let remote: String?
        let account: Int64?
        let revision: Int
        let reload: Int
    }

    private var request: Request {
        Request(remotes: model.remotes, remote: model.selectedRemote,
                account: model.accountID(accounts.identities), revision: accounts.revision, reload: reload)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
                HStack {
                    Text("Repository").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        reload += 1
                        model.refreshRemotes()
                    }
                    .labelStyle(.iconOnly)
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(IDEAppearance.Spacing.md)
        }
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .focusable()
        .focused($hasFocus)
        .onChange(of: workspace.sidebarFocusRequestID, initial: true) {
            if workspace.consumeSidebarFocusIfNeeded(for: .github) { hasFocus = true }
        }
        .onAppear { model.activate() }
        .onDisappear { model.deactivate() }
        .task { await accounts.reload() }
        .task(id: request) {
            await model.loadMetadata(using: accounts)
        }
    }

    @ViewBuilder private var content: some View {
        if model.discovering {
            ProgressView("Looking for GitHub remotes…")
        } else if model.remotes.isEmpty {
            Text("This repository has no supported GitHub.com fetch remotes.")
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        } else {
            Picker("Remote", selection: Binding(get: { model.selectedRemote }, set: model.selectRemote)) {
                Text("Choose a remote").tag(nil as String?)
                ForEach(model.remotes) { remote in
                    Text("\(remote.name) · \(remote.repository.owner)/\(remote.repository.repository)")
                        .tag(Optional(remote.name))
                }
            }
            if accounts.service == nil {
                Text("GitHub sign-in isn’t configured for this build.")
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else if accounts.identities.isEmpty {
                Text(accounts.loadError ?? "Connect a GitHub account to load repository details.")
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Button("Open GitHub Settings…", action: workspace.showGitHubSettings)
            } else {
                Picker("Account", selection: Binding(get: {
                    model.accountID(accounts.identities)
                }, set: model.selectAccount)) {
                    Text("Choose an account").tag(nil as Int64?)
                    ForEach(accounts.identities, id: \.id) { identity in
                        Text(identity.login).tag(Optional(identity.id))
                    }
                }
                if model.requestRevision == accounts.revision {
                    repositoryDetails
                }
            }
        }
    }

    @ViewBuilder private var repositoryDetails: some View {
        if model.loading {
            ProgressView("Loading repository details…")
        } else if let failure = model.failure {
            Text(failure).foregroundStyle(IDEAppearance.ColorToken.muted)
            Button("Open GitHub Settings…", action: workspace.showGitHubSettings)
        } else if let metadata = model.metadata {
            LabeledContent("Name", value: metadata.fullName)
            LabeledContent("Default branch", value: metadata.defaultBranch)
            LabeledContent("Visibility", value: metadata.visibility.capitalized)
            if metadata.archived { Label("Archived", systemImage: "archivebox") }
        }
    }
}
