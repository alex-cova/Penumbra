import Foundation
import XCTest
@testable import Umbra

final class IDEACPAdapterStateTests: XCTestCase {
    private typealias Machine = IDEACPAdapterMachine
    private let failure = IDEACPAdapterError.offline("x")

    func testAFreshInstallWalksTheStepsForwardAndEndsReady() {
        var phase: IDEACPAdapterPhase = .notInstalled
        phase = Machine.transition(from: phase, event: .beginInstall)!
        XCTAssertEqual(phase, .working(.resolving))
        for step in [IDEACPAdapterStep.downloading, .verifying, .installing] {
            phase = Machine.transition(from: phase, event: .advance(step))!
            XCTAssertEqual(phase, .working(step))
        }
        phase = Machine.transition(from: phase, event: .activated(version: "1.0.0"))!
        XCTAssertEqual(phase, .ready(version: "1.0.0"))
    }

    func testStepsCannotGoBackwardOrSkipTheActivationStep() {
        XCTAssertNil(Machine.transition(from: .working(.verifying), event: .advance(.downloading)))
        XCTAssertNil(Machine.transition(from: .working(.verifying), event: .advance(.verifying)))
        XCTAssertNil(Machine.transition(from: .working(.verifying), event: .activated(version: "1")),
                     "activation only follows the installing step")
        XCTAssertNil(Machine.transition(from: .ready(version: "1"), event: .advance(.installing)))
        XCTAssertNil(Machine.transition(from: .notInstalled, event: .activated(version: "1")))
    }

    func testAnUpdateKeepsTheInstalledVersionThroughFailureAndCancellation() {
        let start = Machine.transition(from: .ready(version: "1.0.0"), event: .beginUpdate(to: "2.0.0"))
        XCTAssertEqual(start, .updating(from: "1.0.0", to: "2.0.0", step: .resolving))
        let mid = Machine.transition(from: start!, event: .advance(.downloading))!
        XCTAssertEqual(Machine.transition(from: mid, event: .failed(failure)), .failed(failure, keeping: "1.0.0"))
        XCTAssertEqual(Machine.transition(from: mid, event: .cancelled), .ready(version: "1.0.0"))
        let installing = Machine.transition(from: mid, event: .advance(.verifying)).flatMap {
            Machine.transition(from: $0, event: .advance(.installing))
        }!
        XCTAssertEqual(Machine.transition(from: installing, event: .activated(version: "2.0.0")), .ready(version: "2.0.0"))
    }

    func testAFailedFreshInstallCanBeRetriedButAFailedUpdateRetriesAsAnUpdate() {
        let freshFailure = IDEACPAdapterPhase.failed(failure, keeping: nil)
        XCTAssertEqual(Machine.transition(from: freshFailure, event: .beginInstall), .working(.resolving))
        XCTAssertNil(Machine.transition(from: freshFailure, event: .beginUpdate(to: "2")))
        let updateFailure = IDEACPAdapterPhase.failed(failure, keeping: "1.0.0")
        XCTAssertNil(Machine.transition(from: updateFailure, event: .beginInstall),
                     "an installed adapter is never reinstalled from scratch by mistake")
        XCTAssertEqual(
            Machine.transition(from: updateFailure, event: .beginUpdate(to: "2.0.0")),
            .updating(from: "1.0.0", to: "2.0.0", step: .resolving))
    }

    func testCancellingAFreshInstallReturnsToNotInstalled() {
        XCTAssertEqual(Machine.transition(from: .working(.downloading), event: .cancelled), .notInstalled)
        XCTAssertNil(Machine.transition(from: .ready(version: "1"), event: .cancelled))
        XCTAssertNil(Machine.transition(from: .notInstalled, event: .cancelled))
    }

    func testUpdateAvailableIsOnlyReachedFromAnInstalledAdapter() {
        XCTAssertEqual(
            Machine.transition(from: .ready(version: "1.0.0"), event: .updateFound(available: "1.1.0", security: true)),
            .updateAvailable(installed: "1.0.0", available: "1.1.0", security: true))
        XCTAssertEqual(
            Machine.transition(from: .updateAvailable(installed: "1.0.0", available: "1.1.0", security: true),
                               event: .updateFound(available: "1.2.0", security: false)),
            .updateAvailable(installed: "1.0.0", available: "1.2.0", security: false))
        XCTAssertNil(Machine.transition(from: .notInstalled, event: .updateFound(available: "1", security: false)))
        XCTAssertNil(Machine.transition(from: .working(.downloading), event: .updateFound(available: "1", security: false)),
                     "a check never disturbs a running operation")
        XCTAssertEqual(
            Machine.transition(from: .updateAvailable(installed: "1.0.0", available: "1.1.0", security: false), event: .upToDate),
            .ready(version: "1.0.0"))
    }

    func testDisableAndEnableRoundTripAndRemovalClearsEverything() {
        XCTAssertEqual(Machine.transition(from: .ready(version: "1"), event: .disable), .disabled(installed: "1"))
        XCTAssertEqual(Machine.transition(from: .disabled(installed: "1"), event: .enable), .ready(version: "1"))
        XCTAssertEqual(Machine.transition(from: .notInstalled, event: .disable), .disabled(installed: nil))
        XCTAssertEqual(Machine.transition(from: .disabled(installed: nil), event: .enable), .notInstalled)
        XCTAssertNil(Machine.transition(from: .working(.installing), event: .disable))
        XCTAssertEqual(Machine.transition(from: .ready(version: "1"), event: .removed), .notInstalled)
        XCTAssertNil(Machine.transition(from: .working(.downloading), event: .removed), "no removal during an install")
        XCTAssertNil(Machine.transition(from: .updating(from: "1", to: "2", step: .resolving), event: .removed))
    }

    func testBusyAndInstalledVersionAccessors() {
        XCTAssertTrue(IDEACPAdapterPhase.working(.resolving).isBusy)
        XCTAssertTrue(IDEACPAdapterPhase.updating(from: "1", to: "2", step: .installing).isBusy)
        XCTAssertFalse(IDEACPAdapterPhase.ready(version: "1").isBusy)
        XCTAssertEqual(IDEACPAdapterPhase.updating(from: "1", to: "2", step: .installing).installedVersion, "1")
        XCTAssertEqual(IDEACPAdapterPhase.failed(failure, keeping: "3").installedVersion, "3")
        XCTAssertNil(IDEACPAdapterPhase.working(.verifying).installedVersion)
    }

    func testEveryErrorHasAnActionableMessage() {
        let errors: [IDEACPAdapterError] = [
            .offline("x"), .registry("x"), .untrusted("x"), .integrity("x"), .unsupportedPlatform("x"), .nodeMissing,
            .nodeTooOld(found: "18.0.0", required: "Node.js >=22"), .diskFull(needed: 10, free: 1), .npmFailed("x"),
            .cancelled, .inUse("x"), .corruptManifest("x"), .unsafeTree("x"), .permission("x"), .startupFailed("x"),
            .sandboxed, .notManaged, .noPreviousVersion,
        ]
        for error in errors { XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error)") }
        XCTAssertTrue(IDEACPAdapterError.nodeMissing.errorDescription!.contains("Node.js"))
        XCTAssertTrue(IDEACPAdapterError.untrusted("r").errorDescription!.contains("nothing was installed"))
    }
}
