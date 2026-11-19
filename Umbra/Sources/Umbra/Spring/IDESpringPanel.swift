import SpringIntelligence
import SwiftUI

/// The sidebar's Spring tab: an application picker, a section picker, and the section. The panel only presents the store; the
/// model is built off the main actor and kept until the index reports a Spring-relevant change.
struct IDESpringPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var needsRefreshOnAppear = true

    var body: some View {
        let store = workspace.springStore
        VStack(spacing: 0) {
            header(store)
            Divider()
            content(store)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IDEAppearance.ColorToken.panel)
        .onAppear { workspace.refreshSpring() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spring")
    }

    private func header(_ store: IDESpringStore) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            if let snapshot = store.snapshot, snapshot.contexts.count > 1 {
                Picker("Application", selection: Binding(get: { store.currentContext?.id ?? "" }, set: { store.selectedContextID = $0 })) {
                    ForEach(snapshot.contexts) { Text($0.context.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Spring application")
            }
            Picker("Section", selection: Bindable(store).section) {
                ForEach(IDESpringSection.allCases) { section in
                    Image(systemName: section.symbol).tag(section).help(section.title).accessibilityLabel(section.title)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            Text(store.section.title)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .padding(IDEAppearance.Spacing.sm)
    }

    @ViewBuilder
    private func content(_ store: IDESpringStore) -> some View {
        switch store.phase {
        case .idle where store.snapshot == nil, .loading where store.snapshot == nil:
            IDEEmptyState(title: "Analysing Spring beans…", isLoading: true)
        case .notSpring:
            IDEEmptyState(
                symbol: "leaf", title: "No Spring project",
                message: "Spring appears here once a Gradle or Maven module has spring-context or Spring Boot on its classpath.")
        case .failed(let message):
            IDEEmptyState(symbol: "exclamationmark.triangle", title: "Spring analysis failed", message: message,
                          actionTitle: "Try Again") { workspace.refreshSpring() }
        default:
            if store.snapshot != nil {
                switch store.section {
                case .applications: IDESpringApplicationsView(store: store)
                case .beans: IDESpringBeansView(store: store)
                case .endpoints: IDESpringEndpointsView(store: store)
                case .configuration: IDESpringConfigurationView(store: store)
                case .runtime: IDESpringRuntimeView()
                }
            } else {
                IDEEmptyState(title: "Analysing Spring beans…", isLoading: true)
            }
        }
    }
}

// MARK: - Applications

struct IDESpringApplicationsView: View {
    let store: IDESpringStore
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let snapshot = store.snapshot
        List(selection: Bindable(store).selectedContextID) {
            ForEach(snapshot?.contexts ?? []) { data in
                IDESpringApplicationRow(data: data, snapshot: snapshot, profiles: snapshot?.config.activeProfiles ?? [], assumed: snapshot?.config.profilesAssumed ?? true)
                    .tag(data.id as String?)
                    .contextMenu {
                        if let entry = data.context.entry {
                            Button("Go to Application Class") { workspace.openSpringLocation(entry.location, title: data.context.name) }
                        }
                        Button("Show Application Context Graph") { workspace.openSpringContextGraph(contextID: data.id) }
                    }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if snapshot?.contexts.isEmpty == true { IDEEmptyState(symbol: "app.badge", title: "No applications found") }
        }
    }
}

private struct IDESpringApplicationRow: View {
    let data: IDESpringSnapshot.ContextData
    let snapshot: IDESpringSnapshot?
    let profiles: [String]
    let assumed: Bool

    var body: some View {
        let context = data.context
        let module = snapshot?.modules.first { $0.projectPath == context.moduleID }
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xxs) {
            HStack {
                Image(systemName: context.entry == nil ? "square.stack.3d.up" : "bolt.fill").foregroundStyle(IDEAppearance.ColorToken.accent)
                Text(context.name).font(IDEAppearance.Typography.body).foregroundStyle(IDEAppearance.ColorToken.foreground)
            }
            detail("Entry point", context.entry?.typeName ?? "none (all sources analysed together)")
            if let id = context.moduleID { detail("Module", id) }
            if let boot = module?.bootVersion { detail("Spring Boot", boot) }
            else if let framework = module?.frameworkVersion { detail("Spring Framework", framework) }
            detail("Beans", "\(context.model.beans.count) · \(context.model.injectionPoints.count) injection points")
            detail("Scans", context.scanPackages.isEmpty ? "all packages" : context.scanPackages.joined(separator: ", "))
            detail("Profiles", profiles.isEmpty ? (assumed ? "none known (profile beans are conditional)" : "none") : profiles.joined(separator: ", "))
            let problems = context.model.diagnostics.filter { $0.severity == .error }.count
            detail("Static analysis", problems == 0 ? "no errors" : "\(problems) error\(problems == 1 ? "" : "s")")
            if data.context.moduleIDs.count > 1 { detail("Modules in scope", data.context.moduleIDs.joined(separator: ", ")) }
        }
        .padding(.vertical, IDEAppearance.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: IDEAppearance.Spacing.xs) {
            Text(label).foregroundStyle(IDEAppearance.ColorToken.muted).frame(width: 96, alignment: .leading)
            Text(value).foregroundStyle(IDEAppearance.ColorToken.foreground).lineLimit(2)
        }
        .font(IDEAppearance.Typography.caption)
    }
}

// MARK: - Runtime (honest placeholder)

struct IDESpringRuntimeView: View {
    var body: some View {
        IDEEmptyState(
            symbol: "waveform.path.ecg", title: "No runtime connection",
            message: "Runtime data (beans, mappings, health, conditions) will come from Spring Boot Actuator when that integration exists. Nothing here is simulated.")
    }
}
