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
        Toggle("Production Database", isOn: $editor.isProduction)
            .help("Ask for confirmation before running SQL that may change this file.")
        TextField("Busy Timeout (ms)", value: $editor.sqliteBusyTimeoutMilliseconds, format: .number)
            .help("How long SQLite waits for another connection to release a lock.")
        if editor.createsNewFile {
            Text("The file does not exist yet. It is created, empty, when you save.")
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }

    @ViewBuilder
    private var networkFields: some View {
        Section("Authentication") {
            TextField("User", text: $editor.username)
            SecureField("Password", text: $editor.password)
            if editor.engine == .mongo { TextField("Authentication Database", text: $editor.authSource) }
        }
        Section("Network") {
            TextField("Host", text: $editor.host)
            if !editor.useSRV || editor.engine != .mongo {
                TextField("Port", value: $editor.port, format: .number)
            }
            if editor.engine == .mongo {
                Toggle("Discover Servers via DNS (SRV)", isOn: $editor.useSRV)
            }
        }
        Section("TLS") {
            if editor.engine == .postgres {
                Picker("Mode", selection: $editor.tlsChoice) {
                    Text("Off").tag(IDEDatabaseConnectionEditor.TLSChoice.off)
                    Text("Prefer").tag(IDEDatabaseConnectionEditor.TLSChoice.prefer)
                    Text("Require").tag(IDEDatabaseConnectionEditor.TLSChoice.require)
                }
                Text(tlsExplanation)
                    .font(.caption)
                    .foregroundStyle(editor.tlsChoice == .prefer ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
            } else {
                Toggle("Use TLS", isOn: $editor.useTLS)
            }
        }
        Section("Advanced") {
            LabeledContent("Connection URL") {
                HStack {
                    SecureField("Paste a connection URL", text: $editor.urlText)
                        .textFieldStyle(.roundedBorder)
                    Button("Apply") { editor.applyURL() }
                }
            }
            if editor.engine == .mongo {
                TextField("Replica Set", text: $editor.replicaSet)
                Toggle("Direct Connection", isOn: $editor.directConnection)
                    .disabled(editor.useSRV || !editor.replicaSet.isEmpty)
            }
        }
        Section("Session") {
            TextField("Database", text: $editor.database)
            Toggle("Read Only", isOn: $editor.readOnly)
            Toggle(isOn: $editor.isProduction) {
                Label("Production", systemImage: "exclamationmark.triangle")
            }
            if editor.isProduction, editor.engine != .mongo {
                Text("Umbra asks before running SQL that may change this source.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a SQLite database file"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            editor.database = url.path
            editor.createsNewFile = false
            if editor.name.isEmpty { editor.name = url.lastPathComponent }
        }
    }

    private func chooseNewFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "database.sqlite"
        panel.message = "Choose where to create the new SQLite database"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            editor.database = url.path
            // Saving will open an existing file as-is.
            editor.createsNewFile = !FileManager.default.fileExists(atPath: url.path)
            if editor.name.isEmpty { editor.name = url.lastPathComponent }
        }
    }

    private var isValid: Bool {
        let source = editor.connection()
        if source.engine == .sqlite {
            return !source.database.isEmpty && (0...Int(Int32.max)).contains(editor.sqliteBusyTimeoutMilliseconds)
        }
        return !source.host.isEmpty && ((source.engine == .mongo && source.useSRV) || (1...65_535).contains(source.port))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(editor.existingID == nil ? "New Data Source" : "Edit Data Source")
                .font(IDEAppearance.Typography.titlebarTitle)
                .padding(.bottom, 12)

            Form {
                Section("General") {
                    TextField("Name", text: $editor.name)
                    TextField("Group", text: $editor.group, prompt: Text("Ungrouped"))
                    Picker("Engine", selection: $editor.engine) {
                        ForEach(DatabaseEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                }
                if editor.engine == .sqlite {
                    Section("SQLite File") { sqliteFields }
                } else {
                    networkFields
                }
            }
            .formStyle(.grouped)
            .disabled(editor.isTesting)

            Text(DatabaseURL.redacted(editor.connection(), password: editor.password))
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .textSelection(.enabled)
                .lineLimit(2)
                .padding(.top, 4)

            if let status = editor.status {
                Label(status, systemImage: editor.testSucceeded ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(editor.testSucceeded ? IDEAppearance.ColorToken.gitAdded : IDEAppearance.ColorToken.error)
                    .textSelection(.enabled)
                    .padding(.top, 6)
            }

            HStack {
                Button("Test Connection") { Task { await support.testEditor() } }
                    .disabled(editor.isTesting || !isValid)
                if editor.isTesting { ProgressView().controlSize(.small).accessibilityLabel("Testing Connection") }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { support.saveEditor() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(editor.isTesting || !isValid)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 620, height: 590)
        .onChange(of: editor.connection()) { _, _ in
            if editor.testSucceeded { editor.status = nil }
            editor.testSucceeded = false
        }
        .onChange(of: editor.password) { _, _ in
            if editor.testSucceeded { editor.status = nil }
            editor.testSucceeded = false
        }
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
