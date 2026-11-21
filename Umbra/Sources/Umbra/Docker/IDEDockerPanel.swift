import SwiftUI

struct IDEDockerPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var section = Section.containers
    @State private var contexts: [String] = []
    @State private var containers: [IDEDockerContainer] = []
    @State private var listedContext: String?
    @State private var selection: String?
    @State private var refresh = 0
    @State private var error: String?
    @State private var loading = true
    @State private var outputKind: IDEDockerContainerOutput.Kind?
    @State private var operation: Operation?
    @State private var operationError: String?

    var body: some View {
        let request = Request(context: workspace.dockerContext, refresh: refresh)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Context", selection: contextSelection) {
                    if workspace.dockerContext.isEmpty {
                        Text("Select a context").tag("")
                    } else if !contexts.contains(workspace.dockerContext) {
                        Text(workspace.dockerContext).tag(workspace.dockerContext)
                    }
                    ForEach(contexts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .fixedSize()
                .disabled(operation != nil)
                Picker("Docker resources", selection: $section) {
                    Text("Containers").tag(Section.containers)
                    Text("Images").tag(Section.images)
                    Text("Project").tag(Section.project)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(operation != nil)
                if section == .containers || workspace.dockerContext.isEmpty {
                    containerControls
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            Divider()

            if section == .images, !workspace.dockerContext.isEmpty {
                IDEDockerImagesPanel(context: workspace.dockerContext)
                    .id(workspace.dockerContext)
            } else if section == .project, !workspace.dockerContext.isEmpty {
                IDEDockerProjectPanel(context: workspace.dockerContext, root: workspace.project.rootURL)
                    .id(ProjectSelection(context: workspace.dockerContext, root: workspace.project.rootURL))
            } else {
                containerContent
            }
        }
        .task(id: request) {
            await reload(request)
        }
        .task(id: operation) {
            if let operation { await perform(operation) }
        }
        .alert("Docker action failed", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK", role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
    }

    @ViewBuilder
    private var containerControls: some View {
        Button("Refresh", systemImage: "arrow.clockwise") { refresh += 1 }
            .disabled(operation != nil)
        if outputKind != nil {
            Button("Containers", systemImage: "chevron.left") { outputKind = nil }
        } else {
            Button("Logs", systemImage: "text.alignleft") { outputKind = .logs }
                .disabled(!canUseSelection)
            Button("Inspect", systemImage: "info.circle") { outputKind = .inspect }
                .disabled(!canUseSelection)
            Button("Open Shell", systemImage: "terminal") {
                guard let container = selectedContainer else { return }
                do {
                    try workspace.openDockerShell(container: container, context: workspace.dockerContext)
                } catch {
                    operationError = error.localizedDescription
                }
            }
            .disabled(!canUseSelection || selectedContainer?.state != "running")
            Menu("Actions", systemImage: "ellipsis.circle") {
                if let container = selectedContainer {
                    Button("Start") { begin(.start, container: container) }
                        .disabled(container.state != "created" && container.state != "exited")
                    Button("Stop") { begin(.stop, container: container) }
                        .disabled(container.state != "running" && container.state != "restarting")
                    Button("Restart") { begin(.restart, container: container) }
                        .disabled(container.state != "running")
                }
            }
            .disabled(!canUseSelection)
        }
        if let operation {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("\(operation.action.title) \(operation.name)")
        }
    }

    @ViewBuilder
    private var containerContent: some View {
        if loading || listedContext != workspace.dockerContext {
            ProgressView("Connecting to Docker…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView("Docker unavailable", systemImage: "shippingbox",
                                   description: Text(error))
        } else if let outputKind, let selectedContainer {
            IDEDockerContainerOutput(
                kind: outputKind,
                container: selectedContainer,
                context: workspace.dockerContext
            )
            .id(outputKind)
        } else if containers.isEmpty {
            ContentUnavailableView("No containers", systemImage: "shippingbox")
        } else {
            Table(containers, selection: $selection) {
                TableColumn("Name", value: \.name)
                TableColumn("Image", value: \.image)
                TableColumn("Status", value: \.status)
                TableColumn("Ports", value: \.ports)
            }
        }
    }

    private var selectedContainer: IDEDockerContainer? {
        guard listedContext == workspace.dockerContext else { return nil }
        return containers.first { $0.id == selection }
    }

    private var canUseSelection: Bool {
        !loading && operation == nil && selectedContainer != nil
    }

    private func begin(_ action: IDEDockerContainerAction, container: IDEDockerContainer) {
        guard canUseSelection, selectedContainer?.id == container.id else { return }
        operation = Operation(action: action, id: container.id, name: container.name, context: workspace.dockerContext)
    }

    private func perform(_ operation: Operation) async {
        do {
            try await IDEDockerCLI.discover().perform(operation.action, on: operation.id, in: operation.context)
        } catch {
            guard !Task.isCancelled else { return }
            operationError = "\(operation.name) on \(operation.context): \(error.localizedDescription)"
        }
        guard !Task.isCancelled else { return }
        self.operation = nil
        refresh += 1
    }

    private var contextSelection: Binding<String> {
        Binding(
            get: { workspace.dockerContext },
            set: {
                outputKind = nil
                workspace.selectDockerContext($0)
            }
        )
    }

    private func reload(_ request: Request) async {
        let context = request.context
        guard isCurrent(request) else { return }
        loading = true
        error = nil
        do {
            let cli = try IDEDockerCLI.discover()
            let available = try await cli.contexts()
            guard isCurrent(request) else { return }
            contexts = available
            if context.isEmpty {
                guard !available.isEmpty else {
                    error = "No Docker contexts are configured."
                    listedContext = context
                    loading = false
                    return
                }
                let current = try await cli.currentContext()
                guard isCurrent(request) else { return }
                workspace.selectDockerContext(available.contains(current) ? current : available[0])
                return
            }

            guard available.contains(context) else {
                error = "The selected Docker context is unavailable. Choose another context."
                listedContext = context
                loading = false
                return
            }

            let result = try await cli.containers(in: context)
            guard isCurrent(request) else { return }
            if listedContext != context || !result.contains(where: { $0.id == selection }) {
                selection = nil
                outputKind = nil
            }
            containers = result
        } catch {
            guard isCurrent(request) else { return }
            containers = []
            selection = nil
            outputKind = nil
            self.error = error.localizedDescription
        }
        listedContext = context
        loading = false
    }

    private func isCurrent(_ request: Request) -> Bool {
        !Task.isCancelled && workspace.dockerContext == request.context && refresh == request.refresh
    }

    private enum Section {
        case containers, images, project
    }

    private struct ProjectSelection: Hashable {
        let context: String
        let root: URL?
    }

    private struct Operation: Equatable {
        let action: IDEDockerContainerAction
        let id: String
        let name: String
        let context: String
    }

    private struct Request: Equatable {
        let context: String
        let refresh: Int
    }
}
