import SpringIntelligence
import SwiftUI

/// Beans: a searchable, filterable list with the inspector for the selected bean beneath it.
struct IDESpringBeansView: View {
    let store: IDESpringStore
    @Environment(IDEWorkspace.self) private var workspace
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if let data = store.currentContext {
                let rows = store.rows
                VSplitView {
                    list(rows, data: data)
                        .frame(minHeight: 120)
                    inspector(data: data)
                        .frame(minHeight: 140)
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(IDEAppearance.ColorToken.muted).accessibilityHidden(true)
            TextField("Search beans", text: Bindable(store).filter.text)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search beans")
            Menu {
                filterMenu
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle\(isFiltering ? ".fill" : "")")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Filter beans")
            .accessibilityLabel("Filter beans")
        }
        .padding(IDEAppearance.Spacing.sm)
    }

    private var isFiltering: Bool {
        let f = store.filter
        return !f.stereotypes.isEmpty || !f.modules.isEmpty || f.conditional != .any || f.onlyProblems || !f.includeFactoryBeans
    }

    @ViewBuilder private var filterMenu: some View {
        let f = Bindable(store).filter
        Section("Kind") {
            ForEach([SpringStereotype.service, .repository, .controller, .restController, .configuration, .component], id: \.self) { kind in
                Toggle(kind.rawValue.capitalized, isOn: Binding(
                    get: { store.filter.stereotypes.contains(kind) },
                    set: { if $0 { store.filter.stereotypes.insert(kind) } else { store.filter.stereotypes.remove(kind) } }))
            }
            Toggle("@Bean methods", isOn: f.includeFactoryBeans)
        }
        Section("State") {
            Picker("Conditional", selection: f.conditional) {
                ForEach(SpringBeanFilter.ConditionalState.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Toggle("Only beans with problems", isOn: f.onlyProblems)
        }
        let modules = store.currentContext?.beans.modules ?? []
        if modules.count > 1 {
            Section("Module") {
                ForEach(modules, id: \.self) { module in
                    Toggle(module, isOn: Binding(
                        get: { store.filter.modules.contains(module) },
                        set: { if $0 { store.filter.modules.insert(module) } else { store.filter.modules.remove(module) } }))
                }
            }
        }
        Divider()
        Button("Reset Filters") { let text = store.filter.text; store.filter = SpringBeanFilter(); store.filter.text = text }
    }

    private func list(_ rows: [SpringBeanRow], data: IDESpringSnapshot.ContextData) -> some View {
        List(selection: Bindable(store).selectedBeanID) {
            ForEach(rows) { row in
                IDESpringBeanRowView(row: row)
                    .tag(row.id as SpringBeanID?)
                    .contextMenu { beanMenu(row.id) }
            }
        }
        .listStyle(.plain)
        .onKeyPress(.return) {
            guard let id = store.selectedBeanID else { return .ignored }
            workspace.openSpringBean(id, in: store)
            return .handled
        }
        .overlay {
            if rows.isEmpty {
                IDEEmptyState(symbol: "leaf", title: data.beans.rows.isEmpty ? "No beans registered" : "No matching beans",
                              message: data.beans.rows.isEmpty ? "This application's scan and imports reach no bean classes." : "Change the search text or filters.",
                              actionTitle: data.beans.rows.isEmpty ? nil : "Clear Filters") { store.filter = SpringBeanFilter() }
            }
        }
        .accessibilityLabel("Beans, \(rows.count) shown")
    }

    @ViewBuilder
    private func beanMenu(_ id: SpringBeanID) -> some View {
        Button("Go to Definition") { workspace.openSpringBean(id, in: store) }
        Button("Find Usages") { workspace.findSpringBeanUsages(id, in: store) }
        Divider()
        Button("Show Dependencies in Graph") { workspace.openSpringBeanGraph(focus: id, direction: .outgoing, store: store) }
        Button("Show Consumers in Graph") { workspace.openSpringBeanGraph(focus: id, direction: .incoming, store: store) }
        Button("Show in Dependency Graph") { workspace.openSpringBeanGraph(focus: id, direction: .both, store: store) }
    }

    @ViewBuilder
    private func inspector(data: IDESpringSnapshot.ContextData) -> some View {
        if let id = store.selectedBeanID, let inspection = store.inspection(for: id) {
            IDESpringBeanInspector(inspection: inspection, store: store)
        } else {
            IDEEmptyState(symbol: "sidebar.right", title: "Select a bean", message: "Its dependencies, consumers and conditions appear here.")
        }
    }
}

private struct IDESpringBeanRowView: View {
    let row: SpringBeanRow

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 14).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.hairline) {
                Text(row.name).font(IDEAppearance.Typography.body).foregroundStyle(IDEAppearance.ColorToken.foreground).lineLimit(1)
                Text(row.simpleType).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted).lineLimit(1)
            }
            Spacer(minLength: IDEAppearance.Spacing.xs)
            if row.isPrimary { badge("primary") }
            if row.certainty.isConditional { badge("conditional") }
            if row.certainty.isInactive { badge("inactive") }
            Text("\(row.dependencyCount)→ ←\(row.consumerCount)")
                .font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted)
                .help("\(row.dependencyCount) dependencies, \(row.consumerCount) consumers")
        }
        .opacity(row.certainty.isInactive ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name), \(row.kindLabel), \(row.simpleType), \(row.dependencyCount) dependencies, \(row.consumerCount) consumers")
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted)
            .padding(.horizontal, IDEAppearance.Spacing.xs)
            .background(IDEAppearance.ColorToken.controlHover, in: Capsule())
    }

    private var symbol: String {
        switch row.kindLabel {
        case "Application": "bolt.fill"
        case "RestController", "Controller", "ControllerAdvice": "network"
        case "Repository": "cylinder.split.1x2.fill"
        case "Configuration": "gearshape.fill"
        case "@Bean": "wrench.and.screwdriver.fill"
        default: "leaf.fill"
        }
    }

    private var tint: Color { row.certainty == .certain ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.muted }
}
