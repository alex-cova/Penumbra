import EditorIntelligence
import Foundation
import XCTest

/// The checks from `docs/LANGUAGE_PARITY_PLAN.md` that do not need a live editor: a foreign language
/// gets nothing, a cancelled request returns promptly and is never delivered, `stop` drops what
/// `start` took, environment work during `start` and `stop` stays off the main actor, and the
/// capability report only names features the service actually provides.
enum LanguageServiceConformance {
    static func check(
        _ service: any LanguageService,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let registry = LanguageServiceRegistry(services: [service])
        for identifier in service.languageIdentifiers {
            let report = registry.capabilities(for: identifier)
            for feature in report.features.keys {
                XCTAssertFalse(
                    service.unavailableFeatures.contains(feature),
                    "\(service.name) reports \(feature) while it is unavailable",
                    file: file, line: line
                )
            }
        }
        let foreign = registry.capabilities(for: "language-service-conformance-foreign")
        XCTAssertTrue(foreign.features.isEmpty, "\(service.name) answered a language it does not claim", file: file, line: line)

        await checkCancellation(service, file: file, line: line)
        await checkStopReleasesTheEnvironment(service, file: file, line: line)
        await checkMainActor(service, file: file, line: line)
    }

    /// The request is cancelled before it can finish. It must return within a second, and the
    /// value it returns while cancelled is not a result (`false`).
    private static func checkCancellation(
        _ service: any LanguageService,
        file: StaticString,
        line: UInt
    ) async {
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task { await service.cancellableRequest() }
        task.cancel()
        let produced = await task.value
        let elapsed = started.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .seconds(1), "\(service.name) did not return from a cancelled request", file: file, line: line)
        XCTAssertTrue(task.isCancelled, file: file, line: line)
        XCTAssertFalse(produced, "\(service.name) delivered a result from a cancelled request", file: file, line: line)
    }

    /// The closures passed to `start` are the only owners of a probe. After `stop` the probe is gone.
    private static func checkStopReleasesTheEnvironment(
        _ service: any LanguageService,
        file: StaticString,
        line: UInt
    ) async {
        let slot = WeakSlot()
        do {
            let probe = Probe()
            slot.probe = probe
            let environment = LanguageEnvironment(
                openBufferText: { [probe] _ in
                    _ = probe
                    return nil
                },
                indentUnit: { [probe] in
                    _ = probe
                    return "    "
                },
                hasConsent: { [probe] _ in
                    _ = probe
                    return false
                },
                requestConsent: { [probe] _ in
                    _ = probe
                    return false
                },
                publishDiagnostics: { [probe] _ in
                    _ = probe
                }
            )
            await service.start(environment: environment)
        }
        await service.stop()
        XCTAssertNil(slot.probe, "\(service.name) kept the environment after stop()", file: file, line: line)
    }

    /// `start` and `stop` run off the main actor, and so does a read of the environment from there.
    /// `projectDidChange`, `filesDidChange` and `documentsDidSave` are the hooks that run on it.
    private static func checkMainActor(
        _ service: any LanguageService,
        file: StaticString,
        line: UInt
    ) async {
        let box = MainActorBox()
        await Task.detached {
            let environment = LanguageEnvironment(
                openBufferText: { _ in
                    if onMainThread() { box.markRequest() }
                    return nil
                },
                indentUnit: {
                    if onMainThread() { box.markRequest() }
                    return "    "
                },
                publishDiagnostics: { _ in
                    if onMainThread() { box.markRequest() }
                }
            )
            if onMainThread() { box.markRequest() }
            await service.start(environment: environment)
            _ = await environment.indentUnit()
            _ = await environment.openBufferText(URL(fileURLWithPath: "/language-service-conformance"))
            environment.publishDiagnostics(DiagnosticPublication(
                source: DiagnosticSourceID(rawValue: "conformance"),
                url: URL(fileURLWithPath: "/language-service-conformance"),
                diagnostics: []
            ))
            await service.stop()
        }.value
        XCTAssertFalse(box.requestRanOnMain, "\(service.name) ran a request on the main actor", file: file, line: line)

        await MainActor.run {
            box.hooksRanOnMain = onMainThread()
            service.projectDidChange(root: nil)
            service.filesDidChange([])
            service.documentsDidSave([])
        }
        XCTAssertTrue(box.hooksRanOnMain, "\(service.name) hooks ran off the main actor", file: file, line: line)
    }
}

/// `Thread.isMainThread` is unavailable in an async function. This one is synchronous.
private func onMainThread() -> Bool {
    Thread.isMainThread
}

private final class Probe: @unchecked Sendable {}

private final class WeakSlot: @unchecked Sendable {
    weak var probe: Probe?
}

private final class MainActorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var requestOnMain = false
    var hooksRanOnMain = false

    func markRequest() {
        lock.lock()
        requestOnMain = true
        lock.unlock()
    }

    var requestRanOnMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestOnMain
    }
}
