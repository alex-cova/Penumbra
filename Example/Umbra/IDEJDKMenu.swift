import AppKit
import JavaIntelligence
import SwiftUI

extension IDEWorkspace {
    /// The JDK picker shows for a Java file or a Gradle project.
    var showsJDKPicker: Bool {
        !showsWelcome && (statusLanguage == "java" || javaSupport.isGradleProject)
    }

    /// The Java menu-bar menu exists under the same condition as the JDK picker.
    var showsJavaMenu: Bool { showsJDKPicker }

    /// The HTTP menu-bar menu exists while an `.http` file is the selected tab.
    var showsHTTPMenu: Bool { statusLanguage == "http" }

    /// Asks for a JDK folder (a home, a `.jdk` bundle or a home's `bin`), adds it to the list and
    /// hands it to `completion`. A folder that isn't a JDK is reported instead.
    func addJDKFromPanel(completion: ((JDKInstallation) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Choose a JDK"
        panel.message = "Choose a JDK home folder or a .jdk bundle."
        panel.prompt = "Add JDK"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines")
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            switch self.javaSupport.jdk.addJDK(at: url) {
            case .success(let installation):
                completion?(installation)
            case .failure(let error):
                self.notifications.post(
                    "Couldn't add JDK", detail: "\(url.path): \(error.localizedDescription)", severity: .error
                )
            }
        }
    }
}

/// The menu behind the status bar item and the Java menu: the JDKs to choose from for the open
/// project, Automatic, a folder picker and the default for every project.
struct IDEJDKMenuContent: View {
    @Environment(IDEWorkspace.self) private var workspace
    private var jdk: IDEJDKSelection { workspace.javaSupport.jdk }

    var body: some View {
        if jdk.detected.isEmpty {
            Text("No JDK found")
        } else {
            Section("This Project") {
                ForEach(jdk.detected, id: \.home) { installation in
                    Toggle(isOn: projectBinding(installation)) {
                        Text(title(of: installation))
                    }
                }
                Toggle(isOn: automaticBinding) {
                    Text(automaticTitle)
                }
            }
            if let current = jdk.current {
                Section("Default for All Projects") {
                    if jdk.selection.global == nil {
                        Text("Automatic")
                    } else if let installation = jdk.detected.first(where: jdk.isDefault) {
                        Text(installation.displayName)
                    }
                    Button("Use \(current.installation.displayName) as Default") {
                        jdk.chooseAsDefault(current.installation)
                    }
                    .disabled(jdk.isDefault(current.installation))
                    Button("Use Automatic as Default") {
                        jdk.chooseAsDefault(nil)
                    }
                    .disabled(jdk.selection.global == nil)
                }
            }
        }
        Divider()
        Button("Choose JDK Folder…") {
            workspace.addJDKFromPanel { installation in
                jdk.chooseForProject(installation)
            }
        }
        Button("Rescan for JDKs") {
            Task { await jdk.refreshDetected() }
        }
        if let current = jdk.current {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([current.installation.home])
            }
        }
    }

    private func title(of installation: JDKInstallation) -> String {
        installation.isFullJDK ? installation.displayName : "\(installation.displayName) (JRE only)"
    }

    private var automaticTitle: String {
        if jdk.current?.source == .automatic, let current = jdk.current {
            return "Automatic (\(current.installation.displayName))"
        }
        return "Automatic"
    }

    private func projectBinding(_ installation: JDKInstallation) -> Binding<Bool> {
        Binding {
            jdk.current?.source == .project && jdk.isProjectChoice(installation)
        } set: { isOn in
            if isOn { jdk.chooseForProject(installation) }
        }
    }

    private var automaticBinding: Binding<Bool> {
        Binding {
            jdk.selection.project == nil
        } set: { isOn in
            if isOn { jdk.useAutomatic() }
        }
    }
}

/// The status bar item: `JDK 21` with a warning glyph when the JDK doesn't fit the project.
struct IDEJDKStatusItem: View {
    @Environment(IDEWorkspace.self) private var workspace
    private var jdk: IDEJDKSelection { workspace.javaSupport.jdk }

    var body: some View {
        let level = workspace.javaSupport.gradleModel?.maxLanguageLevel
        let warning = jdk.warning(maxLanguageLevel: level)
        Menu {
            IDEJDKMenuContent()
        } label: {
            HStack(spacing: 3) {
                if warning != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(IDEAppearance.ColorToken.gitModified)
                }
                Text(jdk.statusTitle ?? "No JDK")
            }
            .font(IDEAppearance.Typography.monoSmall)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(jdk.summary(maxLanguageLevel: level))
        .accessibilityLabel("Project JDK")
        .accessibilityValue(jdk.statusTitle ?? "None")
        .task { await jdk.refreshDetected() }
    }
}
