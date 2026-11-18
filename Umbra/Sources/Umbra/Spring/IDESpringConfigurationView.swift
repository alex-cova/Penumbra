import SpringIntelligence
import SwiftUI

/// Configuration: the application's configuration classes, active profiles, property files and their problems, imports and
/// conditional configuration. Everything opens its source.
struct IDESpringConfigurationView: View {
    let store: IDESpringStore
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        if let snapshot = store.snapshot, let data = store.currentContext {
            let config = snapshot.config
            List {
                Section("Active profiles") {
                    Text(config.activeProfiles.isEmpty ? (config.profilesAssumed ? "None known: profile-specific beans and properties are treated as conditional" : "none") : config.activeProfiles.joined(separator: ", "))
                        .font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted)
                    if !config.knownProfiles.isEmpty {
                        Text("Known: " + config.knownProfiles.sorted().joined(separator: ", "))
                            .font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted)
                    }
                }
                Section("Configuration classes") {
                    let configs = data.context.model.beans.filter { $0.stereotypes.contains(.configuration) }
                    if configs.isEmpty { none("None registered.") }
                    ForEach(configs, id: \.id) { bean in
                        Button { workspace.openSpringLocation(bean.location, title: bean.name) } label: {
                            Label(bean.name, systemImage: "gearshape").font(IDEAppearance.Typography.body)
                        }.buttonStyle(.plain)
                    }
                }
                Section("Property sources") {
                    if config.files.isEmpty { none("No application.properties or application.yml found.") }
                    ForEach(config.files, id: \.url) { file in
                        let problems = snapshot.configDiagnostics[file.url] ?? []
                        Button { workspace.openSpringConfigFile(file.url) } label: {
                            HStack {
                                Image(systemName: "doc.text").accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(file.url.lastPathComponent).font(IDEAppearance.Typography.body)
                                    Text("\(file.entries.count) properties" + (file.fileProfile.map { " · profile \($0)" } ?? "")
                                         + (problems.isEmpty ? "" : " · \(problems.count) problem\(problems.count == 1 ? "" : "s")"))
                                        .font(IDEAppearance.Typography.caption).foregroundStyle(problems.isEmpty ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.error)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                }
                Section("Imports and scanning") {
                    let links = data.context.model.configurationLinks
                    if links.isEmpty { none("No @Import, @ComponentScan or @ImportResource found.") }
                    ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                        Button { workspace.openSpringLocation(link.location, title: link.from) } label: {
                            Text(describe(link)).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.foreground).multilineTextAlignment(.leading)
                        }.buttonStyle(.plain)
                    }
                    Button("Show Application Context Graph") { workspace.openSpringContextGraph(contextID: data.id) }.controlSize(.small)
                }
                Section("Conditional configuration") {
                    let conditional = data.context.model.beans.filter { $0.certainty.isConditional || $0.certainty.isInactive }
                    if conditional.isEmpty { none("Every bean is registered unconditionally.") }
                    ForEach(conditional, id: \.id) { bean in
                        Button { workspace.openSpringLocation(bean.location, title: bean.name) } label: {
                            VStack(alignment: .leading) {
                                Text(bean.name).font(IDEAppearance.Typography.body)
                                Text(reasons(bean.certainty)).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                Section("Configuration problems") {
                    let all = snapshot.configDiagnostics.flatMap { url, list in list.map { (url, $0) } }
                    if all.isEmpty { none("No problems in the property files.") }
                    ForEach(Array(all.prefix(200).enumerated()), id: \.offset) { _, item in
                        Button { workspace.openSpringLocation(item.1.location, title: item.1.code) } label: {
                            Text("\(item.0.lastPathComponent): \(item.1.message)").font(IDEAppearance.Typography.caption)
                                .foregroundStyle(item.1.severity == .error ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.foreground)
                                .multilineTextAlignment(.leading)
                        }.buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)
        } else {
            IDEEmptyState(symbol: "gearshape", title: "No configuration loaded")
        }
    }

    private func describe(_ link: SpringConfigurationLink) -> String {
        let from = link.from.split(separator: ".").last.map(String.init) ?? link.from
        switch link.kind {
        case .scan(let package): return "\(from) scans \(package)"
        case .importClass(let target, let resolved): return "\(from) imports \(target)" + (resolved ? "" : " (not readable here)")
        case .importResource(let locations): return "\(from) imports resources \(locations.joined(separator: ", ")) (not read)"
        }
    }

    private func reasons(_ c: SpringCertainty) -> String {
        switch c {
        case .certain: ""
        case .conditional(let r), .inactive(let r): r.joined(separator: "; ")
        }
    }

    private func none(_ text: String) -> some View { Text(text).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted) }
}
