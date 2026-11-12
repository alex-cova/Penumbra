import SwiftUI

/// One agent's environment secrets. The value field is never shown again after it is saved.
struct IDEACPSecretEditor: View {
    let settings: IDEAgentSettings
    let agentID: UUID
    @State private var key = ""
    @State private var value = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xxs) {
            let names = settings.acpEnvKeyNames(for: agentID)
            if !names.isEmpty {
                Text("Keychain: \(names.joined(separator: ", "))")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            HStack {
                TextField("ENV name", text: $key)
                SecureField("Value", text: $value)
                Button("Save to Keychain") { save() }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || value.isEmpty)
            }
            if let saveError {
                Text(saveError)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
            }
        }
    }

    private func save() {
        let name = key.trimmingCharacters(in: .whitespaces)
        do {
            try settings.saveACPEnvValue(value, agentID: agentID, key: name)
            value = ""
            key = ""
            saveError = nil
        } catch {
            saveError = "Could not save that value to the Keychain."
        }
    }
}
