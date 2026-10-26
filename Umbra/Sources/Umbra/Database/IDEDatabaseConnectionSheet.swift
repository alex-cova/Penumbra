import DatabaseKit
import SwiftUI

struct IDEDatabaseConnectionSheet: View {
    @Bindable var editor: IDEDatabaseConnectionEditor
    var support: IDEDatabaseSupport
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(editor.existingID == nil ? "New Data Source" : "Edit Data Source")
                .font(IDEAppearance.Typography.titlebarTitle)
                .padding(.bottom, 12)

            Form {
                LabeledContent("URL") {
                    HStack {
                        TextField("mysql://user:password@host:3306/db", text: $editor.urlText)
                            .textFieldStyle(.roundedBorder)
                        Button("Apply") { editor.applyURL() }
                    }
                }
                TextField("Name", text: $editor.name)
                Picker("Engine", selection: $editor.engine) {
                    ForEach(DatabaseEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                TextField("Host", text: $editor.host)
                TextField("Port", value: $editor.port, format: .number)
                TextField("User", text: $editor.username)
                SecureField("Password", text: $editor.password)
                TextField("Database", text: $editor.database)
                Toggle("Use TLS", isOn: $editor.useTLS)
                Toggle("Read Only", isOn: $editor.readOnly)
                if editor.engine == .mongo {
                    Toggle("SRV (mongodb+srv)", isOn: $editor.useSRV)
                    TextField("Auth database", text: $editor.authSource)
                    TextField("Replica set", text: $editor.replicaSet)
                    Toggle("Direct connection", isOn: $editor.directConnection)
                        .disabled(editor.useSRV || !editor.replicaSet.isEmpty)
                }
            }
            .formStyle(.grouped)

            Text(DatabaseURL.redacted(editor.connection(), password: editor.password))
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .textSelection(.enabled)
                .lineLimit(2)
                .padding(.top, 4)

            if let status = editor.status {
                Text(status)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(
                        status == "Connected." ? IDEAppearance.ColorToken.gitAdded : IDEAppearance.ColorToken.error
                    )
                    .padding(.top, 6)
            }

            HStack {
                Button("Test Connection") { Task { await support.testEditor() } }
                    .disabled(editor.isTesting)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { support.saveEditor() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(editor.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: editor.engine) { _, engine in
            if editor.portFollowsDefault {
                editor.port = engine.defaultPort
            }
        }
        .onChange(of: editor.port) { _, port in
            editor.portFollowsDefault = port == editor.engine.defaultPort
        }
        .onChange(of: editor.useSRV) { _, useSRV in
            if useSRV {
                editor.useTLS = true
                editor.directConnection = false
            }
        }
    }
}
