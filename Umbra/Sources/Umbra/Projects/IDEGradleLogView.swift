import AppKit
import JavaIntelligence
import SwiftUI

/// A bounded text viewport over the disk-backed byte log. The byte position stays stable while
/// new output arrives when auto-follow is paused.
struct IDEGradleLogView: View {
    let log: GradleSessionLog
    let notes: [String]
    let fontName: String
    let fontSize: Double
    let isVisible: Bool

    @State private var end: UInt64 = 0
    @State private var anchoredEnd: UInt64?
    @State private var start: UInt64 = 0
    @State private var follow = true
    @State private var query = ""
    @State private var match: Range<UInt64>?
    @State private var searchStatus: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var loaded = IDEProjectConsoleLog()

    private static let window: UInt64 = 16 * 1024

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                IDEIconButton(systemImage: "chevron.left", help: "Previous Log Page", action: previousPage)
                    .disabled(start == 0)
                IDEIconButton(systemImage: "chevron.right", help: "Next Log Page", action: nextPage)
                    .disabled(start + Self.window >= end)
                Toggle("Follow Tail", isOn: $follow).toggleStyle(.checkbox)
                TextField("Search log", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .onSubmit(findNext)
                    .onChange(of: query) { _, _ in
                        match = nil
                        searchStatus = nil
                        searchTask?.cancel()
                    }
                IDEIconButton(systemImage: "magnifyingglass", help: "Find Next in Full Log", action: findNext)
                    .disabled(query.isEmpty)
                IDEIconButton(systemImage: "square.and.arrow.up", help: "Export Full Gradle Log", action: exportLog)
                Text(searchStatus ?? "Byte \(start.formatted()) of \(end.formatted())")
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Spacer(minLength: 0)
            }
            .font(IDEAppearance.Typography.caption)
            .ideIconButtonSize(.compact)
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            Divider()
            IDEProjectConsoleView(log: loaded, fontName: fontName, fontSize: fontSize) {
                if follow { follow = false }
            }
        }
        .task(id: isVisible ? ObjectIdentifier(log) : nil) {
            guard isVisible else { return }
            await followLog()
        }
        .task(id: visiblePage) {
            guard let page = visiblePage else { return }
            let old = loaded
            let lines = await Self.readPage(log, page)
            guard !Task.isCancelled else { return }
            var next = old
            next.reset()
            if page.start == 0 { next.appendNotes(page.notes.prefix(3)) }
            for line in lines { next.appendProcessLine(line) }
            if page.end == end { next.appendNotes(page.notes.dropFirst(3)) }
            loaded = next
        }
        .onChange(of: ObjectIdentifier(log)) { _, _ in
            start = 0
            end = 0
            follow = true
            anchoredEnd = nil
            match = nil
            searchStatus = nil
            searchTask?.cancel()
            loaded.reset()
        }
        .onChange(of: follow) { _, following in anchoredEnd = following ? nil : end }
        .onDisappear { searchTask?.cancel() }
    }

    private var pageEnd: UInt64 { min(start + Self.window, max(anchoredEnd ?? end, start)) }
    private var visiblePage: Page? {
        isVisible ? Page(logID: ObjectIdentifier(log), start: start, end: pageEnd, notes: notes) : nil
    }

    private func followLog() async {
        while !Task.isCancelled {
            let bytes = log.snapshot.bytes
            if bytes != end { end = bytes }
            if follow {
                let tailStart = bytes > Self.window ? bytes - Self.window : 0
                if start != tailStart { start = tailStart }
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
    }

    private func previousPage() {
        follow = false
        anchoredEnd = end
        start = start > Self.window ? start - Self.window : 0
    }

    private func nextPage() {
        follow = false
        anchoredEnd = end
        start = min(start + Self.window, max(end, Self.window) - Self.window)
    }

    private func findNext() {
        searchTask?.cancel()
        let request = query
        let from = match?.upperBound ?? 0
        searchStatus = "Searching…"
        searchTask = Task {
            do {
                let result = try await Self.search(log, request, from: from)
                guard !Task.isCancelled else { return }
                match = result
                if let result {
                    follow = false
                    anchoredEnd = end
                    start = result.lowerBound
                    searchStatus = "Match at byte \(result.lowerBound.formatted())"
                } else {
                    searchStatus = "No further matches"
                }
            } catch is CancellationError {
                return
            } catch {
                searchStatus = error.localizedDescription
            }
        }
    }

    private func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "gradle.log"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await Self.export(log, url)
                    searchStatus = "Exported \(url.lastPathComponent)"
                } catch {
                    searchStatus = error.localizedDescription
                }
            }
        }
    }

    private struct Page: Equatable {
        let logID: ObjectIdentifier
        let start: UInt64
        let end: UInt64
        let notes: [String]
    }

    @concurrent private static func readPage(_ log: GradleSessionLog, _ page: Page) async -> [IDEProjectOutputLine] {
        guard let chunks = try? log.read(page.start..<page.end) else {
            return [IDEProjectOutputLine(stream: .stderr, text: "Could not read the Gradle log.")]
        }
        var stdout = DisplayDecoder()
        var stderr = DisplayDecoder()
        var lines: [IDEProjectOutputLine] = []
        for (stream, data) in chunks {
            let rendered: [String]
            if stream == .stdout { rendered = stdout.append(data) } else { rendered = stderr.append(data) }
            for line in rendered {
                lines.append(IDEProjectOutputLine(stream: stream == .stdout ? .stdout : .stderr, text: line))
            }
        }
        if let line = stdout.finish() { lines.append(IDEProjectOutputLine(stream: .stdout, text: line)) }
        if let line = stderr.finish() { lines.append(IDEProjectOutputLine(stream: .stderr, text: line)) }
        return lines
    }

    @concurrent private static func search(_ log: GradleSessionLog, _ query: String, from: UInt64) async throws -> Range<UInt64>? {
        try log.find(query, from: from)
    }

    @concurrent private static func export(_ log: GradleSessionLog, _ url: URL) async throws {
        try log.export(to: url)
    }

    private struct DisplayDecoder {
        enum Escape { case none, start, csi, osc, oscEnd }
        var escape = Escape.none
        var line = Data()
        var returned = false

        mutating func append(_ bytes: Data) -> [String] {
            var lines: [String] = []
            for byte in bytes {
                switch escape {
                case .start:
                    escape = byte == 0x5B ? .csi : (byte == 0x5D ? .osc : .none)
                    continue
                case .csi:
                    if (0x40...0x7E).contains(byte) { escape = .none }
                    continue
                case .osc:
                    if byte == 0x07 { escape = .none }
                    if byte == 0x1B { escape = .oscEnd }
                    continue
                case .oscEnd:
                    escape = byte == 0x5C ? .none : .osc
                    continue
                case .none:
                    break
                }
                if byte == 0x1B { escape = .start; continue }
                if byte == 0x0D { returned = true; continue }
                if byte == 0x0A {
                    lines.append(String(decoding: line, as: UTF8.self))
                    line.removeAll(keepingCapacity: true)
                } else {
                    if returned { line.removeAll(keepingCapacity: true) }
                    if line.count >= 4096, byte & 0xC0 != 0x80 {
                        lines.append(String(decoding: line, as: UTF8.self))
                        line.removeAll(keepingCapacity: true)
                    }
                    line.append(byte)
                }
                returned = false
            }
            return lines
        }

        func finish() -> String? { line.isEmpty ? nil : String(decoding: line, as: UTF8.self) }
    }
}

private extension IDEProjectConsoleLog {
    mutating func appendNotes(_ notes: some Sequence<String>) {
        for note in notes { appendNote(note) }
    }
}
