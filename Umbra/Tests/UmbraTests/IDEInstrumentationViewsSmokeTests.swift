import AppKit
import JavaIntelligence
import SwiftUI
import XCTest
@testable import Umbra

/// Hosts the Coverage tab and the profiler in a window so a crash or an empty render shows up in the
/// test run. Set `UMBRA_VIEW_SNAPSHOTS` to a folder to keep the images.
@MainActor
final class IDEInstrumentationViewsSmokeTests: XCTestCase {
    private var workspace: IDEWorkspace!
    private var base: URL!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("instr-views-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.project.setRoot(base)
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: base)
    }

    private func render<Content: View>(_ view: Content, size: NSSize, name: String) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.environment(workspace).preferredColorScheme(.dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let folder = ProcessInfo.processInfo.environment["UMBRA_VIEW_SNAPSHOTS"],
           let png = rep.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
        return rep
    }

    private func ink(_ rep: NSBitmapImageRep) -> Double {
        var counts: [UInt32: Int] = [:]
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let key = UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8 | UInt32(color.blueComponent * 255)
                counts[key, default: 0] += 1
            }
        }
        let total = counts.values.reduce(0, +)
        guard total > 0, let common = counts.values.max() else { return 0 }
        return 1 - Double(common) / Double(total)
    }

    func testTheCoverageTabRendersEmptyBuildingAndWithAReport() throws {
        XCTAssertGreaterThan(ink(try render(IDECoveragePanel(), size: NSSize(width: 760, height: 260), name: "coverage-empty")), 0.001)
        workspace.coverage.beginReport(message: "Building the coverage report for “Calc”…")
        XCTAssertGreaterThan(ink(try render(IDECoveragePanel(), size: NSSize(width: 760, height: 260), name: "coverage-building")), 0.001)

        let report = try JaCoCoXMLReportParser.parse(
            contentsOf: InstrumentationFixtures.url("JavaCoverage", "calc-report.xml")
        )
        workspace.coverage.publish(IDECoverageSnapshot(
            report: report, runID: "r", label: "Calc", date: Date(), tasks: [], runDirectory: base,
            executionFiles: [], classDirectories: [], sourceDirectories: [],
            java: URL(fileURLWithPath: "/jdk/bin/java"), cliJar: URL(fileURLWithPath: "/jacococli.jar")
        ))
        XCTAssertGreaterThan(ink(try render(IDECoveragePanel(), size: NSSize(width: 760, height: 260), name: "coverage-report")), 0.01)
        let tab = IDECoverageTabItem(title: "Coverage · 70%", isSelected: true, onSelect: {})
        XCTAssertGreaterThan(ink(try render(tab, size: NSSize(width: 200, height: 30), name: "coverage-tab")), 0.001)
    }

    private func readyProfile() throws -> IDEProfilerSession {
        let session = IDEProfilerSession(recordings: [URL(fileURLWithPath: "/tmp/x.jfr")], title: "x.jfr")
        var parser = JFRTextParser()
        var profile = JavaProfile(symbols: parser.symbols)
        let text = try String(contentsOf: InstrumentationFixtures.url("JavaProfiling", "spin-print.txt"), encoding: .utf8)
        parser.parse(text) { profile.ingest($0) }
        session.installForTesting(profile: profile)
        return session
    }

    func testTheProfilerRendersEveryViewOfAReadyRecording() throws {
        let session = try readyProfile()
        for mode in IDEProfilerSession.Mode.allCases {
            session.mode = mode
            let rep = try render(IDEProfilerView(session: session), size: NSSize(width: 900, height: 420), name: "profiler-\(mode.rawValue)")
            XCTAssertGreaterThan(ink(rep), 0.01, mode.rawValue)
        }
        session.kind = .allocations
        session.mode = .flame
        XCTAssertGreaterThan(ink(try render(IDEProfilerView(session: session), size: NSSize(width: 900, height: 420), name: "profiler-alloc")), 0.01)
        session.kind = .gc
        XCTAssertGreaterThan(ink(try render(IDEProfilerView(session: session), size: NSSize(width: 900, height: 420), name: "profiler-gc")), 0.005)
    }

    func testTheTimelineAndFiltersOfAMixedRecordingRender() throws {
        let session = IDEProfilerSession(recordings: [URL(fileURLWithPath: "/tmp/mixed.jfr")], title: "mixed.jfr")
        var parser = JFRTextParser()
        var profile = JavaProfile(symbols: parser.symbols)
        let text = try String(contentsOf: InstrumentationFixtures.url("JavaProfiling", "mixed-print.txt"), encoding: .utf8)
        parser.parse(text) { profile.ingest($0) }
        session.installForTesting(profile: profile)

        session.mode = .timeline
        XCTAssertGreaterThan(ink(try render(IDEProfilerView(session: session), size: NSSize(width: 980, height: 460), name: "timeline")), 0.02)
        session.kind = .allocations
        XCTAssertGreaterThan(ink(try render(IDEProfilerView(session: session), size: NSSize(width: 980, height: 460), name: "timeline-heap")), 0.02)

        session.kind = .locks
        session.mode = .flame
        let span = try XCTUnwrap(session.timeline?.span)
        session.timeRange = span.lowerBound...(span.lowerBound + 800)
        XCTAssertGreaterThan(ink(try render(IDEProfilerView(session: session), size: NSSize(width: 980, height: 420), name: "waits-range")), 0.01)
        session.timeRange = nil
        session.kind = .cpu
        session.mode = .hot
        session.selectedMethod = session.hotMethods.first?.method
        XCTAssertGreaterThan(ink(try render(IDEProfilerView(session: session), size: NSSize(width: 980, height: 420), name: "methods-detail")), 0.01)
    }

    func testTheDifferentialViewsRender() throws {
        func load(_ name: String) throws -> JavaProfile {
            var parser = JFRTextParser()
            var profile = JavaProfile(symbols: parser.symbols)
            let text = try String(contentsOf: InstrumentationFixtures.url("JavaProfiling", name), encoding: .utf8)
            parser.parse(text) { profile.ingest($0) }
            return profile
        }
        let session = IDEProfilerSession(recordings: [URL(fileURLWithPath: "/tmp/mixed.jfr")], title: "mixed.jfr")
        session.installForTesting(profile: try load("mixed-print.txt"))
        session.setBaseline(IDEProfilerSession.BaselineCandidate(
            id: "b", title: "spin.jfr", subtitle: "", recordings: [], profile: try load("spin-print.txt")
        ))
        session.mode = .flame
        XCTAssertGreaterThan(ink(try render(IDEProfilerView(session: session), size: NSSize(width: 980, height: 420), name: "diff-flame")), 0.02)
        session.mode = .hot
        XCTAssertGreaterThan(ink(try render(IDEProfilerView(session: session), size: NSSize(width: 980, height: 420), name: "diff-methods")), 0.01)
        // The call tree carries the change per node: its numbers differ from the plain tree's.
        session.mode = .tree
        XCTAssertGreaterThan(ink(try render(IDEProfilerView(session: session), size: NSSize(width: 980, height: 420), name: "diff-tree")), 0.01)
        session.percentBase = .parent
        XCTAssertGreaterThan(ink(try render(IDEProfilerView(session: session), size: NSSize(width: 980, height: 420), name: "diff-tree-parent")), 0.01)
        session.addClassFilter(.jdk)
        session.classFilters = [.jdk, .libraries]
        XCTAssertGreaterThan(ink(try render(IDEProfilerView(session: session), size: NSSize(width: 980, height: 420), name: "diff-tree-hidden")), 0.01)
    }

    func testTheLiveChartsRenderWithReadingsAndWithoutAny() throws {
        let session = IDEProfilerSession(recordings: [], title: "Spin", runID: "r1")
        let monitor = IDEProfilerLiveMonitor(
            runID: "r1", jcmd: nil, jps: nil, snapshotDirectory: base, knownProcessID: nil
        )
        session.beginLive(monitor: monitor)
        monitor.stop()
        XCTAssertEqual(session.phase, .live)
        XCTAssertGreaterThan(ink(try render(IDEProfilerView(session: session), size: NSSize(width: 900, height: 600), name: "live-waiting")), 0.001)

        let samples = (0..<90).map { second -> IDEProfilerLiveMonitor.Sample in
            let wave = sin(Double(second) / 8)
            return IDEProfilerLiveMonitor.Sample(
                id: second, seconds: Double(second), cpuPercent: 60 + 40 * wave, residentBytes: 300_000_000,
                osThreads: 20, heapUsedBytes: Int((120 + 80 * wave) * 1_048_576), heapCommittedBytes: 256 * 1_048_576,
                heapMaxBytes: 1_024 * 1_048_576, metaspaceUsedBytes: (40 + second / 10) * 1_048_576,
                liveThreads: 12 + second / 20, daemonThreads: 9
            )
        }
        monitor.installForTesting(samples: samples, status: .attached(pid: 4242), notice: nil)
        XCTAssertGreaterThan(ink(try render(IDEProfilerView(session: session), size: NSSize(width: 900, height: 600), name: "live-charts")), 0.01)
        monitor.installForTesting(samples: samples, status: .ended, notice: "The JVM does not accept jcmd, so only CPU and memory are shown.")
        XCTAssertGreaterThan(ink(try render(IDEProfilerView(session: session), size: NSSize(width: 900, height: 600), name: "live-ended")), 0.01)

        session.failLive("No recording was written.")
        XCTAssertEqual(session.phase, .failed("No recording was written."))
    }

    func testTheProfilerExplainsEachNonReadyPhase() throws {
        let session = IDEProfilerSession(recordings: [], title: "x")
        for phase: IDEProfilerSession.Phase in [
            .summarizing, .reading(lines: 12_000), .failed("Unsupported chunk version 99"), .needsJDK, .needsConfirmation(megabytes: 900)
        ] {
            session.setPhaseForTesting(phase)
            XCTAssertGreaterThan(ink(try render(IDEProfilerView(session: session), size: NSSize(width: 700, height: 300), name: "profiler-phase")), 0.001)
        }
    }
}

extension IDEProfilerSession {
    func installForTesting(profile: JavaProfile) {
        setProfileForTesting(profile)
    }
}
