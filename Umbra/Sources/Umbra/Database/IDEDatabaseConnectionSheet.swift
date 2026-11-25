import AppKit
import DatabaseKit
import SwiftUI

struct IDEDatabaseConnectionSheet: View {
    @Bindable var editor: IDEDatabaseConnectionEditor
    var support: IDEDatabaseSupport
    var onCancel: () -> Void

    private var tlsExplanation: String {
        switch editor.tlsChoice {
        case .off:
            "No encryption. The password and data cross the network in plain text."
        case .prefer:
            "Uses TLS if the server offers it, otherwise connects in plain text. Anyone between you and the server can force the plain-text fallback."
        case .require:
            "Refuses to connect without TLS, and checks the server certificate and host name."
        }
    }

    /// SQLite is a file: no host, port, user, password or TLS, so none of those are shown.
    @ViewBuilder
    private var sqliteFields: some View {
        if editor.database != ":memory:" {
            LabeledContent("File") {
                HStack {
                    TextField("/path/to/database.sqlite", text: $editor.database)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: editor.database) { _, _ in editor.createsNewFile = false }
                    Button("Choose…") { chooseFile() }
                    Button("New…") { chooseNewFile() }
                }
            }
        }
        Toggle("In-memory database (discarded when disconnected)", isOn: Binding(
            get: { editor.database == ":memory:" },
            set: { editor.database = $0 ? ":memory:" : ""; editor.createsNewFile = false }
        ))
        Toggle("Read Only", isOn: $editor.readOnly)
        if editor.createsNewFile {
            Text("The file does not exist yet. It is created, empty, when you save.")
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }

    @ViewBuilder
    private var networkFields: some View {
        TextField("Host", text: $editor.host)
        TextField("Port", value: $editor.port, format: .number)
        TextField("User", text: $editor.username)
        SecureField("Password", text: $editor.password)
        TextField("Database", text: $editor.database)
        if editor.engine == .postgres {
            Picker("TLS", selection: $editor.tlsChoice) {
                Text("Off").tag(IDEDatabaseConnectionEditor.TLSChoice.off)
                Text("Prefer").tag(IDEDatabaseConnectionEditor.TLSChoice.prefer)
                Text("Require").tag(IDEDatabaseConnectionEditor.TLSChoice.require)
            }
            Text(tlsExplanation)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(
                    editor.tlsChoice == .prefer
                        ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted
                )
        } else {
            Toggle("Use TLS", isOn: $editor.useTLS)
        }
        Toggle("Read Only", isOn: $editor.readOnly)
        if editor.engine == .mongo {
            Toggle("SRV (mongodb+srv)", isOn: $editor.useSRV)
            TextField("Auth database", text: $editor.authSource)
            TextField("Replica set", text: $editor.replicaSet)
            Toggle("Direct connection", isOn: $editor.directConnection)
                .disabled(editor.useSRV || !editor.replicaSet.isEmpty)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a SQLite database file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editor.database = url.path
        editor.createsNewFile = false
        if editor.name.isEmpty { editor.name = url.lastPathComponent }
    }

    private func chooseNewFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "database.sqlite"
        panel.message = "Choose where to create the new SQLite database"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editor.database = url.path
        // The save panel already asked about replacing an existing file; a file that is there is
        // simply opened, never overwritten.
        editor.createsNewFile = !FileManager.default.fileExists(atPath: url.path)
        if editor.name.isEmpty { editor.name = url.lastPathComponent }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(editor.existingID == nil ? "New Data Source" : "Edit Data Source")
                .font(IDEAppearance.Typography.titlebarTitle)
                .padding(.bottom, 12)

            Form {
                if editor.engine != .sqlite {
                    LabeledContent("URL") {
                        HStack {
                            TextField("mysql://user:password@host:3306/db", text: $editor.urlText)
                                .textFieldStyle(.roundedBorder)
                            Button("Apply") { editor.applyURL() }
                        }
                    }
                }
                TextField("Name", text: $editor.name)
                Picker("Engine", selection: $editor.engine) {
                    ForEach(DatabaseEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                if editor.engine == .sqlite {
                    sqliteFields
                } else {
                    networkFields
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
                    .disabled(
                        editor.engine == .sqlite
                            ? editor.database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            : editor.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
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
