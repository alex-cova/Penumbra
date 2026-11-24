import SwiftUI

struct IDEGitHubSettingsView: View {
    let accounts: IDEGitHubAccounts

    @State private var signIn: SignIn?
    @State private var remove: GitHubIdentity?
    @State private var removing = false
    @State private var failure: String?

    private struct SignIn: Identifiable {
        let id = UUID()
        var identity: GitHubIdentity?
    }

    var body: some View {
        IDESettingsSection("Accounts") {
            if accounts.service == nil {
                Text("GitHub sign-in requires an Umbra build configured with a GitHub App.")
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else {
                if accounts.identities.isEmpty {
                    Text("No GitHub accounts connected.")
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                ForEach(accounts.identities, id: \.id) { identity in
                    HStack {
                        Label(identity.login, systemImage: "person.crop.circle")
                        Spacer()
                        Menu("Account actions for \(identity.login)", systemImage: "ellipsis.circle") {
                            Button("Sign In Again…") { signIn = SignIn(identity: identity) }
                            Button("Sign Out…", role: .destructive) { remove = identity }
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("github-account-actions-\(identity.id)")
                    }
                }
                Button("Add GitHub Account…", systemImage: "plus") { signIn = SignIn() }
                    .accessibilityIdentifier("github-add-account")
                if let url = accounts.installationURL {
                    Link("Manage Repository Access on GitHub", destination: url)
                }
                if let error = failure ?? accounts.loadError {
                    Text(error).foregroundStyle(IDEAppearance.ColorToken.foreground)
                }
            }
        }
        .disabled(removing)
        .task { await accounts.reload() }
        .sheet(item: $signIn) { flow in
            IDEGitHubSignInView(accounts: accounts, identity: flow.identity)
        }
        .alert("Sign Out of GitHub?", isPresented: Binding(
            get: { remove != nil }, set: { if !$0 { remove = nil } }
        ), presenting: remove) { identity in
            Button("Sign Out", role: .destructive) {
                removing = true
                Task {
                    defer { removing = false }
                    do {
                        try await accounts.signOut(identity.id)
                        failure = nil
                    } catch {
                        failure = IDEGitHubMessage.describe(error)
                    }
                }
            }
        } message: { identity in
            Text("Remove \(identity.login) from Umbra on this Mac.")
        }
    }
}
