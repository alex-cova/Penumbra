import CryptoKit
import Foundation

/// Real paths. `URL.resolvingSymlinksInPath()` is not enough here: Foundation deliberately turns
/// `/private/var` back into `/var`, so a path it returns can still be spelled through a link.
enum IDEACPPaths {
    /// `realpath(3)`: every symbolic link resolved. Nil when the path does not exist.
    static func real(_ url: URL) -> URL? {
        url.path.withCString { pointer in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved))
        }
    }

    static func real(orSelf url: URL) -> URL { real(url) ?? url.standardizedFileURL }

    /// `path` is `base` or inside it, compared as whole path components.
    static func isInside(_ path: String, _ base: String) -> Bool {
        path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}

/// The disk layout of managed adapters and its invariants. Synchronous file work: callers run it
/// off the main actor (the installer actor, or `Task.detached`).
///
///     <root>/                      Application Support/com.umbra.editor/ACP
///       .lock                      flock during mutations
///       adapters/<id>/
///         versions/<version>/      a complete npm prefix, plus install.json
///         staging/<uuid>/          installs in progress; swept on load
///         active.json              the version new sessions start, and the previous one
///       npm/{cache,home,npmrc}     private npm state, cleared after each operation
///       diagnostics/<id>.log       scrubbed, bounded
///       catalog.json               display cache of the last registry check (never trusted)
struct IDEACPAdapterStore: Sendable {
    let root: URL
    let leases: IDEACPAdapterLeases

    static let maxLogBytes = 64 * 1_024

    init(root: URL, leases: IDEACPAdapterLeases = .shared) {
        self.root = root
        self.leases = leases
    }

    static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("com.umbra.editor/ACP", isDirectory: true)
    }

    // MARK: Paths

    var adaptersDirectory: URL { root.appendingPathComponent("adapters", isDirectory: true) }
    var npmDirectory: URL { root.appendingPathComponent("npm", isDirectory: true) }
    var diagnosticsDirectory: URL { root.appendingPathComponent("diagnostics", isDirectory: true) }
    var catalogCacheURL: URL { root.appendingPathComponent("catalog.json") }
    private var lockURL: URL { root.appendingPathComponent(".lock") }

    func adapterDirectory(_ id: String) -> URL { adaptersDirectory.appendingPathComponent(id, isDirectory: true) }
    func versionsDirectory(_ id: String) -> URL { adapterDirectory(id).appendingPathComponent("versions", isDirectory: true) }
    func stagingDirectory(_ id: String) -> URL { adapterDirectory(id).appendingPathComponent("staging", isDirectory: true) }
    func versionDirectory(_ id: String, _ version: String) -> URL {
        versionsDirectory(id).appendingPathComponent(version, isDirectory: true)
    }
    func activeURL(_ id: String) -> URL { adapterDirectory(id).appendingPathComponent("active.json") }
    /// `flock` files, kept apart from `versions/` and `staging/` so listing those never sees them.
    func locksDirectory(_ id: String) -> URL { adapterDirectory(id).appendingPathComponent("locks", isDirectory: true) }
    func versionLockURL(_ id: String, _ version: String) -> URL {
        locksDirectory(id).appendingPathComponent("version-\(version)")
    }
    func stagingLockURL(_ id: String, _ name: String) -> URL {
        locksDirectory(id).appendingPathComponent("staging-\(name)")
    }

    /// The version lock of an installed version folder (`…/<id>/versions/<v>`); nil for anything
    /// else, such as the staging folder the install's handshake probe runs from.
    static func versionLockURL(forVersionDirectory directory: URL) -> URL? {
        let versions = directory.deletingLastPathComponent()
        guard versions.lastPathComponent == "versions" else { return nil }
        return versions.deletingLastPathComponent()
            .appendingPathComponent("locks", isDirectory: true)
            .appendingPathComponent("version-\(directory.lastPathComponent)")
    }
    func manifestURL(_ id: String, _ version: String) -> URL {
        versionDirectory(id, version).appendingPathComponent("install.json")
    }

    // MARK: Layout and permissions

    func ensureLayout(for id: String? = nil) throws {
        var directories = [root, adaptersDirectory, npmDirectory, diagnosticsDirectory]
        if let id { directories += [adapterDirectory(id), versionsDirectory(id), stagingDirectory(id)] }
        for directory in directories { try ensureDirectory(directory) }
        try Self.checkOwnership(root)
    }

    private func ensureDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // createDirectory leaves an existing directory's mode alone.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw IDEACPAdapterError.permission("Could not prepare \(url.path): \(error.localizedDescription)")
        }
    }

    /// The directory belongs to this user and nobody else can write to it.
    static func checkOwnership(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw IDEACPAdapterError.permission("\(url.path) is missing.")
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw IDEACPAdapterError.permission("\(url.path) is not a folder.")
        }
        guard info.st_uid == getuid() else {
            throw IDEACPAdapterError.permission("\(url.path) is owned by another user.")
        }
        guard info.st_mode & 0o022 == 0 else {
            throw IDEACPAdapterError.permission("\(url.path) can be written by other users.")
        }
    }

    /// Runs `body` holding an exclusive lock on `<root>/.lock`, so two Umbra processes cannot
    /// activate or remove at the same time.
    func withMutationLock<T>(_ body: () throws -> T) throws -> T {
        try ensureDirectory(root)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw IDEACPAdapterError.permission("Could not open the adapter lock.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw IDEACPAdapterError.permission("Could not take the adapter lock.") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    // MARK: Manifests

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// nil when there is no `active.json`; throws when there is one that cannot be read.
    func readActive(_ id: String) throws -> IDEACPActiveManifest? {
        let url = activeURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Self.decoder().decode(IDEACPActiveManifest.self, from: Data(contentsOf: url))
        } catch {
            throw IDEACPAdapterError.corruptManifest("active.json for \(id) is unreadable.")
        }
    }

    func writeActive(_ id: String, _ manifest: IDEACPActiveManifest) throws {
        try writeAtomically(Self.encoder().encode(manifest), to: activeURL(id))
    }

    func readManifest(_ id: String, _ version: String) throws -> IDEACPInstallManifest {
        do {
            let manifest = try Self.decoder().decode(
                IDEACPInstallManifest.self, from: Data(contentsOf: manifestURL(id, version)))
            guard manifest.adapterID == id, manifest.version == version else {
                throw IDEACPAdapterError.corruptManifest("install.json for \(id)@\(version) describes another version.")
            }
            return manifest
        } catch let error as IDEACPAdapterError {
            throw error
        } catch {
            throw IDEACPAdapterError.corruptManifest("install.json for \(id)@\(version) is unreadable.")
        }
    }

    func writeManifest(_ manifest: IDEACPInstallManifest, in directory: URL) throws {
        try writeAtomically(Self.encoder().encode(manifest), to: directory.appendingPathComponent("install.json"))
    }

    /// Temp file in the same folder, then `rename`: a reader sees the old file or the new one.
    func writeAtomically(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            guard rename(temp.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw (error as? IDEACPAdapterError) ?? Self.mapWriteError(error)
        }
    }

    static func mapWriteError(_ error: Error) -> IDEACPAdapterError {
        let code = (error as NSError).code
        if code == Int(ENOSPC) || code == NSFileWriteOutOfSpaceError {
            return .diskFull(needed: 0, free: 0)
        }
        return .permission(error.localizedDescription)
    }

    // MARK: Queries

    /// Verified versions on disk, newest install first. Directories without a valid manifest are
    /// not listed (`recover` removes them).
    func installedVersions(_ id: String) -> [IDEACPInstallManifest] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: versionsDirectory(id).path)) ?? []
        return names.compactMap { try? readManifest(id, $0) }.sorted { $0.installedAt > $1.installedAt }
    }

    /// The active install, or nil when none is active or its files are not intact. Reads the
    /// manifests only; `verifyEntry` also hashes the entry script.
    func activeInstall(_ id: String) -> IDEACPActiveInstall? {
        guard let active = try? readActive(id), let manifest = try? readManifest(id, active.version) else { return nil }
        return install(from: manifest)
    }

    func install(from manifest: IDEACPInstallManifest) -> IDEACPActiveInstall {
        let directory = versionDirectory(manifest.adapterID, manifest.version)
        return IDEACPActiveInstall(
            adapterID: manifest.adapterID, version: manifest.version, versionDirectory: directory,
            entryURL: directory.appendingPathComponent(manifest.entryRelativePath),
            entrySHA256: manifest.entrySHA256, nodePath: manifest.nodePath)
    }

    /// Everything a launch relies on, checked right before the process starts: the folder is ours
    /// and not writable by others, the entry is a regular file inside the version, and its hash is
    /// the one recorded at install time. A file replaced after the fact is refused.
    static func verifyEntry(_ install: IDEACPActiveInstall) throws {
        try checkOwnership(install.versionDirectory)
        let entry = IDEACPPaths.real(orSelf: install.entryURL)
        let base = IDEACPPaths.real(orSelf: install.versionDirectory).path
        guard IDEACPPaths.isInside(entry.path, base), entry.path != base else {
            throw IDEACPAdapterError.unsafeTree(install.entryURL.lastPathComponent)
        }
        var info = stat()
        guard stat(entry.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw IDEACPAdapterError.corruptManifest("The adapter's entry file is missing.")
        }
        guard info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw IDEACPAdapterError.permission("\(entry.lastPathComponent) can be changed by other users.")
        }
        guard let digest = Self.sha256(of: entry), digest == install.entrySHA256 else {
            throw IDEACPAdapterError.integrity("The adapter's entry file changed after it was installed.")
        }
    }

    /// `verifyEntry`, tolerant of one race: the version was reinstalled between reading its
    /// manifest and checking the entry. When the hash differs, the manifest in the folder is read
    /// again; if it now names the file that is there, that is the new install and the launch goes
    /// on with it. A file changed without its manifest changing still fails.
    @discardableResult
    static func verifyEntryAllowingReinstall(_ install: IDEACPActiveInstall) throws -> IDEACPActiveInstall {
        do {
            try verifyEntry(install)
            return install
        } catch let error as IDEACPAdapterError {
            guard case .integrity = error,
                  let data = try? Data(contentsOf: install.versionDirectory.appendingPathComponent("install.json")),
                  let manifest = try? decoder().decode(IDEACPInstallManifest.self, from: data),
                  manifest.adapterID == install.adapterID, manifest.version == install.version,
                  manifest.entrySHA256 != install.entrySHA256
            else { throw error }
            var refreshed = install
            refreshed.entrySHA256 = manifest.entrySHA256
            try verifyEntry(refreshed)
            return refreshed
        }
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Staging and activation

    /// A staging folder nobody holds: what a crashed install leaves behind. Installs use
    /// `makeHeldStaging`.
    func makeStaging(_ id: String) throws -> URL {
        try makeHeldStaging(id).url
    }

    /// A staging folder and the lock that tells `recover` in any Umbra process that an install
    /// is writing to it. Keep the lock until the folder is activated or discarded; releasing it
    /// removes the lock file.
    func makeHeldStaging(_ id: String) throws -> (url: URL, lock: IDEACPFileLock) {
        try ensureLayout(for: id)
        try ensureDirectory(locksDirectory(id))
        let name = UUID().uuidString
        guard let lock = IDEACPFileLock(url: stagingLockURL(id, name), exclusive: true, wait: false, removeOnRelease: true) else {
            throw IDEACPAdapterError.permission("Could not lock the adapter's staging folder.")
        }
        let url = stagingDirectory(id).appendingPathComponent(name, isDirectory: true)
        try ensureDirectory(url)
        return (url, lock)
    }

    /// Runs `body` while no process holds `version` of `id`: this process's leases first, then an
    /// exclusive non-blocking lock on the version's lock file, kept until `body` returns so no
    /// process can start the version in between.
    private func withVersionUnused<T>(_ id: String, _ version: String, _ refusal: String, _ body: () throws -> T) throws -> T {
        guard !leases.isLeased(adapterID: id, version: version) else { throw IDEACPAdapterError.inUse(refusal) }
        guard let hold = IDEACPFileLock(url: versionLockURL(id, version), exclusive: true, wait: false) else {
            throw IDEACPAdapterError.inUse("Version \(version) is used by an agent in another Umbra window or process. Stop its chats first.")
        }
        defer { hold.release() }
        return try body()
    }

    func discardStaging(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Moves a verified staged prefix into `versions/<version>` and makes it active. The staged
    /// directory must already hold `install.json`. An existing directory for the same version is
    /// replaced only when nothing is using it. `active.json` is written last, so a crash between
    /// the two steps leaves the old version active and a complete unused new one on disk.
    @discardableResult
    func activate(_ id: String, staged: URL, manifest: IDEACPInstallManifest) throws -> IDEACPActiveManifest {
        try withMutationLock {
            let target = versionDirectory(id, manifest.version)
            if FileManager.default.fileExists(atPath: target.path) {
                try withVersionUnused(id, manifest.version, "Version \(manifest.version) is running. Stop its chats, then reinstall.") {
                    // Swap the two folders in one step, so a launch never sees the version missing.
                    // The old content ends up at the staged path and is deleted from there.
                    if renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 {
                        try? FileManager.default.removeItem(at: staged)
                    } else {
                        let aside = stagingDirectory(id).appendingPathComponent("replaced-\(UUID().uuidString)")
                        try FileManager.default.moveItem(at: target, to: aside)
                        do {
                            try FileManager.default.moveItem(at: staged, to: target)
                        } catch {
                            try? FileManager.default.moveItem(at: aside, to: target)
                            throw Self.mapWriteError(error)
                        }
                        try? FileManager.default.removeItem(at: aside)
                    }
                }
            } else {
                do {
                    try FileManager.default.moveItem(at: staged, to: target)
                } catch {
                    throw Self.mapWriteError(error)
                }
            }
            let previous = try? readActive(id)
            let active = IDEACPActiveManifest(
                version: manifest.version,
                previous: previous.flatMap { $0.version == manifest.version ? $0.previous : $0.version },
                activatedAt: Date())
            try writeActive(id, active)
            return active
        }
    }

    /// Makes an earlier verified version active again. Both manifests and the entry hash are
    /// checked first, so a damaged version cannot be restored.
    func restore(_ id: String, version: String) throws -> IDEACPActiveManifest {
        try withMutationLock {
            let manifest = try readManifest(id, version)
            try Self.verifyEntry(install(from: manifest))
            let current = try? readActive(id)
            let active = IDEACPActiveManifest(
                version: version, previous: current.flatMap { $0.version == version ? $0.previous : $0.version },
                activatedAt: Date())
            try writeActive(id, active)
            return active
        }
    }

    // MARK: Removal and pruning

    func removeVersion(_ id: String, version: String) throws {
        try withMutationLock {
            if (try? readActive(id))?.version == version {
                throw IDEACPAdapterError.inUse("Version \(version) is the active one. Restore another version first.")
            }
            try withVersionUnused(id, version, "Version \(version) is used by a running agent. Stop its chats first.") {
                try? FileManager.default.removeItem(at: versionDirectory(id, version))
                // A launch already waiting on this file gets it after us and then finds no files.
                unlink(versionLockURL(id, version).path)
            }
            if let active = try? readActive(id), active.previous == version {
                try writeActive(id, IDEACPActiveManifest(version: active.version, previous: nil, activatedAt: active.activatedAt))
            }
        }
    }

    func removeAdapter(_ id: String) throws {
        try withMutationLock {
            guard leases.totalCount(adapterID: id) == 0 else {
                throw IDEACPAdapterError.inUse("A running agent uses \(id). Stop its chats first.")
            }
            // Every version held exclusively until the folder is gone, so no other process starts
            // one meanwhile.
            var holds: [IDEACPFileLock] = []
            defer { holds.forEach { $0.release() } }
            for version in (try? FileManager.default.contentsOfDirectory(atPath: versionsDirectory(id).path)) ?? [] {
                guard let hold = IDEACPFileLock(url: versionLockURL(id, version), exclusive: true, wait: false) else {
                    throw IDEACPAdapterError.inUse("An agent in another Umbra window or process uses \(id) \(version). Stop its chats first.")
                }
                holds.append(hold)
            }
            try? FileManager.default.removeItem(at: adapterDirectory(id))
            try? FileManager.default.removeItem(at: diagnosticsDirectory.appendingPathComponent("\(id).log"))
        }
    }

    /// Keeps the active version, the previous one, and anything in use; removes the rest.
    @discardableResult
    func prune(_ id: String) -> [String] {
        let active = try? readActive(id)
        var keep = Set([active?.version, active?.previous].compactMap { $0 })
        keep.formUnion(leases.leasedVersions(adapterID: id))
        var removed: [String] = []
        for manifest in installedVersions(id) where !keep.contains(manifest.version) {
            if (try? removeVersion(id, version: manifest.version)) != nil { removed.append(manifest.version) }
        }
        return removed
    }

    // MARK: Recovery

    struct RecoveryReport: Equatable, Sendable {
        var removedStaging = 0
        var removedIncomplete: [String] = []
        var repairedActive: String?
    }

    /// Run when the manager loads. Removes interrupted installs and repairs an unusable
    /// `active.json` by activating the newest verified version. An install still running in any
    /// Umbra process holds its staging lock and is left alone; a crashed one holds nothing.
    @discardableResult
    func recover(_ id: String) -> RecoveryReport {
        var report = RecoveryReport()
        guard FileManager.default.fileExists(atPath: adapterDirectory(id).path) else { return report }
        let staging = stagingDirectory(id)
        // Under the mutation lock: `activate` moves a replaced version aside into staging while
        // holding it.
        _ = try? withMutationLock {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [] {
                let lock = stagingLockURL(id, name)
                if IDEACPFileLock.isHeld(lock) { continue }
                try? FileManager.default.removeItem(at: staging.appendingPathComponent(name))
                try? FileManager.default.removeItem(at: lock)
                report.removedStaging += 1
            }
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: versionsDirectory(id).path)) ?? []
        where (try? readManifest(id, name)) == nil {
            let removed: Bool? = try? withVersionUnused(id, name, "") {
                try? FileManager.default.removeItem(at: versionDirectory(id, name))
                return true
            }
            if removed == true { report.removedIncomplete.append(name) }
        }
        let active = try? readActive(id)
        let usable = active.flatMap { (try? readManifest(id, $0.version)) } != nil
        if !usable, let newest = installedVersions(id).first {
            let repaired = IDEACPActiveManifest(version: newest.version, previous: nil, activatedAt: Date())
            if (try? withMutationLock { try writeActive(id, repaired) }) != nil { report.repairedActive = newest.version }
        }
        if report.removedStaging > 0 || !report.removedIncomplete.isEmpty || report.repairedActive != nil {
            appendDiagnostic(id, "Recovery: removed \(report.removedStaging) staging folder(s), "
                + "\(report.removedIncomplete.count) incomplete version(s)"
                + (report.repairedActive.map { "; reactivated \($0)" } ?? "") + ".")
        }
        return report
    }

    // MARK: Disk and diagnostics

    func freeBytes() -> Int64 {
        let probe = FileManager.default.fileExists(atPath: root.path) ? root : root.deletingLastPathComponent()
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }

    /// Bytes under `url`, counting regular files only. Used for progress and the installed size.
    static func directorySize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey], options: [])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Appends a scrubbed line to `diagnostics/<id>.log` and keeps the file under `maxLogBytes`
    /// by dropping the oldest lines.
    func appendDiagnostic(_ id: String, _ message: String, now: Date = Date()) {
        try? ensureDirectory(diagnosticsDirectory)
        let url = diagnosticsDirectory.appendingPathComponent("\(id).log")
        let stamp = ISO8601DateFormatter().string(from: now)
        let line = "\(stamp) \(IDEACPSecretScrubber.scrub(message).replacingOccurrences(of: "\n", with: " ⏎ "))\n"
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text += line
        while text.utf8.count > Self.maxLogBytes, let newline = text.firstIndex(of: "\n") {
            text.removeSubrange(text.startIndex...newline)
        }
        try? writeAtomically(Data(text.utf8), to: url)
    }

    func readDiagnostics(_ id: String) -> String {
        (try? String(contentsOf: diagnosticsDirectory.appendingPathComponent("\(id).log"), encoding: .utf8)) ?? ""
    }

    // MARK: Display cache

    struct CachedCheck: Codable, Equatable, Sendable {
        var latest: [String: String]
        var checkedAt: Date
    }

    func readCachedCheck() -> CachedCheck? {
        try? Self.decoder().decode(CachedCheck.self, from: Data(contentsOf: catalogCacheURL))
    }

    func writeCachedCheck(_ check: CachedCheck) {
        try? ensureDirectory(root)
        try? writeAtomically(Self.encoder().encode(check), to: catalogCacheURL)
    }
}
