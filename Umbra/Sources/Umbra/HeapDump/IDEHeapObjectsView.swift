import AppKit
import JavaIntelligence
import SwiftUI

/// The histogram's trailing pane: the object index's state, then the selected class's instances
/// over the inspector of the selected instance.
struct IDEHeapObjectsPane: View {
    let session: IDEHeapDumpSession

    private var objects: IDEHeapObjectExplorer { session.objects }

    var body: some View {
        switch objects.state {
        case .unknown, .checking:
            message("Looking for an object index…", progress: true)
        case .absent(let estimated, let available):
            IDEHeapBuildIndexPrompt(objects: objects, estimatedBytes: estimated, availableBytes: available)
        case .building(let progress):
            VStack(spacing: IDEAppearance.Spacing.sm) {
                ProgressView(value: progress.fraction)
                    .frame(width: 240)
                Text("\(progress.phase.rawValue)…")
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Button("Cancel") { objects.cancelBuild() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let text):
            VStack(spacing: IDEAppearance.Spacing.sm) {
                Text(text)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Try Again") { objects.build() }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if objects.group == nil {
                message(session.grouping == .byPackage
                    ? "Group by class to see a class's instances."
                    : "Select a class to see its instances.", progress: false)
            } else {
                SplitPanes(axis: .vertical, minPrimary: 120, minSecondary: 160, defaultFraction: 0.45,
                           storageKey: "umbra.heapDump.objects.split") {
                    IDEHeapInstanceList(objects: objects)
                } secondary: {
                    IDEHeapInspectorView(session: session)
                }
            }
        }
    }

    private func message(_ text: String, progress: Bool) -> some View {
        VStack(spacing: IDEAppearance.Spacing.sm) {
            if progress { ProgressView().controlSize(.small) }
            Text(text)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What building the index costs, and the button that starts it: a costly step the user chooses.
struct IDEHeapBuildIndexPrompt: View {
    let objects: IDEHeapObjectExplorer
    let estimatedBytes: Int64
    let availableBytes: Int64?

    var body: some View {
        VStack(spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 28))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text("Instances, fields and referrers need an object index.")
                .font(IDEAppearance.Typography.body)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Build Object Index") { objects.build() }
                .keyboardShortcut(.defaultAction)
                .disabled(isShort)
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isShort: Bool {
        guard let availableBytes else { return false }
        return availableBytes < estimatedBytes
    }

    private var detail: String {
        let needed = ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)
        var text = "Building reads the dump again and needs up to \(needed) of disk while it runs (less once finished). It is kept in Caches and reused until the dump changes."
        if let availableBytes {
            let free = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
            text += isShort ? " Only \(free) is free." : " \(free) is free."
        }
        return text
    }
}

/// The selected class's instances, largest first.
struct IDEHeapInstanceList: View {
    let objects: IDEHeapObjectExplorer

    var body: some View {
        @Bindable var objects = objects
        VStack(spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text(objects.groupName ?? "")
                    .font(IDEAppearance.Typography.monoSmall)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: IDEAppearance.Spacing.sm)
                Text(countLine)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .monospacedDigit()
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, IDEAppearance.Spacing.xs)
            Divider()
            if objects.isLoadingInstances {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(objects.instances, selection: $objects.selectedInstance) {
                    TableColumn("Object") { row in
                        Text(row.address)
                            .font(IDEAppearance.Typography.monoSmall)
                    }
                    .width(min: 90, ideal: 120, max: 160)
                    TableColumn("Shallow") { row in
                        Text(ByteCountFormatter.string(fromByteCount: Int64(row.shallow), countStyle: .memory))
                            .font(IDEAppearance.Typography.monoSmall)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 60, ideal: 80, max: 110)
                    TableColumn("Value") { row in
                        Text(row.preview ?? "")
                            .font(IDEAppearance.Typography.monoSmall)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                            .lineLimit(1)
                            .help(row.preview ?? "")
                    }
                }
            }
        }
    }

    private var countLine: String {
        let total = objects.instanceTotal
        if total > objects.instances.count, !objects.instances.isEmpty {
            return "\(objects.instances.count.formatted()) largest of \(total.formatted())"
        }
        return total == 1 ? "1 object" : "\(total.formatted()) objects"
    }
}

/// One object: what it holds and who holds it, with back and forward through the references followed.
struct IDEHeapInspectorView: View {
    let session: IDEHeapDumpSession
    @State private var fieldSelection: IDEHeapFieldRow.ID?
    @State private var referrerSelection: IDEHeapReferrerRow.ID?

    private var objects: IDEHeapObjectExplorer { session.objects }

    var body: some View {
        @Bindable var objects = objects
        VStack(spacing: 0) {
            if objects.inspected == nil {
                Text("Select an instance to inspect it.")
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                header
                Divider()
                if objects.isLoadingObject {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch objects.inspectorTab {
                    case .fields: fieldTable
                    case .referrers: referrerTable
                    }
                }
            }
        }
    }

    private var header: some View {
        @Bindable var objects = objects
        return VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Button { objects.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(objects.backStack.isEmpty)
                    .help("Back")
                Button { objects.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(objects.forwardStack.isEmpty)
                    .help("Forward")
                Text(objects.inspectedTitle)
                    .font(IDEAppearance.Typography.monoSmall)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: IDEAppearance.Spacing.sm)
                if let name = objects.inspectedClassName {
                    Button { session.openSource?(Self.elementClass(name)) } label: { Image(systemName: "arrow.up.forward.square") }
                        .help("Jump to Source")
                }
            }
            .buttonStyle(.borderless)
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Picker("Show", selection: $objects.inspectorTab) {
                    Text("Fields").tag(IDEHeapObjectExplorer.InspectorTab.fields)
                    Text("Referrers (\(objects.referrerTotal.formatted()))").tag(IDEHeapObjectExplorer.InspectorTab.referrers)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(objects.inspectedSummary)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    private var fieldTable: some View {
        Table(objects.fields, selection: $fieldSelection) {
            TableColumn("Name") { row in
                Text(row.name)
                    .font(IDEAppearance.Typography.monoSmall)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 150, max: 260)
            TableColumn("Type") { row in
                Text(row.type)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            .width(min: 40, ideal: 56, max: 80)
            TableColumn("Value") { row in
                Text(row.value)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(row.target == nil ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.target == nil ? row.value : "Double-click to inspect \(row.value)")
            }
        }
        .contextMenu(forSelectionType: IDEHeapFieldRow.ID.self) { ids in
            if let row = objects.fields.first(where: { $0.id == ids.first }) {
                if let target = row.target {
                    Button("Inspect") { objects.inspect(target) }
                }
                Button("Copy Value") { copy(row.value) }
                Button("Copy Name") { copy(row.name) }
            }
        } primaryAction: { ids in
            if let target = objects.fields.first(where: { $0.id == ids.first })?.target { objects.inspect(target) }
        }
    }

    private var referrerTable: some View {
        VStack(spacing: 0) {
            Table(objects.referrers, selection: $referrerSelection) {
                TableColumn("Via") { row in
                    Text(row.isWeak ? "\(row.via) (weak)" : row.via)
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(row.isWeak ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.foreground)
                        .lineLimit(1)
                }
                .width(min: 50, ideal: 80, max: 160)
                TableColumn("Referrer") { row in
                    Text(row.title)
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(IDEAppearance.ColorToken.accent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Double-click to inspect \(row.title)")
                }
                TableColumn("Value") { row in
                    Text(row.preview ?? "")
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .lineLimit(1)
                }
                .width(min: 60, ideal: 100)
            }
            .contextMenu(forSelectionType: IDEHeapReferrerRow.ID.self) { ids in
                if let row = objects.referrers.first(where: { $0.id == ids.first }) {
                    Button("Inspect") { objects.inspect(row.referrer) }
                    Button("Copy") { copy("\(row.via) ← \(row.title)") }
                }
            } primaryAction: { ids in
                if let row = objects.referrers.first(where: { $0.id == ids.first }) { objects.inspect(row.referrer) }
            }
            if objects.referrerTotal > objects.referrers.count {
                Divider()
                Text("The first \(objects.referrers.count.formatted()) of \(objects.referrerTotal.formatted()) referrers")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .padding(IDEAppearance.Spacing.xs)
            }
        }
    }

    static func elementClass(_ name: String) -> String {
        var element = Substring(name)
        while element.hasSuffix("[]") { element = element.dropLast(2) }
        return String(element)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The Summary's card for the object index: its state, size and the actions on it.
struct IDEHeapIndexCard: View {
    let objects: IDEHeapObjectExplorer

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text("Object Index")
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            switch objects.state {
            case .unknown, .checking:
                Text("Looking for an index…").font(IDEAppearance.Typography.caption)
            case .absent(let estimated, _):
                Text("Not built. Instances, fields and referrers need it; building needs up to \(ByteCountFormatter.string(fromByteCount: estimated, countStyle: .file)) of disk.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Build Object Index") { objects.build() }
                    .controlSize(.small)
            case .building(let progress):
                ProgressView(value: progress.fraction)
                Text("\(progress.phase.rawValue)…").font(IDEAppearance.Typography.caption)
                Button("Cancel") { objects.cancelBuild() }.controlSize(.small)
            case .failed(let text):
                Text(text)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { objects.build() }.controlSize(.small)
            case .ready:
                if let facts = objects.indexFacts {
                    row("References", facts.references.formatted())
                    if facts.dangling > 0 { row("Missing targets", facts.dangling.formatted()) }
                    row("On disk", ByteCountFormatter.string(fromByteCount: facts.bytes, countStyle: .file))
                    row("Built in", String(format: "%.1f s", facts.seconds))
                }
                Button("Delete Index") { objects.deleteIndex() }
                    .controlSize(.small)
                    .help("Frees the disk space; instances and referrers need it built again.")
            }
        }
        .padding(IDEAppearance.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.card, in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.card))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(IDEAppearance.ColorToken.muted)
            Spacer(minLength: IDEAppearance.Spacing.sm)
            Text(value).monospacedDigit()
        }
        .font(IDEAppearance.Typography.caption)
    }
}
