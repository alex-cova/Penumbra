import SwiftUI

struct IDEDockerContainersTable: View {
    let context: String
    let containers: [IDEDockerContainer]
    @Binding var selection: String?
    let busyContainerID: String?
    let perform: (IDEDockerContainerAction, IDEDockerContainer) -> Void

    @State private var usage: [String: IDEDockerContainerUsage] = [:]

    var body: some View {
        Table(containers, selection: $selection) {
            TableColumn("Name") { container in
                HStack(spacing: 6) {
                    lifecycleControl(for: container)
                        .frame(width: 24)
                    Text(container.name)
                        .help(container.name)
                }
            }
            .width(min: 115, ideal: 185)
            TableColumn("Image") { container in
                Text(container.image)
                    .help(container.image)
            }
            .width(min: 115, ideal: 195)
            TableColumn("Status", value: \.status)
                .width(min: 80, ideal: 145)
            TableColumn("CPU") { container in
                let cpu = usage(for: container)?.cpu
                Text(cpu ?? "—")
                    .monospacedDigit()
                    .accessibilityLabel(cpu.map { "CPU usage \($0)" } ?? "CPU usage unavailable")
            }
            .width(min: 55, ideal: 65, max: 90)
            TableColumn("Memory") { container in
                let memory = usage(for: container)
                Text(memory?.memoryUsed ?? "—")
                    .monospacedDigit()
                    .help(memory?.memory ?? "Memory usage unavailable")
                    .accessibilityLabel(memory.map { "Memory usage \($0.memory)" } ?? "Memory usage unavailable")
            }
            .width(min: 75, ideal: 90, max: 125)
            TableColumn("Ports") { container in
                Text(container.ports)
                    .help(container.ports)
            }
            .width(min: 80, ideal: 190)
        }
        .task { await sampleUsage() }
    }

    @ViewBuilder
    private func lifecycleControl(for container: IDEDockerContainer) -> some View {
        if busyContainerID == container.id {
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Updating \(container.name)")
        } else if let action = container.primaryAction {
            let title = "\(action.title) \(container.name)"
            Button {
                perform(action, container)
            } label: {
                Label(title, systemImage: action == .start ? "play.fill" : "stop.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(title)
            .disabled(busyContainerID != nil)
        } else {
            Color.clear
                .frame(height: 18)
                .accessibilityHidden(true)
        }
    }

    private func usage(for container: IDEDockerContainer) -> IDEDockerContainerUsage? {
        container.state == "running" ? usage[container.id] : nil
    }

    private func sampleUsage() async {
        guard containers.contains(where: { $0.state == "running" }),
              let cli = try? IDEDockerCLI.discover() else { return }
        while !Task.isCancelled {
            let snapshot = try? await cli.containerUsage(in: context)
            guard !Task.isCancelled else { return }
            usage = Dictionary((snapshot ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
        }
    }
}
