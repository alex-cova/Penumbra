import AppKit
import DatabaseKit
import SwiftUI
import XCTest

@testable import Umbra

/// Display frame timing of the result grid, against the grid it replaced.
///
/// A real window is scrolled through a scripted path. After each step the window is displayed
/// synchronously and the time that took is one *frame cost*: the main-thread work to lay out the
/// rows that scrolled in, configure their cells and draw. Between steps the run waits one 60 Hz
/// interval, which lets the current grid's background viewport read land, and counts the cells
/// still showing the "Loading…" placeholder at the moment a frame is drawn. These need a window
/// server (`UMBRA_UI_TESTS=1`), and Debug numbers are only an upper bound.
@MainActor
final class IDEDatabaseGridFrameTimingTests: XCTestCase {
    private static let columnCount = 40

    /// The grid Umbra shipped before the stored-result viewport, kept verbatim as a baseline: one
    /// page of `[[String?]]` rows, a table-wide `reloadData`, a text field per cell.
    private struct LegacyGrid: NSViewRepresentable {
        var columns: [String]
        var rows: [[String?]]

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSScrollView {
            let table = NSTableView()
            table.style = .plain
            table.usesAlternatingRowBackgroundColors = true
            table.columnAutoresizingStyle = .noColumnAutoresizing
            table.allowsColumnResizing = true
            table.gridStyleMask = [.solidVerticalGridLineMask]
            table.backgroundColor = .clear
            table.delegate = context.coordinator
            table.dataSource = context.coordinator
            table.rowHeight = 20
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.drawsBackground = false
            context.coordinator.table = table
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            context.coordinator.rows = rows
            guard let table = context.coordinator.table else { return }
            if context.coordinator.columnNames != columns {
                context.coordinator.columnNames = columns
                while !table.tableColumns.isEmpty { table.removeTableColumn(table.tableColumns[0]) }
                for (index, name) in columns.enumerated() {
                    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
                    column.title = name
                    column.width = 140
                    column.minWidth = 60
                    table.addTableColumn(column)
                }
            }
            table.reloadData()
        }

        final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
            var columnNames: [String] = []
            var rows: [[String?]] = []
            weak var table: NSTableView?

            func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

            func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
                let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("")
                let index = Int(identifier.rawValue.dropFirst()) ?? 0
                let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField)
                    ?? NSTextField(labelWithString: "")
                cell.identifier = identifier
                cell.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                cell.lineBreakMode = .byTruncatingTail
                let value = row < rows.count && rows[row].indices.contains(index) ? rows[row][index] : nil
                cell.stringValue = value ?? "NULL"
                cell.textColor = value == nil ? .secondaryLabelColor : .labelColor
                return cell
            }
        }
    }

    private struct Report {
        var frameMilliseconds: [Double] = []
        var placeholderFrames = 0
        var placeholderCells = 0
        var visibleCells = 0
        /// Placeholder frames by phase of the path: vertical, horizontal, jumps.
        var placeholderFramesByPhase = [0, 0, 0]

        func percentile(_ fraction: Double) -> Double {
            let sorted = frameMilliseconds.sorted()
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
        }

        func line(_ name: String) -> String {
            String(format: "DATABASE_GRID_FRAMES %@ frames=%d p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms over16.7ms=%d placeholderFrames=%d (vertical %d, horizontal %d, jumps %d) placeholderCells=%d/%d",
                   name, frameMilliseconds.count, percentile(0.5), percentile(0.95), percentile(0.99),
                   frameMilliseconds.max() ?? 0, frameMilliseconds.filter { $0 > 16.7 }.count,
                   placeholderFrames, placeholderFramesByPhase[0], placeholderFramesByPhase[1], placeholderFramesByPhase[2],
                   placeholderCells, visibleCells)
        }
    }

    private func window<Content: View>(_ content: Content) throws -> (NSWindow, NSScrollView, NSTableView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 480), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 1_000, height: 480)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for child in view.subviews { if let match = find(type, in: child) { return match } }
            return nil
        }
        let scroll = try XCTUnwrap(find(NSScrollView.self, in: host))
        let table = try XCTUnwrap(find(NSTableView.self, in: host))
        window.displayIfNeeded()
        return (window, scroll, table)
    }

    private func placeholderCount(_ table: NSTableView) -> (placeholders: Int, visible: Int) {
        let rows = table.rows(in: table.visibleRect)
        let columns = table.columnIndexes(in: table.visibleRect)
        var placeholders = 0
        var visible = 0
        for row in rows.lowerBound..<rows.upperBound {
            for column in columns {
                guard let field = table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTextField else { continue }
                visible += 1
                if field.stringValue == "Loading…" { placeholders += 1 }
            }
        }
        return (placeholders, visible)
    }

    /// The scripted path: smooth vertical scrolling, smooth horizontal scrolling, then jumps.
    private func scroll(
        _ window: NSWindow, _ scroll: NSScrollView, _ table: NSTableView, verticalSteps: Int
    ) async throws -> Report {
        var report = Report()
        let clip = scroll.contentView
        let maxY = max(0, table.frame.height - clip.bounds.height)
        let maxX = max(0, table.frame.width - clip.bounds.width)
        var targets: [NSPoint] = []
        for step in 0..<verticalSteps { targets.append(NSPoint(x: 0, y: min(maxY, Double(step) * 40))) }
        for step in 0..<80 { targets.append(NSPoint(x: min(maxX, Double(step) * 60), y: targets.last?.y ?? 0)) }
        for (fractionX, fractionY) in [(0.9, 0.9), (0.1, 0.5), (0.6, 0.05), (0.3, 0.8), (0.0, 0.0)] {
            targets.append(NSPoint(x: maxX * fractionX, y: maxY * fractionY))
        }
        for (index, target) in targets.enumerated() {
            let phase = index < verticalSteps ? 0 : index < verticalSteps + 80 ? 1 : 2
            clip.scroll(to: target)
            scroll.reflectScrolledClipView(clip)
            let start = ContinuousClock.now
            window.displayIfNeeded()
            let elapsed = start.duration(to: .now).components
            report.frameMilliseconds.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
            let counts = placeholderCount(table)
            report.visibleCells += counts.visible
            report.placeholderCells += counts.placeholders
            if counts.placeholders > 0 {
                report.placeholderFrames += 1
                report.placeholderFramesByPhase[phase] += 1
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        return report
    }

    private func requireWindowServer() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_UI_TESTS"] == "1", "needs a window server (UMBRA_UI_TESTS=1)")
    }

    func testStoredResultGridFrameCostsAgainstTheOriginalGrid() async throws {
        try requireWindowServer()
        let names = (0..<Self.columnCount).map { "column_\($0)" }

        // The original grid could only show one page, so it is measured on 200 rows.
        let page = (0..<200).map { row in names.indices.map { Optional("\(row):\($0) value") } }
        let (legacyWindow, legacyScroll, legacyTable) = try window(LegacyGrid(columns: names, rows: page))
        let legacy = try await scroll(legacyWindow, legacyScroll, legacyTable, verticalSteps: 90)
        legacyWindow.close()

        // The current grid on the same 200 rows, then on 100,000 that the old grid could not show.
        var current: [(String, Report)] = []
        for rows in [200, 100_000] {
            let storage = IDEDatabaseResultStorage()
            for start in stride(from: 0, to: rows, by: 1_000) {
                try await storage.store.append((start..<min(rows, start + 1_000)).map { row in
                    names.indices.map { .text("\(row):\($0) value") }
                })
            }
            let grid = IDEDatabaseResultGrid(storage: storage, columns: names, rowCount: rows, canSort: false,
                                             onSort: { _ in }, onInspect: { _, _ in })
            let (window, scrollView, table) = try window(grid)
            // Let the first viewport arrive before the path starts, as a user would.
            try await Task.sleep(for: .milliseconds(300))
            current.append(("\(rows)rows", try await self.scroll(window, scrollView, table, verticalSteps: rows == 200 ? 90 : 300)))
            window.close()
            await storage.store.close()
        }

        print(legacy.line("original-200rows"))
        for (name, report) in current { print(report.line("viewport-\(name)")) }
        let rows200 = try XCTUnwrap(current.first?.1)
        let rows100k = try XCTUnwrap(current.last?.1)
        // A frame must stay far inside a 60 Hz budget even in Debug, and the size of the result must not matter.
        XCTAssertLessThan(rows100k.percentile(0.95), 50, "Debug upper bound; the release figure is what the budget uses")
        XCTAssertLessThan(rows100k.percentile(0.5), max(rows200.percentile(0.5) * 3, 8),
                          "Work per frame is bounded by what is visible, not by the number of rows")
        // Smooth scrolling in either direction never shows a placeholder: the cache refills before the
        // viewport reaches its edge and refreshes every cached column, including the ones just off
        // screen. Only a jump to a region that was never loaded may.
        for report in [rows200, rows100k] {
            XCTAssertEqual(report.placeholderFramesByPhase[0], 0, "vertical scroll showed placeholders")
            XCTAssertEqual(report.placeholderFramesByPhase[1], 0, "horizontal scroll showed placeholders")
        }
    }
}
