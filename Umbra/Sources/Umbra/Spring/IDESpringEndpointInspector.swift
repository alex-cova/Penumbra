import SpringIntelligence
import SwiftUI

/// The inspector for one endpoint: the mapping Spring will register, what the handler reads and returns, and where each part is
/// declared. Every location opens its source. A route that contains a `${placeholder}` also shows its value from configuration.
struct IDESpringEndpointInspector: View {
    let endpoint: SpringEndpoint
    let store: IDESpringStore
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                header
                actions
                mapping
                if !problems.isEmpty { section("Problems") { problemList } }
                if !endpoint.parameters.isEmpty { section("Parameters (\(endpoint.parameters.count))") { parameterList } }
                section("Request body") { requestBody }
                section("Response") { response }
                if !endpoint.exceptionHandlers.isEmpty { section("Exception handlers (\(endpoint.exceptionHandlers.count))") { exceptionHandlers } }
                if !endpoint.validations.isEmpty { section("Validation") { ForEach(endpoint.validations, id: \.self) { mono($0) } } }
            }
            .padding(IDEAppearance.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(IDEAppearance.ColorToken.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector for endpoint \(endpoint.title)")
    }

    private var problems: [SpringDiagnostic] { store.diagnostics(for: endpoint) }

    private var header: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xxs) {
            Text(endpoint.title).font(IDEAppearance.Typography.body.weight(.semibold).monospaced())
                .foregroundStyle(IDEAppearance.ColorToken.foreground).textSelection(.enabled)
            Text(endpoint.handlerTitle + "(" + endpoint.parameters.map(\.type).joined(separator: ", ") + ")")
                .font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted).textSelection(.enabled)
        }
    }

    private var actions: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Button("Go to Handler") { workspace.openSpringLocation(endpoint.handlerLocation, title: endpoint.handlerTitle) }
            Button("Generate HTTP Request") { workspace.generateSpringHTTPRequest(endpoint, config: store.snapshot?.config) }
            Menu("More") { IDESpringEndpointActions(endpoint: endpoint, store: store) }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .controlSize(.small)
    }

    private var mapping: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xxs) {
            fact("Stack", endpoint.stack.title)
            fact("Route", endpoint.route)
            if let config = store.snapshot?.config, !endpoint.placeholderKeys.isEmpty {
                let resolved = endpoint.resolvedRoute(using: config)
                fact("Resolved", resolved.route + (resolved.unresolved.isEmpty ? "" : "  (not set: \(resolved.unresolved.joined(separator: ", ")))"))
            }
            if !endpoint.pathVariables.isEmpty { fact("Path variables", endpoint.pathVariables.map { "{\($0)}" }.joined(separator: ", ")) }
            fact("Method", endpoint.conditions.methods.isEmpty ? "any" : endpoint.conditions.methods.joined(separator: ", "))
            if !endpoint.conditions.consumes.isEmpty { fact("Consumes", endpoint.conditions.consumes.joined(separator: ", ")) }
            if !endpoint.conditions.produces.isEmpty { fact("Produces", endpoint.conditions.produces.joined(separator: ", ")) }
            if !endpoint.conditions.params.isEmpty { fact("Params", endpoint.conditions.params.joined(separator: ", ")) }
            if !endpoint.conditions.headers.isEmpty { fact("Headers", endpoint.conditions.headers.joined(separator: ", ")) }
            if let name = endpoint.mappingName { fact("Name", name) }
            link("Controller", endpoint.controller, endpoint.controllerLocation)
            link("Handler", endpoint.handlerSignature, endpoint.handlerLocation)
            link("Mapping", endpoint.mappingDeclaredIn.map { "on \($0)" } ?? "on the handler", endpoint.mappingLocation)
            if let c = endpoint.composedFrom { fact("Composed from", "@" + (c.split(separator: ".").last.map(String.init) ?? c)) }
            if let m = endpoint.module { fact("Module", m) }
            fact("Registration", registration)
            if case .partial(let reasons) = endpoint.confidence {
                fact("Static analysis", "partial — " + reasons.joined(separator: "; ") + ". Conflicts are not checked for this endpoint.")
            }
        }
    }

    private var registration: String {
        switch endpoint.certainty {
        case .certain: "Registered (as far as static analysis can tell)"
        case .conditional(let r): "Conditional — " + (r.first ?? "depends on a condition")
        case .inactive(let r): "Inactive — " + (r.first ?? "excluded under the analysis profiles")
        }
    }

    private var problemList: some View {
        ForEach(Array(problems.enumerated()), id: \.offset) { _, d in
            Button { workspace.openSpringLocation(d.location, title: d.code) } label: {
                Label(d.message, systemImage: d.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(d.severity == .error ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
        }
    }

    private var parameterList: some View {
        ForEach(Array(endpoint.parameters.enumerated()), id: \.offset) { _, p in
            Button { workspace.openSpringLocation(p.location, title: p.name) } label: {
                VStack(alignment: .leading, spacing: IDEAppearance.Spacing.hairline) {
                    Text("\(p.bindingName): \(p.type)").font(IDEAppearance.Typography.caption.monospaced())
                        .foregroundStyle(IDEAppearance.ColorToken.foreground).lineLimit(1)
                    Text(p.kind.title + (p.isImplicit ? " (inferred)" : "") + (p.isRequired ? ", required" : ", optional")
                         + (p.defaultValue.map { ", default \($0)" } ?? ""))
                        .font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(p.kind.title) \(p.bindingName), \(p.type), \(p.isRequired ? "required" : "optional")")
        }
    }

    @ViewBuilder private var requestBody: some View {
        if let type = endpoint.requestBodyType {
            mono(type)
            if let skeleton = endpoint.requestBodySkeleton {
                Text(skeleton).font(IDEAppearance.Typography.caption.monospaced()).foregroundStyle(IDEAppearance.ColorToken.muted)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            none("The handler reads no request body.")
        }
    }

    @ViewBuilder private var response: some View {
        let r = endpoint.response
        if let payload = r.payload {
            fact("Body", payload + (r.isStream ? " (a stream of items)" : ""))
        } else {
            fact("Body", r.isBody ? "none (void)" : "none: the return value is resolved as a view name")
        }
        fact("Declared", r.declared)
        if !r.wrappers.isEmpty { fact("Wrapped in", r.wrappers.joined(separator: " › ")) }
        if let status = r.status { fact("Status", status) }
    }

    private var exceptionHandlers: some View {
        ForEach(Array(endpoint.exceptionHandlers.enumerated()), id: \.offset) { _, h in
            Button { workspace.openSpringLocation(h.location, title: h.method) } label: {
                VStack(alignment: .leading, spacing: IDEAppearance.Spacing.hairline) {
                    Text("\(h.owner.split(separator: ".").last.map(String.init) ?? h.owner).\(h.method)")
                        .font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.foreground)
                    Text((h.exceptions.isEmpty ? "any exception" : h.exceptions.joined(separator: ", ")) + " — " + scope(h.scope))
                        .font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func scope(_ s: SpringExceptionHandlerRef.Scope) -> String {
        switch s {
        case .controller: "this controller"
        case .advice: "controller advice"
        case .adviceMaybe: "controller advice (its selector cannot be evaluated statically)"
        }
    }

    private func link(_ label: String, _ value: String, _ location: SpringSourceLocation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: IDEAppearance.Spacing.xs) {
            Text(label).foregroundStyle(IDEAppearance.ColorToken.muted).frame(width: 96, alignment: .leading)
            Button { workspace.openSpringLocation(location, title: value) } label: {
                Text(value).foregroundStyle(IDEAppearance.ColorToken.accent).lineLimit(2).multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
        }
        .font(IDEAppearance.Typography.caption)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: IDEAppearance.Spacing.xs) {
            Text(label).foregroundStyle(IDEAppearance.ColorToken.muted).frame(width: 96, alignment: .leading)
            Text(value).foregroundStyle(IDEAppearance.ColorToken.foreground).textSelection(.enabled)
        }
        .font(IDEAppearance.Typography.caption)
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(IDEAppearance.Typography.caption.monospaced()).foregroundStyle(IDEAppearance.ColorToken.foreground).textSelection(.enabled)
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
