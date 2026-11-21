import SwiftUI

struct IDEDockerContainerOutput: View {
    enum Kind: String {
        case logs = "Logs"
        case inspect = "Inspect"
    }

    let kind: Kind
    let container: IDEDockerContainer
    let context: String
    @State private var output: String?
    @State private var error: String?
    @State private var following = true

    var body: some View {
        VStack(spacing: 0) {
            if kind == .logs {
                Toggle("Follow Logs", isOn: $following)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Divider()
            }
            Group {
                if let error {
                    ContentUnavailableView("\(kind.rawValue) unavailable", systemImage: "text.alignleft", description: Text(error))
                } else if let output {
                    if output.isEmpty {
                        ContentUnavailableView("No output", systemImage: "text.alignleft")
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            Text(output)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                        }
                        .defaultScrollAnchor(kind == .logs ? .bottom : .top)
                    }
                } else {
                    ProgressView("Loading \(kind.rawValue.lowercased()) for \(container.name)…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: following) {
            guard !Task.isCancelled else { return }
            error = nil
            do {
                let cli = try IDEDockerCLI.discover()
                switch kind {
                case .logs:
                    if following {
                        try await follow(using: cli)
                    } else {
                        output = try await cli.logs(for: container.id, in: context)
                    }
                case .inspect: output = try await cli.inspect(container.id, in: context)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func follow(using cli: IDEDockerCLI) async throws {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(64))
        async let reader: Void = cli.followLogs(for: container.id, in: context, chunks: continuation)
        var buffer = Data()
        let limit = 256 * 1024
        output = ""
        for await chunk in stream {
            try Task.checkCancellation()
            buffer.append(chunk)
            if buffer.count > limit {
                buffer.removeFirst(buffer.count - limit)
            }
            output = String(decoding: buffer, as: UTF8.self)
        }
        try await reader
    }
}
