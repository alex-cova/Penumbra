import SwiftUI

struct IDEDockerImagesPanel: View {
    let context: String

    @State private var images: [IDEDockerImage] = []
    @State private var selectedID: String?
    @State private var request: Request = .list
    @State private var refresh = 0
    @State private var output: String?
    @State private var error: String?
    @State private var loading = true
    @State private var asksForReference = false
    @State private var reference = ""

    var body: some View {
        let task = Load(request: request, revision: refresh)
        VStack(spacing: 0) {
            HStack {
                if request == .list {
                    Button("Refresh", systemImage: "arrow.clockwise") { refresh += 1 }
                    Button("Inspect", systemImage: "info.circle") {
                        if let image = images.first(where: { $0.id == selectedID }) {
                            request = .inspect(image.imageID)
                        }
                    }
                    .disabled(loading || selectedID == nil)
                    Button("Pull Image", systemImage: "arrow.down.circle") {
                        reference = ""
                        asksForReference = true
                    }
                    .disabled(loading)
                } else {
                    Button("Images", systemImage: "chevron.left") { request = .list }
                }
                Spacer()
            }
            .padding(8)
            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Pull Image", isPresented: $asksForReference) {
            TextField("Image reference", text: $reference)
            Button("Pull") {
                let name = reference.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { request = .pull(name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter an image reference to pull into \(context).")
        }
        .task(id: task) { await load(task) }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView(request == .list ? "Loading images…" : "Running Docker…")
        } else if let error {
            ContentUnavailableView("Docker image operation failed", systemImage: "shippingbox", description: Text(error))
        } else if let output {
            ScrollView([.horizontal, .vertical]) {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
        } else if images.isEmpty {
            ContentUnavailableView("No images", systemImage: "shippingbox")
        } else {
            Table(images, selection: $selectedID) {
                TableColumn("Repository", value: \.repository)
                TableColumn("Tag", value: \.tag)
                TableColumn("Size", value: \.size)
            }
        }
    }

    private func load(_ task: Load) async {
        guard isCurrent(task) else { return }
        loading = true
        error = nil
        output = nil
        do {
            let cli = try IDEDockerCLI.discover()
            switch task.request {
            case .list:
                let result = try await cli.images(in: context)
                guard isCurrent(task) else { return }
                images = result
                if !result.contains(where: { $0.id == selectedID }) { selectedID = nil }
            case let .inspect(id):
                let result = try await cli.inspectImage(id, in: context)
                guard isCurrent(task) else { return }
                output = result
            case let .pull(reference):
                let result = try await cli.pullImage(reference, in: context)
                guard isCurrent(task) else { return }
                output = result
            }
        } catch {
            guard isCurrent(task) else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func isCurrent(_ task: Load) -> Bool {
        !Task.isCancelled && request == task.request && refresh == task.revision
    }

    private enum Request: Equatable {
        case list, inspect(String), pull(String)
    }

    private struct Load: Equatable {
        let request: Request
        let revision: Int
    }
}
