import Foundation
import XCTest
@testable import Umbra

final class IDEACPAdapterStoreTests: XCTestCase {
    private var rig: ACPTestRoot!
    private var store: IDEACPAdapterStore { rig.store }
    private let id = "codex-acp"

    override func setUpWithError() throws { rig = try ACPTestRoot() }
    override func tearDown() { rig.cleanUp() }

    /// A complete staged version, with its manifest, ready to activate.
    private func stage(_ version: String, entry: String = "console.log(1)\n") throws -> (URL, IDEACPInstallManifest) {
        let staging = try store.makeStaging(id)
        let entryRelative = "node_modules/pkg/dist/index.js"
        let entryURL = staging.appendingPathComponent(entryRelative)
        try FileManager.default.createDirectory(at: entryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try entry.write(to: entryURL, atomically: true, encoding: .utf8)
        let manifest = IDEACPInstallManifest(
            adapterID: id, package: "pkg", version: version, integrity: "sha512-x", signatureKeyID: "k",
            provenanceRepository: "r", publisher: "p", nodePath: "/usr/bin/true", nodeVersion: "26.0.0",
            entryRelativePath: entryRelative, entrySHA256: IDEACPAdapterStore.sha256(of: entryURL)!, installedBytes: 1,
            installedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded()), warnings: [])
        try store.writeManifest(manifest, in: staging)
        return (staging, manifest)
    }

    // MARK: Layout

    func testLayoutIsPrivateToTheUser() throws {
        try store.ensureLayout(for: id)
        for url in [store.root, store.adaptersDirectory, store.adapterDirectory(id), store.versionsDirectory(id), store.stagingDirectory(id)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? Int) ?? 0, 0o700, url.lastPathComponent)
            XCTAssertNoThrow(try IDEACPAdapterStore.checkOwnership(url))
        }
    }

    func testOwnershipCheckRefusesAFolderOthersCanWrite() throws {
        try store.ensureLayout(for: id)
        let loose = store.versionsDirectory(id)
        try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: loose.path)
        XCTAssertThrowsError(try IDEACPAdapterStore.checkOwnership(loose)) {
            guard case .permission? = $0 as? IDEACPAdapterError else { return XCTFail("\($0)") }
        }
        let file = store.root.appendingPathComponent("not-a-folder")
        try Data().write(to: file)
        XCTAssertThrowsError(try IDEACPAdapterStore.checkOwnership(file))
        XCTAssertThrowsError(try IDEACPAdapterStore.checkOwnership(store.root.appendingPathComponent("missing")))
        // ensureLayout repairs a loosened folder it owns.
        try store.ensureLayout(for: id)
        XCTAssertNoThrow(try IDEACPAdapterStore.checkOwnership(loose))
    }

    // MARK: Activation

    func testActivationMovesTheStagedFolderAndWritesActiveLast() throws {
        let (first, firstManifest) = try stage("1.0.0")
        let active = try store.activate(id, staged: first, manifest: firstManifest)
        XCTAssertEqual(active.version, "1.0.0")
        XCTAssertNil(active.previous)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "the staged folder was moved, not copied")
        XCTAssertEqual(try store.readActive(id)?.version, "1.0.0")
        XCTAssertEqual(try store.readManifest(id, "1.0.0"), firstManifest)

        let (second, secondManifest) = try stage("2.0.0")
        let next = try store.activate(id, staged: second, manifest: secondManifest)
        XCTAssertEqual(next.version, "2.0.0")
        XCTAssertEqual(next.previous, "1.0.0")
        XCTAssertEqual(store.installedVersions(id).count, 2)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: store.stagingDirectory(id).path)) ?? ["?"], [],
                       "no staging leftovers")
    }

    func testReinstallingTheActiveVersionKeepsItsPreviousPointer() throws {
        let (one, oneManifest) = try stage("1.0.0")
        try store.activate(id, staged: one, manifest: oneManifest)
        let (two, twoManifest) = try stage("2.0.0")
        try store.activate(id, staged: two, manifest: twoManifest)
        let (again, againManifest) = try stage("2.0.0", entry: "console.log('again')\n")
        let active = try store.activate(id, staged: again, manifest: againManifest)
        XCTAssertEqual(active.version, "2.0.0")
        XCTAssertEqual(active.previous, "1.0.0")
        let entry = store.versionDirectory(id, "2.0.0").appendingPathComponent(againManifest.entryRelativePath)
        XCTAssertEqual(try String(contentsOf: entry, encoding: .utf8), "console.log('again')\n")
    }

    func testReplacingAVersionInUseIsRefusedAndLeavesItIntact() throws {
        let (one, manifest) = try stage("1.0.0", entry: "original\n")
        try store.activate(id, staged: one, manifest: manifest)
        let lease = rig.leases.acquire(adapterID: id, version: "1.0.0")
        let (again, againManifest) = try stage("1.0.0", entry: "replacement\n")
        XCTAssertThrowsError(try store.activate(id, staged: again, manifest: againManifest)) {
            guard case .inUse? = $0 as? IDEACPAdapterError else { return XCTFail("\($0)") }
        }
        let entry = store.versionDirectory(id, "1.0.0").appendingPathComponent(manifest.entryRelativePath)
        XCTAssertEqual(try String(contentsOf: entry, encoding: .utf8), "original\n")
        lease.release()
    }

    func testConcurrentActivationsNeverCorruptActiveJSON() throws {
        let staged = try (0..<8).map { try stage("\($0).0.0") }
        DispatchQueue.concurrentPerform(iterations: staged.count) { index in
            _ = try? store.activate(id, staged: staged[index].0, manifest: staged[index].1)
        }
        let active = try XCTUnwrap(try store.readActive(id))
        XCTAssertTrue(staged.map(\.1.version).contains(active.version))
        XCTAssertEqual(store.installedVersions(id).count, 8)
        if let previous = active.previous { XCTAssertNotEqual(previous, active.version) }
    }

    func testALaunchDuringActivationsAlwaysFindsACompleteVerifiedVersion() throws {
        // Re-activating the same version swaps folders; a reader must never see it missing or torn.
        let (first, firstManifest) = try stage("1.0.0", entry: "console.log('a')\n")
        try store.activate(id, staged: first, manifest: firstManifest)
        let stop = ManagedAtomicFlag()
        let failures = FailureLog()
        let reader = Thread {
            while !stop.isSet {
                guard let install = self.store.activeInstall(self.id) else { failures.add("no active install"); continue }
                do { try IDEACPAdapterStore.verifyEntryAllowingReinstall(install) } catch { failures.add("\(error)") }
            }
        }
        reader.start()
        for index in 0..<40 {
            let (next, manifest) = try stage("1.0.0", entry: "console.log('b\(index)')\n")
            try store.activate(id, staged: next, manifest: manifest)
        }
        stop.set()
        while !reader.isFinished { usleep(1_000) }
        XCTAssertEqual(failures.all, [], "a launch raced an update and saw a missing or half-written version")
    }

    // MARK: Recovery

    func testInterruptedInstallsAreCleanedUp() throws {
        let (stagedOnly, _) = try stage("9.0.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedOnly.path))
        // A version directory that never got its manifest (a crash between the steps).
        try acpWriteVersion(store, version: "8.0.0", writeManifest: false)
        let (good, manifest) = try stage("1.0.0")
        try store.activate(id, staged: good, manifest: manifest)

        let report = store.recover(id)
        XCTAssertEqual(report.removedStaging, 1)
        XCTAssertEqual(report.removedIncomplete, ["8.0.0"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedOnly.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.versionDirectory(id, "8.0.0").path))
        XCTAssertEqual(try store.readActive(id)?.version, "1.0.0", "a healthy active version is left alone")
        XCTAssertTrue(store.readDiagnostics(id).contains("Recovery"))
    }

    func testACorruptActiveFileFallsBackToTheNewestVerifiedVersion() throws {
        try acpWriteVersion(store, version: "1.0.0", installedAt: Date(timeIntervalSinceNow: -100))
        try acpWriteVersion(store, version: "2.0.0", installedAt: Date(timeIntervalSinceNow: -10))
        try Data("{ not json".utf8).write(to: store.activeURL(id))
        XCTAssertThrowsError(try store.readActive(id)) {
            guard case .corruptManifest? = $0 as? IDEACPAdapterError else { return XCTFail("\($0)") }
        }
        XCTAssertNil(store.activeInstall(id), "a damaged pointer activates nothing")
        let report = store.recover(id)
        XCTAssertEqual(report.repairedActive, "2.0.0")
        XCTAssertEqual(try store.readActive(id)?.version, "2.0.0")
    }

    func testAnActivePointerToAMissingVersionIsRepaired() throws {
        try acpWriteVersion(store, version: "1.0.0")
        try store.writeActive(id, IDEACPActiveManifest(version: "5.0.0", previous: nil, activatedAt: Date()))
        XCTAssertNil(store.activeInstall(id))
        XCTAssertEqual(store.recover(id).repairedActive, "1.0.0")
        XCTAssertEqual(store.activeInstall(id)?.version, "1.0.0")
    }

    func testARunningVersionWithoutAManifestIsNotDeletedUnderneathItsProcess() throws {
        try acpWriteVersion(store, version: "3.0.0", writeManifest: false)
        let lease = rig.leases.acquire(adapterID: id, version: "3.0.0")
        XCTAssertEqual(store.recover(id).removedIncomplete, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.versionDirectory(id, "3.0.0").path))
        lease.release()
    }

    // MARK: Two Umbra processes

    /// Another Umbra process: same folder, its own lease registry. `flock` locks belong to an
    /// open file, so two stores in one test process conflict exactly as two processes do.
    private func otherProcess() -> IDEACPAdapterStore {
        IDEACPAdapterStore(root: rig.root, leases: IDEACPAdapterLeases())
    }

    func testAnotherProcessLoadingLeavesAnInstallInProgressAlone() throws {
        let held = try store.makeHeldStaging(id)
        try Data("partial".utf8).write(to: held.url.appendingPathComponent("file"))
        let report = otherProcess().recover(id)
        XCTAssertEqual(report.removedStaging, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: held.url.appendingPathComponent("file").path),
                      "a running install's staging survives another window's startup")

        held.lock.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.stagingLockURL(id, held.url.lastPathComponent).path),
                       "releasing removes the lock file")
        XCTAssertEqual(otherProcess().recover(id).removedStaging, 1, "once nobody holds it, it is a leftover")
        XCTAssertFalse(FileManager.default.fileExists(atPath: held.url.path))
    }

    func testAnotherProcessCannotRemoveOrReplaceAVersionRunningHere() throws {
        try acpWriteVersion(store, version: "1.0.0", installedAt: Date(timeIntervalSinceNow: -100))
        try acpWriteVersion(store, version: "2.0.0", installedAt: Date(timeIntervalSinceNow: -50))
        try acpWriteVersion(store, version: "3.0.0")
        try store.writeActive(id, IDEACPActiveManifest(version: "3.0.0", previous: "2.0.0", activatedAt: Date()))
        let running = rig.leases.acquire(
            adapterID: id, version: "1.0.0", versionDirectory: store.versionDirectory(id, "1.0.0"))
        let other = otherProcess()

        XCTAssertThrowsError(try other.removeVersion(id, version: "1.0.0")) {
            guard case .inUse? = $0 as? IDEACPAdapterError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(other.prune(id), [], "pruning skips what another process runs")
        XCTAssertThrowsError(try other.removeAdapter(id)) {
            guard case .inUse? = $0 as? IDEACPAdapterError else { return XCTFail("\($0)") }
        }
        let (again, againManifest) = try stage("1.0.0", entry: "replacement\n")
        XCTAssertThrowsError(try other.activate(id, staged: again, manifest: againManifest)) {
            guard case .inUse? = $0 as? IDEACPAdapterError else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.versionDirectory(id, "1.0.0").path))

        running.release()
        XCTAssertNoThrow(try other.removeVersion(id, version: "1.0.0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.versionDirectory(id, "1.0.0").path))
        XCTAssertNoThrow(try other.removeAdapter(id))
    }

    func testTheHandshakeProbeTakesNoVersionLock() {
        let staging = store.stagingDirectory(id).appendingPathComponent("abc")
        XCTAssertNil(IDEACPAdapterStore.versionLockURL(forVersionDirectory: staging))
        XCTAssertEqual(IDEACPAdapterStore.versionLockURL(forVersionDirectory: store.versionDirectory(id, "1.0.0"))?.path,
                       store.versionLockURL(id, "1.0.0").path)
    }

    func testAManifestThatDescribesAnotherVersionIsRejected() throws {
        try acpWriteVersion(store, version: "1.0.0")
        let other = try acpWriteVersion(store, version: "2.0.0")
        try FileManager.default.removeItem(at: store.manifestURL(id, "1.0.0"))
        try FileManager.default.copyItem(at: store.manifestURL(id, "2.0.0"), to: store.manifestURL(id, "1.0.0"))
        XCTAssertThrowsError(try store.readManifest(id, "1.0.0")) {
            guard case .corruptManifest? = $0 as? IDEACPAdapterError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(store.installedVersions(id).map(\.version), [other.version])
    }

    // MARK: Removal, restore, pruning

    func testRemovingTheActiveOrAnInUseVersionIsRefused() throws {
        try acpWriteVersion(store, version: "1.0.0", installedAt: Date(timeIntervalSinceNow: -10))
        try acpWriteVersion(store, version: "2.0.0")
        try store.writeActive(id, IDEACPActiveManifest(version: "2.0.0", previous: "1.0.0", activatedAt: Date()))

        XCTAssertThrowsError(try store.removeVersion(id, version: "2.0.0")) {
            guard case .inUse? = $0 as? IDEACPAdapterError else { return XCTFail("\($0)") }
        }
        let lease = rig.leases.acquire(adapterID: id, version: "1.0.0")
        XCTAssertThrowsError(try store.removeVersion(id, version: "1.0.0"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.versionDirectory(id, "1.0.0").path))
        lease.release()

        XCTAssertNoThrow(try store.removeVersion(id, version: "1.0.0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.versionDirectory(id, "1.0.0").path))
        XCTAssertNil(try store.readActive(id)?.previous, "the pointer to a removed version is cleared")
    }

    func testRemovingTheWholeAdapterNeedsNoRunningProcess() throws {
        try acpWriteVersion(store, version: "1.0.0")
        store.appendDiagnostic(id, "hello")
        let lease = rig.leases.acquire(adapterID: id, version: "1.0.0")
        XCTAssertThrowsError(try store.removeAdapter(id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.adapterDirectory(id).path))
        lease.release()
        try store.removeAdapter(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.adapterDirectory(id).path))
        XCTAssertEqual(store.readDiagnostics(id), "", "uninstall leaves no diagnostics behind")
    }

    func testRestoreSwitchesToAnEarlierVerifiedVersionAndRefusesADamagedOne() throws {
        try acpWriteVersion(store, version: "1.0.0")
        try acpWriteVersion(store, version: "2.0.0")
        try store.writeActive(id, IDEACPActiveManifest(version: "2.0.0", previous: "1.0.0", activatedAt: Date()))
        let restored = try store.restore(id, version: "1.0.0")
        XCTAssertEqual(restored.version, "1.0.0")
        XCTAssertEqual(restored.previous, "2.0.0")

        let entry = store.versionDirectory(id, "2.0.0").appendingPathComponent("node_modules/pkg/dist/index.js")
        try "tampered".write(to: entry, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.restore(id, version: "2.0.0")) {
            guard case .integrity? = $0 as? IDEACPAdapterError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try store.readActive(id)?.version, "1.0.0", "a refused restore changes nothing")
    }

    func testPruneKeepsTheActivePreviousAndInUseVersions() throws {
        for (index, version) in ["1.0.0", "2.0.0", "3.0.0", "4.0.0", "5.0.0"].enumerated() {
            try acpWriteVersion(store, version: version, installedAt: Date(timeIntervalSinceNow: Double(index - 10)))
        }
        try store.writeActive(id, IDEACPActiveManifest(version: "5.0.0", previous: "4.0.0", activatedAt: Date()))
        let lease = rig.leases.acquire(adapterID: id, version: "2.0.0")
        let removed = Set(store.prune(id))
        XCTAssertEqual(removed, ["1.0.0", "3.0.0"])
        XCTAssertEqual(Set(store.installedVersions(id).map(\.version)), ["2.0.0", "4.0.0", "5.0.0"])
        lease.release()
    }

    // MARK: Launch-time verification

    func testVerifyEntryDetectsAReplacedFileAndAnEscapingSymlink() throws {
        let manifest = try acpWriteVersion(store, version: "1.0.0")
        try store.writeActive(id, IDEACPActiveManifest(version: "1.0.0", previous: nil, activatedAt: Date()))
        let install = try XCTUnwrap(store.activeInstall(id))
        XCTAssertNoThrow(try IDEACPAdapterStore.verifyEntry(install))

        try "changed".write(to: install.entryURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try IDEACPAdapterStore.verifyEntry(install)) {
            guard case .integrity? = $0 as? IDEACPAdapterError else { return XCTFail("\($0)") }
        }

        // The entry becomes a link to a file outside the version.
        let outside = rig.root.appendingPathComponent("outside.js")
        try "console.log(1)\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: install.entryURL)
        try FileManager.default.createSymbolicLink(at: install.entryURL, withDestinationURL: outside)
        XCTAssertThrowsError(try IDEACPAdapterStore.verifyEntry(install)) {
            guard case .unsafeTree? = $0 as? IDEACPAdapterError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(manifest.version, "1.0.0")
    }

    func testAReinstallBetweenReadingAndLaunchingIsToleratedButATamperedFileIsNot() throws {
        let (first, firstManifest) = try stage("1.0.0", entry: "original\n")
        try store.activate(id, staged: first, manifest: firstManifest)
        let stale = try XCTUnwrap(store.activeInstall(id))

        // A file edited in place: the manifest still names the old hash, so this must fail.
        try "edited".write(to: stale.entryURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try IDEACPAdapterStore.verifyEntryAllowingReinstall(stale)) {
            guard case .integrity? = $0 as? IDEACPAdapterError else { return XCTFail("\($0)") }
        }

        // The same version installed again: folder and manifest both change.
        let (second, secondManifest) = try stage("1.0.0", entry: "reinstalled\n")
        try store.activate(id, staged: second, manifest: secondManifest)
        let refreshed = try IDEACPAdapterStore.verifyEntryAllowingReinstall(stale)
        XCTAssertEqual(refreshed.entrySHA256, secondManifest.entrySHA256)
        XCTAssertThrowsError(try IDEACPAdapterStore.verifyEntry(stale), "the strict check still compares with the snapshot")
    }

    func testVerifyEntryRefusesAWritableVersionFolderAndAMissingEntry() throws {
        try acpWriteVersion(store, version: "1.0.0")
        try store.writeActive(id, IDEACPActiveManifest(version: "1.0.0", previous: nil, activatedAt: Date()))
        let install = try XCTUnwrap(store.activeInstall(id))
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: install.versionDirectory.path)
        XCTAssertThrowsError(try IDEACPAdapterStore.verifyEntry(install)) {
            guard case .permission? = $0 as? IDEACPAdapterError else { return XCTFail("\($0)") }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: install.versionDirectory.path)
        try FileManager.default.removeItem(at: install.entryURL)
        XCTAssertThrowsError(try IDEACPAdapterStore.verifyEntry(install))
    }

    // MARK: Diagnostics and cache

    func testDiagnosticsAreScrubbedAndBounded() throws {
        store.appendDiagnostic(id, "failed with token=sk-abcdefghijklmnop and api_key=hunter2")
        let first = store.readDiagnostics(id)
        XCTAssertFalse(first.contains("sk-abcdefghijklmnop"))
        XCTAssertFalse(first.contains("hunter2"))
        XCTAssertTrue(first.contains("[redacted]"))

        let long = String(repeating: "x", count: 900)
        for index in 0..<300 { store.appendDiagnostic(id, "line \(index) \(long)") }
        let text = store.readDiagnostics(id)
        XCTAssertLessThanOrEqual(text.utf8.count, IDEACPAdapterStore.maxLogBytes)
        XCTAssertTrue(text.contains("line 299"), "the newest lines are kept")
        XCTAssertFalse(text.contains("line 0 "), "the oldest lines are dropped")
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testTheDisplayCacheRoundTripsAndNeverCountsAsInstalled() throws {
        XCTAssertNil(store.readCachedCheck())
        let check = IDEACPAdapterStore.CachedCheck(latest: ["codex-acp": "2.6.0"], checkedAt: Date(timeIntervalSince1970: 1_000))
        store.writeCachedCheck(check)
        XCTAssertEqual(store.readCachedCheck()?.latest, ["codex-acp": "2.6.0"])
        XCTAssertNil(store.activeInstall("codex-acp"))
        XCTAssertTrue(store.installedVersions("codex-acp").isEmpty)
    }

    func testDirectorySizeAndFreeBytes() throws {
        let folder = store.root.appendingPathComponent("size", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100_000).write(to: folder.appendingPathComponent("a"))
        XCTAssertGreaterThanOrEqual(IDEACPAdapterStore.directorySize(folder), 100_000)
        XCTAssertGreaterThan(store.freeBytes(), 0)
    }
}

private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private final class FailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { if !items.contains(item) { items.append(item) } } }
    var all: [String] { lock.withLock { items } }
}

final class IDEACPPathsTests: XCTestCase {
    func testRealPathSpellsOutTheLinkThatFoundationHides() throws {
        // Foundation maps /private/var back to /var; realpath does not.
        let temp = FileManager.default.temporaryDirectory
        let foundation = temp.resolvingSymlinksInPath().path
        let real = try XCTUnwrap(IDEACPPaths.real(temp)).path
        if temp.path.hasPrefix("/var/") {
            XCTAssertTrue(real.hasPrefix("/private/var/"), real)
            XCTAssertTrue(foundation.hasPrefix("/var/"), "the quirk this helper exists for: \(foundation)")
        }
        XCTAssertNil(IDEACPPaths.real(URL(fileURLWithPath: "/nonexistent/umbra")))
        XCTAssertEqual(IDEACPPaths.real(orSelf: URL(fileURLWithPath: "/nonexistent/umbra")).path, "/nonexistent/umbra")
    }

    func testInsideIsComparedByWholeComponents() {
        XCTAssertTrue(IDEACPPaths.isInside("/a/b/c", "/a/b"))
        XCTAssertTrue(IDEACPPaths.isInside("/a/b", "/a/b"))
        XCTAssertFalse(IDEACPPaths.isInside("/a/bc", "/a/b"), "a sibling with the same prefix is outside")
        XCTAssertFalse(IDEACPPaths.isInside("/a", "/a/b"))
    }

    func testTheAuditJudgesLinksByWhereTheyReallyLand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/b"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Inside the tree, by a relative link and by an absolute one spelled through /private.
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("node_modules/a/rel").path, withDestinationPath: "../b")
        let realB = try XCTUnwrap(IDEACPPaths.real(root.appendingPathComponent("node_modules/b")))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("node_modules/a/abs").path, withDestinationPath: realB.path)
        XCTAssertNoThrow(try IDEACPTreeAudit.audit(root: root))
        // A link that climbs out lexically but would be fine after normalizing is still judged by where it lands.
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("node_modules/a/out").path, withDestinationPath: "../../../")
        XCTAssertThrowsError(try IDEACPTreeAudit.audit(root: root)) {
            guard case .unsafeTree? = $0 as? IDEACPAdapterError else { return XCTFail("\($0)") }
        }
    }
}
