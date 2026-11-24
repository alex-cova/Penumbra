import AppKit
import SwiftUI

struct IDEGitHubSignInView: View {
    let accounts: IDEGitHubAccounts
    let identity: GitHubIdentity?

    @Environment(\.dismiss) private var dismiss
    @State private var challenge: GitHubDeviceAuthorization<ContinuousClock>.Challenge?
    @State private var failure: String?
    @State private var attempt = 0
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            Text(identity.map { "Sign In Again as \($0.login)" } ?? "Sign In to GitHub")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let failure {
                Text(failure)
            } else if let challenge {
                Text("Enter this code in your browser to authorize Umbra.")
                HStack {
                    Text(challenge.userCode)
                        .font(.title2.monospaced())
                        .textSelection(.enabled)
                        .accessibilityLabel("GitHub device code \(challenge.userCode)")
                    Button(copied ? "Copied" : "Copy Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(challenge.userCode, forType: .string)
                        copied = true
                    }
                }
                Label("Waiting for authorization", systemImage: "hourglass")
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else {
                ProgressView("Requesting a sign-in code…")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if failure != nil {
                    Button("Try Again") { attempt += 1 }
                        .keyboardShortcut(.defaultAction)
                } else if let challenge {
                    Link("Open GitHub", destination: challenge.verificationURL)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(width: 420)
        .task(id: attempt) { await signIn() }
    }

    private func signIn() async {
        guard let service = accounts.service else { return }
        challenge = nil
        failure = nil
        copied = false
        do {
            let flow = try await service.beginSignIn()
            try Task.checkCancellation()
            challenge = flow.challenge
            let verified = try await service.completeSignIn(flow, expectedUserID: identity?.id)
            await accounts.didSignIn(verified)
            if !Task.isCancelled { dismiss() }
        } catch {
            if !Task.isCancelled { failure = IDEGitHubMessage.describe(error) }
        }
    }
}
