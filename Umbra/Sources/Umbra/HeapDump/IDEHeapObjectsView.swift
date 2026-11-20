import AppKit
import JavaIntelligence
import SwiftUI

/// The histogram's trailing pane: the object index's state, then the selected class's instances
/// over the inspector of the selected instance.
struct IDEHeapObjectsPane: View {
    let session: IDEHeapDumpSession

    private var objects: IDEHeapObjectExplorer { session.objects }

    var body: some View {
        IDEHeapIndexGate(objects: objects) {
            if objects.group == nil {
                IDEHeapPaneMessage(text: session.grouping == .byPackage
                    ? "Group by class to see a class's instances."
                    : "Select a class to see its instances.")
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
}

/// The index's states (looking, absent with the build prompt, building, failed); `content` once it is ready.
struct IDEHeapIndexGate<Content: View>: View {
    let objects: IDEHeapObjectExplorer
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch objects.state {
        case .unknown, .checking:
            IDEHeapPaneMessage(text: "Looking for an object index…", progress: true)
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
            content()
        }
    }
}

struct IDEHeapPaneMessage: View {
    let text: String
    var progress = false

    var body: some View {
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
                    .width(min: 60, ideal: 76, max: 110)
                    TableColumn("Retained") { row in
                        Text(ByteCountFormatter.string(fromByteCount: row.retained, countStyle: .memory))
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
            return "\(objects.instances.count.formatted()) retaining most of \(total.formatted())"
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
                    case .path: pathTable
                    case .retains: retainedSetTable
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
                    Text("Path to Root").tag(IDEHeapObjectExplorer.InspectorTab.path)
                    Text("Retains").tag(IDEHeapObjectExplorer.InspectorTab.retains)
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

    @State private var pathSelection: IDEHeapPathRow.ID?
    @State private var retainedSelection: HeapIndex.ClassTotal.ID?

    @ViewBuilder
    private var pathTable: some View {
        if objects.path.isEmpty {
            IDEHeapPaneMessage(text: "Nothing reaches this object from a GC root, not even through a weak reference: it is garbage the dump was written with.")
        } else {
            Table(objects.path, selection: $pathSelection) {
                TableColumn("Object") { row in
                    HStack(spacing: IDEAppearance.Spacing.xs) {
                        Image(systemName: row.id == 0 ? "smallcircle.filled.circle" : (row.rootKinds != nil ? "anchor" : "arrow.up"))
                            .foregroundStyle(row.rootKinds != nil ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.muted)
                            .frame(width: 14)
                        Text(Self.shortTitle(row.title))
                            .font(IDEAppearance.Typography.monoSmall)
                            .foregroundStyle(row.id == 0 ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.accent)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .help(row.rootKinds.map { "\(row.title)\nGC root: \($0)" } ?? row.title)
                }
                TableColumn("Holds the One Below Through") { row in
                    Text(row.via.map { row.isWeak ? "\($0) (weak)" : $0 } ?? "")
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(row.isWeak ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.foreground)
                        .lineLimit(1)
                        .help(row.isWeak ? "A Reference's referent: it does not keep the object alive." : "")
                }
                .width(min: 70, ideal: 110, max: 220)
                TableColumn("Root / Value") { row in
                    Text(row.rootKinds.map { "GC root: \($0)" } ?? (row.preview ?? ""))
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(row.rootKinds != nil ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.muted)
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 140)
            }
            .contextMenu(forSelectionType: IDEHeapPathRow.ID.self) { ids in
                if let row = objects.path.first(where: { $0.id == ids.first }), row.id > 0 {
                    Button("Inspect") { objects.inspect(row.object) }
                }
                Button("Copy Path") { copy(objects.path.map { ($0.via.map { "\($0) ← " } ?? "") + $0.title }.joined(separator: "\n")) }
            } primaryAction: { ids in
                if let row = objects.path.first(where: { $0.id == ids.first }), row.id > 0 { objects.inspect(row.object) }
            }
        }
    }

    @ViewBuilder
    private var retainedSetTable: some View {
        if objects.isLoadingRetainedSet {
            IDEHeapPaneMessage(text: "Walking what this object keeps alive…", progress: true)
        } else {
            VStack(spacing: 0) {
                Table(objects.retainedSet, selection: $retainedSelection) {
                    TableColumn("Class") { total in
                        Text(total.name)
                            .font(IDEAppearance.Typography.monoSmall)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    TableColumn("Objects") { total in
                        Text(total.count.formatted())
                            .font(IDEAppearance.Typography.monoSmall)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 60, ideal: 80, max: 120)
                    TableColumn("Shallow") { total in
                        Text(ByteCountFormatter.string(fromByteCount: total.bytes, countStyle: .memory))
                            .font(IDEAppearance.Typography.monoSmall)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 60, ideal: 80, max: 120)
                }
                if !objects.retainedSetComplete {
                    Divider()
                    Text("Stopped after 200 million objects; the totals are a lower bound.")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .padding(IDEAppearance.Spacing.xs)
                }
            }
        }
    }

    /// `a.b.Outer$Inner @ 0x7f…` → `Outer$Inner @ 0x7f…`: the package is in the tooltip.
    static func shortTitle(_ title: String) -> String {
        let parts = title.split(separator: " @ ", maxSplits: 1)
        guard let name = parts.first, let dot = name.lastIndex(of: ".") else { return title }
        let prefix = name.hasPrefix("class ") ? "class " : ""
        let simple = prefix + name[name.index(after: dot)...]
        return parts.count > 1 ? "\(simple) @ \(parts[1])" : simple
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


// MARK: - Dominators

/// The dominator tree: what keeps the most memory alive, each expandable into what it alone keeps,
/// with the inspector of the selected object beside it.
struct IDEHeapDominatorsView: View {
    let session: IDEHeapDumpSession

    private var objects: IDEHeapObjectExplorer { session.objects }

    var body: some View {
        IDEHeapIndexGate(objects: objects) {
            SplitPanes(minPrimary: 380, minSecondary: 320, defaultFraction: 0.58, storageKey: "umbra.heapDump.dominators.split") {
                tree
            } secondary: {
                IDEHeapInspectorView(session: session)
            }
            .onAppear { objects.loadDominatorsIfNeeded() }
        }
    }

    private var tree: some View {
        @Bindable var objects = objects
        let total = max(objects.index?.reachableBytes ?? 1, 1)
        return VStack(spacing: 0) {
            if objects.isLoadingDominators {
                IDEHeapPaneMessage(text: "Loading the dominator tree…", progress: true)
            } else {
                Table(objects.dominatorRows, selection: $objects.selectedDominatorRow) {
                    TableColumn("Object") { row in
                        HStack(spacing: IDEAppearance.Spacing.xxs) {
                            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
                            if row.childCount > 0 {
                                Button { objects.toggle(row) } label: {
                                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                                        .frame(width: 12)
                                }
                                .buttonStyle(.borderless)
                            } else {
                                Color.clear.frame(width: 12, height: 1)
                            }
                            label(row)
                        }
                        .help(row.detail.isEmpty ? row.title : "\(row.title)  \(row.detail)")
                    }
                    TableColumn("Shallow") { row in
                        Text(row.shallow.map { IDEHeapDumpView.bytes($0) } ?? "")
                            .font(IDEAppearance.Typography.monoSmall)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 60, ideal: 76, max: 110)
                    TableColumn("Retained") { row in
                        Text(row.object == nil && row.shallow == nil ? "" : IDEHeapDumpView.bytes(row.retained))
                            .font(IDEAppearance.Typography.monoSmall)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 60, ideal: 84, max: 120)
                    TableColumn("% of Live") { row in
                        if row.object != nil {
                            let share = Double(row.retained) / Double(total)
                            HStack(spacing: IDEAppearance.Spacing.xs) {
                                Text(String(format: "%.1f%%", share * 100))
                                    .font(IDEAppearance.Typography.monoSmall)
                                    .frame(width: 48, alignment: .trailing)
                                IDEHeapShareBar(share: share)
                            }
                        }
                    }
                    .width(min: 90, ideal: 130, max: 180)
                }
                .contextMenu(forSelectionType: IDEHeapDominatorRow.ID.self) { ids in
                    if let row = objects.dominatorRows.first(where: { $0.id == ids.first }) {
                        if row.childCount > 0 { Button(row.isExpanded ? "Collapse" : "Expand") { objects.toggle(row) } }
                        if row.object != nil {
                            Button("Show Path to GC Roots") { objects.inspectorTab = .path }
                            Button("Show What It Retains") { objects.inspectorTab = .retains }
                        }
                    }
                } primaryAction: { ids in
                    guard let row = objects.dominatorRows.first(where: { $0.id == ids.first }) else { return }
                    if case .more = row.kind { objects.showMore(row) } else if row.childCount > 0 { objects.toggle(row) }
                }
                Divider()
                Text("Each object keeps alive what is listed under it: freeing it frees its retained size. Double-click to expand.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, IDEAppearance.Spacing.sm)
                    .padding(.vertical, IDEAppearance.Spacing.xs)
            }
        }
    }

    @ViewBuilder
    private func label(_ row: IDEHeapDominatorRow) -> some View {
        switch row.kind {
        case .more:
            Button(row.title) { objects.showMore(row) }
                .buttonStyle(.link)
                .font(IDEAppearance.Typography.caption)
        case .unreachable, .unreachableClass, .weaklyReachable, .weaklyReachableClass:
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text(row.title)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Text(row.detail)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            .lineLimit(1)
        case .object:
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text(row.title)
                    .font(IDEAppearance.Typography.monoSmall)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Text(row.detail)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

/// The Summary's list of the objects that keep the most alive.
struct IDEHeapBiggestObjectsCard: View {
    let session: IDEHeapDumpSession
    let index: HeapIndex

    var body: some View {
        let top = index.dominatorChildren(of: 0, range: 0..<5)
        let total = max(index.reachableBytes, 1)
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text("Biggest Objects by Retained Size")
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            ForEach(top, id: \.self) { n in
                Button {
                    session.mode = .dominators
                    session.objects.inspect(n, startingOver: true)
                } label: {
                    HStack(spacing: IDEAppearance.Spacing.sm) {
                        Text(index.title(of: n))
                            .font(IDEAppearance.Typography.monoSmall)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: IDEAppearance.Spacing.sm)
                        Text(IDEHeapDumpView.bytes(index.retainedSize(of: n)))
                            .font(IDEAppearance.Typography.monoSmall)
                            .frame(width: 80, alignment: .trailing)
                        Text(String(format: "%.1f%%", Double(index.retainedSize(of: n)) / Double(total) * 100))
                            .font(IDEAppearance.Typography.monoSmall)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                            .frame(width: 52, alignment: .trailing)
                        IDEHeapShareBar(share: Double(index.retainedSize(of: n)) / Double(total))
                            .frame(width: 80)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Inspect in the Dominators view")
            }
        }
        .padding(IDEAppearance.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.card, in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.card))
    }
}

/// `IDEHeapMergedPaths` as a sheet item.
struct IDEHeapMergedPathsBox: Identifiable {
    let paths: IDEHeapMergedPaths
    var id: String { paths.className }
}

/// A class's instances' paths to GC roots, merged from the root side: where they are held from.
struct IDEHeapMergedPathsSheet: View {
    let objects: IDEHeapObjectExplorer
    let paths: IDEHeapMergedPaths
    @Environment(\.dismiss) private var dismiss
    @State private var selection: IDEHeapMergedPaths.Row.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shortest Paths to GC Roots")
                        .font(IDEAppearance.Typography.titlebarTitle)
                    Text("\(paths.className): \(paths.objectCount.formatted()) instances (the ones retaining most), merged from the roots down")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(IDEAppearance.Spacing.md)
            Divider()
            Table(paths.rows, selection: $selection) {
                TableColumn("Object") { row in
                    HStack(spacing: IDEAppearance.Spacing.xs) {
                        Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
                        Image(systemName: row.depth == 0 ? "anchor" : (row.isTarget ? "smallcircle.filled.circle" : "arrow.down.right"))
                            .foregroundStyle(row.depth == 0 ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.muted)
                            .frame(width: 14)
                        Text(row.title)
                            .font(IDEAppearance.Typography.monoSmall)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                TableColumn("Instances Through It") { row in
                    Text(row.count.formatted())
                        .font(IDEAppearance.Typography.monoSmall)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 90, ideal: 130, max: 160)
            }
            .contextMenu(forSelectionType: IDEHeapMergedPaths.Row.ID.self) { _ in
            } primaryAction: { ids in
                guard let row = paths.rows.first(where: { $0.id == ids.first }) else { return }
                objects.inspect(row.object, startingOver: true)
                dismiss()
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(IDEAppearance.ColorToken.editor)
    }
}
