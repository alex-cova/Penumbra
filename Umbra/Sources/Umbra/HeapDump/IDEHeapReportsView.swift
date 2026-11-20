import AppKit
import JavaIntelligence
import SwiftUI

// MARK: - Reports

/// Leak suspects (after Eclipse MAT) and the inspections, with the inspector beside them: every
/// object a report names opens there.
struct IDEHeapReportsView: View {
    let session: IDEHeapDumpSession

    private var objects: IDEHeapObjectExplorer { session.objects }

    var body: some View {
        IDEHeapIndexGate(objects: objects) {
            SplitPanes(minPrimary: 420, minSecondary: 320, defaultFraction: 0.6, storageKey: "umbra.heapDump.reports.split") {
                ScrollView {
                    VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
                        sectionTitle("Leak Suspects")
                        suspects
                        sectionTitle("Inspections")
                        inspections
                    }
                    .padding(IDEAppearance.Spacing.lg)
                    .frame(maxWidth: 900, alignment: .leading)
                }
            } secondary: {
                IDEHeapInspectorView(session: session)
            }
            .onAppear { objects.loadInspectionsIfNeeded() }
        }
    }

    @ViewBuilder
    private var suspects: some View {
        if let suspects = objects.suspects {
            if suspects.isEmpty {
                IDEHeapReportCard {
                    Text("No single object, and no class's instances together, keep 10 % or more of the live heap.")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            } else {
                ForEach(Array(suspects.enumerated()), id: \.element.id) { position, suspect in
                    IDEHeapSuspectCard(objects: objects, number: position + 1, suspect: suspect)
                }
            }
        } else {
            IDEHeapReportCard { IDEHeapReportLoading(text: "Looking for what keeps the most memory alive…") }
        }
    }

    @ViewBuilder
    private var inspections: some View {
        if let error = objects.inspectionError {
            IDEHeapReportCard {
                Text(error)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
            }
        } else if objects.isLoadingInspections || objects.duplicateStrings == nil {
            IDEHeapReportCard { IDEHeapReportLoading(text: "Checking strings, collections and arrays…") }
        } else {
            if let strings = objects.duplicateStrings { duplicateStrings(strings) }
            if let collections = objects.wastedCollections { wastedCollections(collections) }
            if let zeros = objects.zeroArrays { zeroArrays(zeros) }
        }
    }

    private func duplicateStrings(_ report: HeapDuplicateStrings) -> some View {
        IDEHeapReportCard {
            IDEHeapReportHeader(
                title: "Duplicate Strings", bytes: report.wastedBytes,
                detail: "\(report.stringCount.formatted()) live strings hold \(report.distinctCount.formatted()) distinct texts. Copies beyond the first cost the bytes shown."
            )
            ForEach(report.groups.prefix(20)) { group in
                IDEHeapReportRow(
                    title: HeapValueFormatterBridge.quoted(group.text), count: group.count, bytes: group.wastedBytes,
                    help: "Inspect one copy"
                ) { objects.inspect(group.example, startingOver: true) }
            }
        }
    }

    private func wastedCollections(_ report: HeapWastedCollections) -> some View {
        IDEHeapReportCard {
            IDEHeapReportHeader(
                title: "Empty and Sparse Collections", bytes: report.wastedBytes,
                detail: "Collections with an allocated array and no elements, or using under a quarter of their array."
            )
            if report.rows.isEmpty {
                Text("None found.").font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            ForEach(report.rows) { row in
                IDEHeapReportRow(title: "\(row.className) (\(row.problem))", count: row.count, bytes: row.wastedBytes, help: "Inspect an example") {
                    if let example = row.examples.first { objects.inspect(example, startingOver: true) }
                }
            }
        }
    }

    private func zeroArrays(_ report: HeapZeroArrays) -> some View {
        IDEHeapReportCard {
            IDEHeapReportHeader(
                title: "Arrays of Zeros", bytes: report.bytes,
                detail: "Live primitive arrays of 1 KB or more that hold nothing but zeros: buffers allocated and never filled."
            )
            if report.rows.isEmpty {
                Text("None found.").font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            ForEach(report.rows) { row in
                IDEHeapReportRow(title: row.className, count: row.count, bytes: row.bytes, help: "Inspect the largest") {
                    if let example = row.examples.first { objects.inspect(example, startingOver: true) }
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(IDEAppearance.Typography.titlebarTitle)
            .padding(.top, IDEAppearance.Spacing.xs)
    }
}

/// `HeapValueFormatter.quoted` is internal to the library; the same escaping for display.
enum HeapValueFormatterBridge {
    static func quoted(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
        if cleaned.count > 100 { cleaned = String(cleaned.prefix(100)) + "…" }
        return "\"\(cleaned)\""
    }
}

/// One problem suspect: its share of the live heap, MAT's sentence, the accumulation point and the
/// classes it keeps alive.
struct IDEHeapSuspectCard: View {
    let objects: IDEHeapObjectExplorer
    let number: Int
    let suspect: HeapLeakSuspect

    var body: some View {
        IDEHeapReportCard {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                Text("Problem Suspect \(number)")
                    .font(IDEAppearance.Typography.sectionHeader)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: suspect.retainedBytes, countStyle: .memory))
                    .font(IDEAppearance.Typography.monoSmall)
                Text(String(format: "%.1f%%", suspect.share * 100))
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                IDEHeapShareBar(share: suspect.share).frame(width: 100)
            }
            Text(suspect.summary)
                .font(IDEAppearance.Typography.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: IDEAppearance.Spacing.sm) {
                if let object = suspect.object {
                    Button(suspect.kind == .object ? "Inspect" : "Inspect the Largest") {
                        objects.inspectorTab = .fields
                        objects.inspect(object, startingOver: true)
                    }
                    Button("Path to GC Root") {
                        objects.inspectorTab = .path
                        objects.inspect(object, startingOver: true)
                    }
                }
                if let accumulation = suspect.accumulation {
                    Button("Inspect Accumulation Point") {
                        objects.inspectorTab = .fields
                        objects.inspect(accumulation, startingOver: true)
                    }
                }
            }
            .controlSize(.small)
            if !suspect.biggestClasses.isEmpty {
                Text("Biggest classes it keeps alive")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .padding(.top, IDEAppearance.Spacing.xs)
                ForEach(suspect.biggestClasses) { total in
                    HStack {
                        Text(total.name).font(IDEAppearance.Typography.monoSmall).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: IDEAppearance.Spacing.sm)
                        Text(total.count.formatted()).font(IDEAppearance.Typography.monoSmall).foregroundStyle(IDEAppearance.ColorToken.muted)
                        Text(ByteCountFormatter.string(fromByteCount: total.bytes, countStyle: .memory))
                            .font(IDEAppearance.Typography.monoSmall)
                            .frame(width: 80, alignment: .trailing)
                    }
                }
            }
        }
    }
}

struct IDEHeapReportCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) { content() }
            .padding(IDEAppearance.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IDEAppearance.ColorToken.card, in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.card))
    }
}

struct IDEHeapReportHeader: View {
    let title: String
    let bytes: Int64
    let detail: String

    var body: some View {
        HStack {
            Text(title).font(IDEAppearance.Typography.sectionHeader)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory) + " wasted")
                .font(IDEAppearance.Typography.monoSmall)
        }
        Text(detail)
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct IDEHeapReportRow: View {
    let title: String
    let count: Int
    let bytes: Int64
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Text(title)
                    .font(IDEAppearance.Typography.monoSmall)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: IDEAppearance.Spacing.sm)
                Text("×\(count.formatted())")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory))
                    .font(IDEAppearance.Typography.monoSmall)
                    .frame(width: 80, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct IDEHeapReportLoading: View {
    let text: String

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }
}

// MARK: - Threads

/// The threads at the moment of the dump: what each retains, its stack with the locals of each
/// frame, and the inspector for the thread or the picked local.
struct IDEHeapThreadsView: View {
    let session: IDEHeapDumpSession

    private var objects: IDEHeapObjectExplorer { session.objects }

    var body: some View {
        IDEHeapIndexGate(objects: objects) {
            SplitPanes(minPrimary: 300, minSecondary: 380, defaultFraction: 0.38, storageKey: "umbra.heapDump.threads.split") {
                threadList
            } secondary: {
                SplitPanes(axis: .vertical, minPrimary: 140, minSecondary: 160, defaultFraction: 0.5, storageKey: "umbra.heapDump.threads.stack") {
                    stack
                } secondary: {
                    IDEHeapInspectorView(session: session)
                }
            }
            .onAppear { objects.loadThreadsIfNeeded() }
        }
    }

    @ViewBuilder
    private var threadList: some View {
        @Bindable var objects = objects
        if let threads = objects.threads {
            if threads.isEmpty {
                IDEHeapPaneMessage(text: "The dump records no threads.")
            } else {
                Table(threads, selection: $objects.selectedThread) {
                    TableColumn("Thread") { row in
                        Text(row.name).font(IDEAppearance.Typography.monoSmall).lineLimit(1).truncationMode(.middle)
                    }
                    TableColumn("State") { row in
                        Text(row.state)
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(row.state == "BLOCKED" ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
                    }
                    .width(min: 60, ideal: 96, max: 120)
                    TableColumn("Retained") { row in
                        Text(ByteCountFormatter.string(fromByteCount: row.retained, countStyle: .memory))
                            .font(IDEAppearance.Typography.monoSmall)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 60, ideal: 76, max: 110)
                    TableColumn("Frames") { row in
                        Text(row.frames.count.formatted())
                            .font(IDEAppearance.Typography.monoSmall)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 40, ideal: 50, max: 70)
                }
            }
        } else {
            IDEHeapPaneMessage(text: "Reading the threads…", progress: true)
        }
    }

    @ViewBuilder
    private var stack: some View {
        @Bindable var objects = objects
        if objects.selectedThread == nil {
            IDEHeapPaneMessage(text: "Select a thread to see its stack and the objects its frames hold.")
        } else if objects.stackRows.isEmpty {
            IDEHeapPaneMessage(text: "No stack was recorded for this thread.")
        } else {
            Table(objects.stackRows, selection: $objects.selectedStackRow) {
                TableColumn("Stack (innermost first) and Locals") { row in
                    HStack(spacing: IDEAppearance.Spacing.xs) {
                        if row.local != nil {
                            Color.clear.frame(width: 18, height: 1)
                            Image(systemName: "arrow.turn.down.right")
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                        }
                        Text(row.text)
                            .font(IDEAppearance.Typography.monoSmall)
                            .foregroundStyle(row.local == nil ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.accent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(row.text)
                }
            }
            .contextMenu(forSelectionType: IDEHeapStackRow.ID.self) { ids in
                Button("Copy Stack") {
                    let text = objects.stackRows.filter { $0.local == nil }.map(\.text).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
    }
}
