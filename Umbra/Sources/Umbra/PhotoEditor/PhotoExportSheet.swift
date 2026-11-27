import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PhotoExportSheet: View {
    @Bindable var session: PhotoEditorSession
    @Binding var exportError: String?
    @Environment(\.dismiss) private var dismiss

    @State private var format: PhotoExportFormat = .jpeg
    @State private var quality: Double = 0.9
    @State private var isWorking = false
    @State private var batchNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: PhotoStudio.Spacing.lg) {
            VStack(alignment: .leading, spacing: PhotoStudio.Spacing.xs) {
                Text("Export")
                    .font(.headline)
                    .foregroundStyle(PhotoStudio.Photo.value)
                Text(
                    session.hasImage
                        ? "Saves at full resolution and keeps EXIF, GPS, and color profile."
                        : "Apply the current recipe to many photos."
                )
                .font(PhotoStudio.Typography.caption)
                .foregroundStyle(PhotoStudio.Photo.label)
            }

            Picker("Format", selection: $format) {
                ForEach(PhotoExportFormat.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .pickerStyle(.segmented)

            if format.supportsQuality {
                VStack(alignment: .leading, spacing: PhotoStudio.Spacing.xs) {
                    HStack {
                        Text("Quality")
                        Spacer()
                        Text(quality, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $quality, in: 0.1...1)
                }
            }

            if let batchNote {
                Text(batchNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Share…", systemImage: "square.and.arrow.up", action: share)
                    .disabled(isWorking || !session.hasImage)
                Button("Batch…", systemImage: "square.stack.3d.up", action: presentBatchSources)
                    .disabled(isWorking)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save…", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || !session.hasImage)
            }
        }
        .padding(PhotoStudio.Spacing.lg)
        .frame(minWidth: 280)
        .overlay {
            if isWorking || session.exportState == .exporting {
                VStack(spacing: PhotoStudio.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    if session.batchTotal > 0 {
                        Text("\(session.batchCompleted) of \(session.batchTotal)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(PhotoStudio.Spacing.md)
                .background(.ultraThinMaterial, in: .rect(cornerRadius: PhotoStudio.Radius.sm))
            }
        }
    }

    private var suggestedName: String {
        let base = session.sourceFileName.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? "photo"
        return "\(base).\(format.fileExtension)"
    }

    private func save() {
        Task {
            isWorking = true
            let result = await session.export(format: format, quality: quality)
            isWorking = false
            switch result {
            case .success(let data):
                PhotoFilePanel.save(suggestedName: suggestedName, contentTypes: [format.utType]) { url in
                    do {
                        try data.write(to: url)
                        exportError = nil
                        dismiss()
                    } catch {
                        exportError = error.localizedDescription
                    }
                }
            case .failure(let error):
                exportError = error.localizedDescription
            }
        }
    }

    private func share() {
        Task {
            isWorking = true
            let result = await session.export(format: format, quality: quality)
            isWorking = false
            switch result {
            case .success(let data):
                presentSharePicker(data: data)
            case .failure(let error):
                exportError = error.localizedDescription
            }
        }
    }

    private func presentBatchSources() {
        PhotoFilePanel.openFiles(
            message: "Choose photos to export with the current recipe",
            contentTypes: PhotoEditorImport.contentTypes,
            allowsMultipleSelection: true
        ) { urls in
            guard !urls.isEmpty else { return }
            PhotoFilePanel.openDirectory(message: "Choose a folder for the exported files") { destination in
                guard let destination else { return }
                Task { await runBatch(urls: urls, destination: destination) }
            }
        }
    }

    private func runBatch(urls: [URL], destination: URL) async {
        isWorking = true
        batchNote = nil
        let items = await session.batchExport(
            urls: urls,
            format: format,
            quality: quality,
            destination: destination
        )
        isWorking = false
        let failed = items.filter { !$0.succeeded }
        if failed.isEmpty {
            batchNote = "Exported \(items.count) photos."
            exportError = nil
        } else {
            let message = "Exported \(items.count - failed.count) of \(items.count). \(failed.count) failed."
            batchNote = message
            exportError = message
        }
    }

    private func presentSharePicker(data: Data) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName)
        do {
            try data.write(to: temp)
        } catch {
            exportError = error.localizedDescription
            return
        }
        guard let content = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [temp])
        let rect = NSRect(x: content.bounds.midX, y: content.bounds.maxY - 48, width: 1, height: 1)
        picker.show(relativeTo: rect, of: content, preferredEdge: .minY)
    }
}
