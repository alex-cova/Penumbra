import SwiftUI

struct IDEDatabaseScopePicker: View {
    let label: String
    let current: String
    let load: () async throws -> [String]
    let select: (String) async throws -> Void
    @State private var isOpen = false
    @State private var options: [String]?
    @State private var error: String?
    @State private var isSelecting = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            Label(current.isEmpty ? label : current, systemImage: "chevron.up.chevron.down")
                .lineLimit(1)
        }
        .accessibilityLabel(label)
        .accessibilityValue(current)
        .popover(isPresented: $isOpen) {
            VStack(alignment: .leading, spacing: 8) {
                Text(label).font(.headline)
                if let options, !options.isEmpty {
                    List(options, id: \.self) { name in
                        Button {
                            choose(name)
                        } label: {
                            HStack {
                                Text(name)
                                Spacer()
                                if name == current { Image(systemName: "checkmark").accessibilityHidden(true) }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(name == current ? .isSelected : [])
                    }
                    .disabled(isSelecting)
                    .frame(height: min(220, CGFloat(options.count) * 30 + 12))
                } else if options != nil {
                    Text("No choices available.").foregroundStyle(.secondary)
                } else if error == nil {
                    ProgressView().controlSize(.small).accessibilityLabel("Loading \(label)")
                }
                if isSelecting { ProgressView().controlSize(.small).accessibilityLabel("Switching scope") }
                if let error {
                    Text(error).font(.caption).foregroundStyle(IDEAppearance.ColorToken.error)
                }
            }
            .padding(12)
            .frame(width: 260)
            .task {
                options = nil
                error = nil
                do { options = try await load() }
                catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
        }
    }

    private func choose(_ name: String) {
        isSelecting = true
        error = nil
        Task {
            defer { isSelecting = false }
            do {
                try await select(name)
                isOpen = false
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
