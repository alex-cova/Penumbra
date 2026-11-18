import SpringIntelligence
import SwiftUI

/// The inspector for one bean: what it is, where it is declared, what it needs and who needs it. Every location opens its source.
struct IDESpringBeanInspector: View {
    let inspection: SpringBeanInspection
    let store: IDESpringStore
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let bean = inspection.bean
        ScrollView {
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                header(bean)
                actions(bean)
                facts(bean)
                if !inspection.conditions.isEmpty { conditions }
                if !inspection.diagnostics.isEmpty { diagnostics }
                section("Dependencies (\(inspection.dependencies.count))") { dependencies }
                section("Consumers (\(inspection.consumers.count))") { consumers }
            }
            .padding(IDEAppearance.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(IDEAppearance.ColorToken.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector for bean \(bean.name)")
    }

    private func header(_ bean: SpringBean) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xxs) {
            Text(bean.name).font(IDEAppearance.Typography.body.weight(.semibold)).foregroundStyle(IDEAppearance.ColorToken.foreground)
            Text(bean.type.name).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted).textSelection(.enabled)
        }
    }

    private func actions(_ bean: SpringBean) -> some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Button("Go to Definition") { workspace.openSpringLocation(bean.location, title: bean.name) }
            Button("Find Usages") { workspace.findSpringBeanUsages(bean.id, in: store) }
            Menu("Graph") {
                Button("Show Dependencies") { workspace.openSpringBeanGraph(focus: bean.id, direction: .outgoing, store: store) }
                Button("Show Consumers") { workspace.openSpringBeanGraph(focus: bean.id, direction: .incoming, store: store) }
                Button("Show in Dependency Graph") { workspace.openSpringBeanGraph(focus: bean.id, direction: .both, store: store) }
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .controlSize(.small)
    }

    private func facts(_ bean: SpringBean) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xxs) {
            fact("Origin", inspection.origin)
            fact("Declared in", "\(bean.location.url.lastPathComponent)")
            fact("Configuration", inspection.configurationClass)
            fact("Scope", bean.scope + (bean.isLazy ? " · lazy" : ""))
            if !bean.qualifiers.isEmpty { fact("Qualifiers", bean.qualifiers.joined(separator: ", ")) }
            if bean.isPrimary || bean.isFallback { fact("Selection", [bean.isPrimary ? "@Primary" : nil, bean.isFallback ? "@Fallback" : nil].compactMap { $0 }.joined(separator: ", ")) }
            if !bean.aliases.isEmpty { fact("Aliases", bean.aliases.joined(separator: ", ")) }
            fact("Registration", certaintyText(bean.certainty))
        }
    }

    private func certaintyText(_ c: SpringCertainty) -> String {
        switch c {
        case .certain: "Registered (as far as static analysis can tell)"
        case .conditional: "Conditional"
        case .inactive: "Inactive under the analysis profiles"
        }
    }

    private var conditions: some View {
        section("Conditions") {
            ForEach(inspection.conditions, id: \.self) { reason in
                Label(reason, systemImage: "questionmark.diamond").font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
    }

    private var diagnostics: some View {
        section("Problems") {
            ForEach(Array(inspection.diagnostics.enumerated()), id: \.offset) { _, d in
                Button { workspace.openSpringLocation(d.location, title: d.code) } label: {
                    Label(d.message, systemImage: d.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(d.severity == .error ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var dependencies: some View {
        if inspection.dependencies.isEmpty { none("Injects nothing.") }
        ForEach(Array(inspection.dependencies.enumerated()), id: \.offset) { _, dep in
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.hairline) {
                Button { workspace.openSpringLocation(dep.point.location, title: dep.point.name) } label: {
                    HStack {
                        Image(systemName: statusSymbol(dep.status)).foregroundStyle(statusColor(dep.status)).accessibilityHidden(true)
                        Text("\(dep.point.name): \(dep.requiredType)").font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.foreground).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(dep.point.name), \(dep.requiredType), \(statusText(dep.status))")
                Text(statusText(dep.status)).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted).padding(.leading, 18)
                ForEach(dep.targets, id: \.id) { target in
                    Button { workspace.openSpringLocation(target.location, title: target.name) } label: {
                        Text("→ \(target.name)").font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.accent)
                    }
                    .buttonStyle(.plain).padding(.leading, 18)
                }
            }
        }
    }

    @ViewBuilder private var consumers: some View {
        if inspection.consumers.isEmpty { none("Nothing in this application injects it.") }
        ForEach(Array(inspection.consumers.enumerated()), id: \.offset) { _, c in
            Button { workspace.openSpringLocation(c.point.location, title: c.point.name) } label: {
                HStack {
                    Image(systemName: c.isCertain ? "arrow.down.right.circle.fill" : "arrow.down.right.circle").foregroundStyle(IDEAppearance.ColorToken.accent).accessibilityHidden(true)
                    Text("\(c.ownerName).\(c.point.name)" + (c.isCertain ? "" : " (one of several candidates)"))
                        .font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.foreground).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func statusSymbol(_ s: SpringBeanInspection.Dependency.Status) -> String {
        switch s {
        case .verified: "checkmark.circle.fill"
        case .conditional: "questionmark.circle"
        case .ambiguous: "exclamationmark.triangle.fill"
        case .unresolved: "xmark.circle.fill"
        }
    }

    private func statusColor(_ s: SpringBeanInspection.Dependency.Status) -> Color {
        switch s {
        case .verified: IDEAppearance.ColorToken.gitAdded
        case .conditional: IDEAppearance.ColorToken.muted
        case .ambiguous: IDEAppearance.ColorToken.gitModified
        case .unresolved: IDEAppearance.ColorToken.error
        }
    }

    private func statusText(_ s: SpringBeanInspection.Dependency.Status) -> String {
        switch s {
        case .verified: "resolved"
        case .conditional: "depends on a condition or one of several candidates"
        case .ambiguous: "ambiguous: several candidates, nothing selects one"
        case .unresolved(let reason): "unresolved: \(reason)"
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: IDEAppearance.Spacing.xs) {
            Text(label).foregroundStyle(IDEAppearance.ColorToken.muted).frame(width: 84, alignment: .leading)
            Text(value).foregroundStyle(IDEAppearance.ColorToken.foreground).textSelection(.enabled)
        }
        .font(IDEAppearance.Typography.caption)
    }

    private func none(_ text: String) -> some View {
        Text(text).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text(title).font(IDEAppearance.Typography.caption.weight(.semibold)).foregroundStyle(IDEAppearance.ColorToken.muted)
            content()
        }
    }
}
