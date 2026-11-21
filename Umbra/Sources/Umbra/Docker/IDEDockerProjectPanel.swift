import SwiftUI

struct IDEDockerProjectPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    let context: String
    let root: URL?

    @State private var dockerfile: URL?
    @State private var composeFile: URL?
    @State private var buildx = false
    @State private var compose = false
    @State private var checking = true
    @State private var remote = false
    @State private var tag = ""
    @State private var services: [String] = []
    @State private var service = ""
    @State private var operation: Operation?
    @State private var output = ""
    @State private var status = ""
    @State private var checkRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let root {
                controls
                Divider()
                if remote {
                    Text("Bind mounts use paths on the Docker host.")
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                if !status.isEmpty {
                    Text(status)
                        .padding(8)
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                }
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: checkRevision) { await check(root) }
                .task(id: operation) {
                    if let operation { await run(operation, root: root) }
                }
            } else {
                ContentUnavailableView("Open a Project Folder", systemImage: "folder",
                                       description: Text("Docker builds and Compose use files in the current project."))
            }
        }
    }

    private var controls: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading) {
                HStack {
                    TextField("Image tag (optional)", text: $tag)
                        .frame(idealWidth: 155, maxWidth: 185)
                    Button("Build Dockerfile") {
                        if let dockerfile { operation = .build(dockerfile, tag) }
                    }
                    .disabled(!buildx || dockerfile == nil)
                }
                if !checking, !buildx || dockerfile == nil {
                    Text(buildx ? "No Dockerfile in the project root." : "Docker Buildx is unavailable.")
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(operation != nil)
            VStack(alignment: .leading) {
                HStack {
                    Picker("Compose service", selection: $service) {
                        Text("All Services").tag("")
                        ForEach(services, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    Menu("Compose") {
                        Button("Load Services") {
                            if let composeFile { operation = .services(composeFile) }
                        }
                        ForEach(IDEDockerComposeCommand.allCases) { command in
                            Button(command.rawValue) {
                                if let composeFile {
                                    operation = .compose(command, composeFile, service.isEmpty ? nil : service)
                                }
                            }
                        }
                    }
                    .disabled(!compose || composeFile == nil)
                }
                if !checking, !compose || composeFile == nil {
                    Text(compose ? "No Compose file in the project root." : "Docker Compose is unavailable.")
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(operation != nil)
            Spacer(minLength: 0)
            if operation != nil {
                Button("Cancel") {
                    operation = nil
                    status = "Docker command cancelled."
                }
            } else {
                Button("Refresh", systemImage: "arrow.clockwise") { checkRevision += 1 }
                    .labelStyle(.iconOnly)
                    .disabled(checking)
            }
        }
        .padding(8)
        .disabled(checking)
    }

    private func check(_ root: URL) async {
        checking = true
        status = ""
        defer { if !Task.isCancelled { checking = false } }
        dockerfile = findFile(["Dockerfile"], in: root)
        composeFile = findFile(["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"], in: root)
        services = []
        service = ""
        do {
            let cli = try IDEDockerCLI.discover()
            async let buildxAvailable = cli.pluginAvailable("buildx")
            async let composeAvailable = cli.pluginAvailable("compose")
            async let endpoint = cli.endpoint(in: context)
            let (hasBuildx, hasCompose, host) = try await (buildxAvailable, composeAvailable, endpoint)
            try Task.checkCancellation()
            buildx = hasBuildx
            compose = hasCompose
            remote = !host.hasPrefix("unix://")
        } catch {
            guard !Task.isCancelled else { return }
            status = error.localizedDescription
            buildx = false
            compose = false
        }
    }

    private func findFile(_ names: [String], in root: URL) -> URL? {
        names.lazy.map { root.appendingPathComponent($0) }
            .first { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    private func run(_ request: Operation, root: URL) async {
        guard !Task.isCancelled else { return }
        output = ""
        status = "Running Docker on \(context)…"
        defer { if !Task.isCancelled { operation = nil } }
        do {
            let cli = try IDEDockerCLI.discover()
            let gate = IDEProjectTrustGate(store: IDESharedServices.shared.dockerTrust) { folder in
                await workspace.promptProjectTrust(
                    message: "Trust this project’s Docker configuration?",
                    detail: "Dockerfile and Compose commands can execute project code. Umbra will run them for \(folder.lastPathComponent) using \(context)."
                )
            }
            guard await gate.confirmTrust(for: root, isCurrent: {
                !Task.isCancelled && workspace.project.rootURL == root && workspace.dockerContext == context
            }) else {
                if !Task.isCancelled { status = "Docker command cancelled." }
                return
            }
            try Task.checkCancellation()
            if case let .services(file) = request {
                let result = try await cli.composeServices(file: file, in: context)
                try Task.checkCancellation()
                services = result
                if !services.contains(service) { service = "" }
                status = services.isEmpty ? "No Compose services found." : "Compose services loaded."
                return
            }

            let (stream, chunks) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(64))
            async let job: Void = execute(request, cli: cli, root: root, chunks: chunks)
            var buffer = Data()
            let limit = 256 * 1024
            for await chunk in stream {
                try Task.checkCancellation()
                buffer.append(chunk)
                if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
                output = String(decoding: buffer, as: UTF8.self)
            }
            try await job
            status = "Docker command completed."
        } catch {
            guard !Task.isCancelled else { return }
            status = output.isEmpty ? error.localizedDescription : "Docker command failed. See output below."
        }
    }

    private func execute(
        _ request: Operation, cli: IDEDockerCLI, root: URL, chunks: AsyncStream<Data>.Continuation
    ) async throws {
        switch request {
        case let .build(file, tag):
            try await cli.build(file: file, root: root, tag: tag.trimmingCharacters(in: .whitespacesAndNewlines),
                                in: context, chunks: chunks)
        case let .compose(command, file, service):
            try await cli.compose(command, file: file, service: service, in: context, chunks: chunks)
        case .services:
            chunks.finish()
        }
    }

    private enum Operation: Equatable {
        case build(URL, String)
        case services(URL)
        case compose(IDEDockerComposeCommand, URL, String?)
    }
}
