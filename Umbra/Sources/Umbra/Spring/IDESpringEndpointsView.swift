import SpringIntelligence
import SwiftUI

/// Endpoints: a searchable list of the application's HTTP endpoints with the inspector for the selected one beneath it.
/// Everything shown comes from the static mapping index; nothing is asked of a running application.
struct IDESpringEndpointsView: View {
    let store: IDESpringStore
    @Environment(IDEWorkspace.self) private var workspace
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if let data = store.currentContext {
                let rows = store.endpointRows
                if data.endpoints.endpoints.isEmpty && !store.endpointScopeIsAll {
                    IDEEmptyState(
                        symbol: "network", title: "No endpoints found",
                        message: "This application registers no controller with request mappings. Functional routes (RouterFunctions) are not analysed.")
                } else {
                    VSplitView {
                        list(rows, data: data).frame(minHeight: 120)
                        inspector.frame(minHeight: 140)
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(IDEAppearance.ColorToken.muted).accessibilityHidden(true)
            TextField("Search endpoints", text: Bindable(store).endpointFilter.text)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search endpoints")
            Menu { filterMenu } label: { Image(systemName: "line.3.horizontal.decrease.circle\(isFiltering ? ".fill" : "")") }
                .menuStyle(.borderlessButton).fixedSize().help("Filter and sort endpoints").accessibilityLabel("Filter and sort endpoints")
        }
        .padding(IDEAppearance.Spacing.sm)
    }

    private var isFiltering: Bool {
        let f = store.endpointFilter
        return !f.methods.isEmpty || !f.modules.isEmpty || f.onlyProblems || !f.includeInactive || store.endpointScopeIsAll
    }

    @ViewBuilder private var filterMenu: some View {
        let f = Bindable(store).endpointFilter
        Section("Sort by") {
            Picker("Sort by", selection: f.sort) {
                ForEach(SpringEndpointFilter.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Group by controller", isOn: Bindable(store).groupEndpointsByController)
        }
        Section("HTTP method") {
            ForEach(["GET", "POST", "PUT", "PATCH", "DELETE", "ANY"], id: \.self) { method in
                Toggle(method, isOn: Binding(
                    get: { store.endpointFilter.methods.contains(method) },
                    set: { if $0 { store.endpointFilter.methods.insert(method) } else { store.endpointFilter.methods.remove(method) } }))
            }
        }
        let modules = store.currentContext?.endpoints.modules ?? []
        if modules.count > 1 {
            Section("Module") {
                ForEach(modules, id: \.self) { module in
                    Toggle(module, isOn: Binding(
                        get: { store.endpointFilter.modules.contains(module) },
                        set: { if $0 { store.endpointFilter.modules.insert(module) } else { store.endpointFilter.modules.remove(module) } }))
                }
            }
        }
        Section("State") {
            Toggle("Include inactive endpoints", isOn: f.includeInactive)
            Toggle("Only endpoints with problems", isOn: f.onlyProblems)
        }
        if (store.snapshot?.contexts.count ?? 0) > 1 {
            Section("Application") { Toggle("All applications", isOn: Bindable(store).endpointScopeIsAll) }
        }
        Divider()
        Button("Reset Filters") {
            let text = store.endpointFilter.text
            store.endpointFilter = SpringEndpointFilter(); store.endpointFilter.text = text; store.endpointScopeIsAll = false
        }
    }

    @ViewBuilder
    private func list(_ rows: [SpringEndpoint], data: IDESpringSnapshot.ContextData) -> some View {
        List(selection: Bindable(store).selectedEndpointID) {
            if store.groupEndpointsByController {
                ForEach(Dictionary(grouping: rows, by: \.controller).sorted { $0.key < $1.key }, id: \.key) { controller, group in
                    Section(controller.split(separator: ".").last.map(String.init) ?? controller) {
                        ForEach(group) { row($0) }
                    }
                }
            } else {
                ForEach(rows) { row($0) }
            }
        }
        .listStyle(.plain)
        .onKeyPress(.return) {
            workspace.openSelectedSpringEndpoint(in: store) ? .handled : .ignored
        }
        .overlay {
            if rows.isEmpty {
                IDEEmptyState(symbol: "network", title: "No matching endpoints", message: "Change the search text or filters.",
                              actionTitle: "Clear Filters") { store.endpointFilter = SpringEndpointFilter(); store.endpointScopeIsAll = false }
            }
        }
        .accessibilityLabel("Endpoints, \(rows.count) shown")
    }

    private func row(_ e: SpringEndpoint) -> some View {
        IDESpringEndpointRow(endpoint: e, showApplication: store.endpointScopeIsAll, hasProblems: store.hasProblems(e))
            .tag(e.id as SpringEndpointID?)
            .contextMenu { IDESpringEndpointActions(endpoint: e, store: store) }
    }

    @ViewBuilder private var inspector: some View {
        if let e = store.selectedEndpoint {
            IDESpringEndpointInspector(endpoint: e, store: store)
        } else {
            IDEEmptyState(symbol: "sidebar.right", title: "Select an endpoint", message: "Its mapping, parameters and response appear here.")
        }
    }
}

private struct IDESpringEndpointRow: View {
    let endpoint: SpringEndpoint
    let showApplication: Bool
    let hasProblems: Bool

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Text(endpoint.conditions.methods.isEmpty ? "ANY" : endpoint.conditions.methods.joined(separator: "/"))
                .font(IDEAppearance.Typography.caption.weight(.semibold).monospaced())
                .foregroundStyle(methodColor)
                .frame(width: 52, alignment: .leading)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.hairline) {
                Text(endpoint.route).font(IDEAppearance.Typography.body.monospaced()).foregroundStyle(IDEAppearance.ColorToken.foreground).lineLimit(1)
                Text(endpoint.handlerTitle + (showApplication ? " · \(endpoint.contextID.split(separator: "|").first.map(String.init)?.split(separator: ".").last ?? "")" : ""))
                    .font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted).lineLimit(1)
            }
            Spacer(minLength: IDEAppearance.Spacing.xs)
            if hasProblems { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(IDEAppearance.ColorToken.gitModified).accessibilityHidden(true) }
            if endpoint.certainty.isConditional { badge("conditional") }
            if endpoint.certainty.isInactive { badge("inactive") }
            if !endpoint.confidence.isExact { badge("partial") }
        }
        .opacity(endpoint.certainty.isInactive ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(endpoint.methodsTitle) \(endpoint.route), \(endpoint.handlerTitle)"
                            + (hasProblems ? ", has problems" : "") + (endpoint.certainty.isConditional ? ", conditional" : "")
                            + (endpoint.certainty.isInactive ? ", inactive" : ""))
    }

    private var methodColor: Color {
        switch endpoint.conditions.methods.first {
        case "GET": IDEAppearance.ColorToken.accent
        case "POST": IDEAppearance.ColorToken.gitAdded
        case "DELETE": IDEAppearance.ColorToken.error
        case "PUT", "PATCH": IDEAppearance.ColorToken.gitModified
        default: IDEAppearance.ColorToken.muted
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted)
            .padding(.horizontal, IDEAppearance.Spacing.xs)
            .background(IDEAppearance.ColorToken.controlHover, in: Capsule())
    }
}

/// The actions every endpoint surface offers (row context menu, inspector). Each one is implemented; nothing here is a placeholder.
struct IDESpringEndpointActions: View {
    let endpoint: SpringEndpoint
    let store: IDESpringStore
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        Button("Go to Handler") { workspace.openSpringLocation(endpoint.handlerLocation, title: endpoint.handlerTitle) }
        Button("Go to Mapping") { workspace.openSpringLocation(endpoint.mappingLocation, title: endpoint.title) }
        Button("Find Related References") { workspace.findSpringEndpointReferences(endpoint) }
        Divider()
        Button("Copy Route") { workspace.copySpringText(endpoint.route) }
        Button("Copy HTTP Method and Route") { workspace.copySpringText(endpoint.title) }
        Button("Generate HTTP Request") { workspace.generateSpringHTTPRequest(endpoint, config: store.snapshot?.config) }
        Divider()
        Button("Reveal in Application Context") { workspace.revealSpringApplication(endpoint.contextID, in: store) }
    }
}
