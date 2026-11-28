import CryptoKit
import Foundation
import SubprocessKit
import XCTest
@testable import Umbra

/// The installer never touches the network here: a fake serves a tarball built in the test.
final class IDEJDKInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jdk-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private final class FakeNetwork: IDEJDKInstallerNetwork, @unchecked Sendable {
        var release: IDETemurinRelease
        var archive: URL
        var finalURL: URL?
        private(set) var downloads = 0

        init(release: IDETemurinRelease, archive: URL) {
            self.release = release
            self.archive = archive
        }

        func release(featureVersion: Int, architecture: String) async throws -> IDETemurinRelease { release }

        func download(_ url: URL) async throws -> (file: URL, finalURL: URL) {
            downloads += 1
            // The installer deletes what it is given, so hand out a copy.
            let copy = archive.deletingLastPathComponent().appendingPathComponent("download-\(UUID().uuidString).tar.gz")
            try FileManager.default.copyItem(at: archive, to: copy)
            return (copy, finalURL ?? url)
        }
    }

    /// A tar.gz holding `top/Contents/Home/{bin/java,release}`.
    private func makeArchive(
        top: String = "jdk-21.0.9+1", javaVersion: String = "21.0.9", withJava: Bool = true, extraTopLevel: String? = nil
    ) throws -> URL {
        let source = root.appendingPathComponent("src-\(UUID().uuidString)", isDirectory: true)
        let home = source.appendingPathComponent("\(top)/Contents/Home", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("bin"), withIntermediateDirectories: true)
        if withJava {
            let java = home.appendingPathComponent("bin/java")
            try "#!/bin/sh\necho openjdk\n".write(to: java, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
        }
        try "JAVA_VERSION=\"\(javaVersion)\"\n".write(to: home.appendingPathComponent("release"), atomically: true, encoding: .utf8)
        if let extraTopLevel {
            try FileManager.default.createDirectory(at: source.appendingPathComponent(extraTopLevel), withIntermediateDirectories: true)
        }
        let archive = root.appendingPathComponent("archive-\(UUID().uuidString).tar.gz")
        let result = try SubprocessRunner.runBlocking(SubprocessRequest(
            executable: "/usr/bin/tar", arguments: ["-czf", archive.path, "-C", source.path, "."]
        ))
        XCTAssertEqual(result.exit.status, 0)
        // `.` as the root would add a leading "./" entry; extract-side handles that, but keep the top-level shape simple.
        return archive
    }

    private func release(for archive: URL, checksum: String? = nil, url: String = "https://github.com/adoptium/temurin21-binaries/releases/download/x/jdk.tar.gz", version: String = "21.0.9+1") throws -> IDETemurinRelease {
        IDETemurinRelease(
            featureVersion: 21, version: version, archiveName: "jdk.tar.gz", downloadURL: URL(string: url)!,
            checksum: try checksum ?? IDEJDKInstaller.sha256(of: archive), size: 1
        )
    }

    private func installer(_ network: FakeNetwork) -> IDEJDKInstaller {
        IDEJDKInstaller(
            network: network,
            installDirectory: root.appendingPathComponent("JavaVirtualMachines", isDirectory: true),
            stagingDirectory: root.appendingPathComponent("staging", isDirectory: true)
        )
    }

    private func installed(_ installer: IDEJDKInstaller) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: installer.installDirectory.path)) ?? []).sorted()
    }

    private func staged(_ installer: IDEJDKInstaller) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: installer.stagingDirectory.path)) ?? []
    }

    // MARK: - Install

    func testAVerifiedArchiveIsInstalledAsOneCompleteBundle() async throws {
        let archive = try makeArchive()
        let network = FakeNetwork(release: try release(for: archive), archive: archive)
        let installer = installer(network)

        let bundle = try await installer.install(featureVersion: 21)
        XCTAssertEqual(bundle.lastPathComponent, "temurin-21.0.9_1.jdk")
        XCTAssertEqual(bundle.deletingLastPathComponent().standardizedFileURL, installer.installDirectory.standardizedFileURL)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("Contents/Home/bin/java").path))
        XCTAssertEqual(installed(installer), ["temurin-21.0.9_1.jdk"], "nothing else is left in the folder the app scans")
        XCTAssertEqual(staged(installer), [], "the staging area is cleaned up")
        XCTAssertEqual(network.downloads, 1)
    }

    func testAnArchiveThatDoesNotMatchItsChecksumIsRejectedBeforeAnythingIsUnpacked() async throws {
        let archive = try makeArchive()
        let wrong = String(repeating: "0", count: 64)
        let network = FakeNetwork(release: try release(for: archive, checksum: wrong), archive: archive)
        let installer = installer(network)
        do {
            _ = try await installer.install(featureVersion: 21)
            XCTFail("a wrong checksum must fail")
        } catch {
            XCTAssertEqual(error as? IDEJDKInstallError, .checksumMismatch)
        }
        XCTAssertEqual(installed(installer), [])
        XCTAssertEqual(staged(installer), [])
    }

    func testASourceOutsideAdoptiumIsNeverDownloaded() async throws {
        let archive = try makeArchive()
        for url in ["http://github.com/adoptium/x.tar.gz", "https://evil.example.com/jdk.tar.gz", "https://github.com.evil.example/jdk.tar.gz", "file:///tmp/jdk.tar.gz"] {
            let network = FakeNetwork(release: try release(for: archive, url: url), archive: archive)
            let installer = installer(network)
            do {
                _ = try await installer.install(featureVersion: 21)
                XCTFail("\(url) must be refused")
            } catch {
                guard case .untrustedSource? = error as? IDEJDKInstallError else { return XCTFail("\(url): \(error)") }
            }
            XCTAssertEqual(network.downloads, 0, "\(url) was not fetched")
            XCTAssertEqual(installed(installer), [])
        }
    }

    func testARedirectToAnUntrustedHostIsRefusedAfterTheDownload() async throws {
        let archive = try makeArchive()
        let network = FakeNetwork(release: try release(for: archive), archive: archive)
        network.finalURL = URL(string: "https://cdn.evil.example/jdk.tar.gz")
        let installer = installer(network)
        do {
            _ = try await installer.install(featureVersion: 21)
            XCTFail("an untrusted final host must fail")
        } catch {
            guard case .untrustedSource? = error as? IDEJDKInstallError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(installed(installer), [])
        XCTAssertEqual(staged(installer), [])
    }

    func testAnArchiveThatIsNotTheRequestedJDKIsRejected() async throws {
        let cases: [(String, URL)] = [
            ("another feature version", try makeArchive(javaVersion: "17.0.1")),
            ("no bin/java", try makeArchive(withJava: false)),
            ("two top-level folders", try makeArchive(extraTopLevel: "extra")),
        ]
        for (name, archive) in cases {
            let network = FakeNetwork(release: try release(for: archive), archive: archive)
            let installer = installer(network)
            do {
                _ = try await installer.install(featureVersion: 21)
                XCTFail("\(name) must be rejected")
            } catch {
                guard case .invalidArchive? = error as? IDEJDKInstallError else { return XCTFail("\(name): \(error)") }
            }
            XCTAssertEqual(installed(installer), [], name)
            XCTAssertEqual(staged(installer), [], name)
        }
    }

    func testAnAlreadyInstalledReleaseIsNotDownloadedAgain() async throws {
        let archive = try makeArchive()
        let network = FakeNetwork(release: try release(for: archive), archive: archive)
        let installer = installer(network)
        let first = try await installer.install(featureVersion: 21)
        do {
            _ = try await installer.install(featureVersion: 21)
            XCTFail("a second install of the same release")
        } catch {
            XCTAssertEqual(error as? IDEJDKInstallError, .alreadyInstalled(first))
        }
        XCTAssertEqual(network.downloads, 1)
    }

    func testTheBundleNameCannotLeaveTheInstallFolder() throws {
        let archive = try makeArchive()
        let hostile = try release(for: archive, version: "21.0.9/../../../etc")
        XCTAssertFalse(hostile.bundleName.contains("/"))
        XCTAssertEqual(hostile.bundleName, "temurin-21.0.9_.._.._.._etc.jdk")
        XCTAssertEqual(try release(for: archive, version: "21.0.9+1").bundleName, "temurin-21.0.9_1.jdk")
    }

    // MARK: - Trust and metadata

    func testOnlyHttpsHostsOfAdoptiumAndItsGitHubReleasesAreTrusted() {
        for trusted in [
            "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21/x.tar.gz",
            "https://objects.githubusercontent.com/github-production-release-asset/x",
            "https://api.adoptium.net/v3/assets",
        ] {
            XCTAssertTrue(IDEJDKInstaller.isTrusted(URL(string: trusted)!), trusted)
        }
        for untrusted in [
            "http://github.com/x", "https://notgithub.com/x", "https://github.com.evil.example/x",
            "https://evilgithubusercontent.com/x", "ftp://github.com/x", "https://adoptium.net.evil.example/x",
        ] {
            XCTAssertFalse(IDEJDKInstaller.isTrusted(URL(string: untrusted)!), untrusted)
        }
        XCTAssertTrue(IDEJDKInstaller.isChecksum(String(repeating: "a", count: 64)))
        XCTAssertFalse(IDEJDKInstaller.isChecksum(String(repeating: "g", count: 64)))
        XCTAssertFalse(IDEJDKInstaller.isChecksum("abc"))
    }

    func testAdoptiumReleaseMetadataIsParsedFromItsRealShape() throws {
        let json = """
        [{"binary":{"architecture":"aarch64","image_type":"jdk","os":"mac","package":{
            "checksum":"48067F2B7C958ED104A9D8A5749BE7D25220B0A356B4D2D1BCFAAB3E16AD0B14",
            "link":"https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13.1%2B2/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.13.1_2.tar.gz",
            "name":"OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.13.1_2.tar.gz","size":199772678}},
          "version":{"major":21,"openjdk_version":"21.0.13.1+2-LTS","semver":"21.0.13+100000002.0.LTS"}}]
        """
        let release = try IDEAdoptiumNetwork.parseRelease(Data(json.utf8), featureVersion: 21)
        XCTAssertEqual(release.version, "21.0.13.1+2")
        XCTAssertEqual(release.checksum, "48067f2b7c958ed104a9d8a5749be7d25220b0a356b4d2d1bcfaab3e16ad0b14", "lowercased")
        XCTAssertEqual(release.size, 199_772_678)
        XCTAssertEqual(release.bundleName, "temurin-21.0.13.1_2.jdk")
        XCTAssertTrue(IDEJDKInstaller.isTrusted(release.downloadURL))

        XCTAssertThrowsError(try IDEAdoptiumNetwork.parseRelease(Data("[]".utf8), featureVersion: 21)) {
            XCTAssertEqual($0 as? IDEJDKInstallError, .noRelease(featureVersion: 21))
        }
        XCTAssertThrowsError(try IDEAdoptiumNetwork.parseRelease(Data("{\"nope\":1}".utf8), featureVersion: 21)) {
            XCTAssertEqual($0 as? IDEJDKInstallError, .malformedMetadata)
        }
        XCTAssertThrowsError(try IDEAdoptiumNetwork.parseRelease(Data(json.replacingOccurrences(of: ".tar.gz\"", with: ".pkg\"").utf8), featureVersion: 21)) {
            XCTAssertEqual($0 as? IDEJDKInstallError, .noRelease(featureVersion: 21), "only a tar.gz is installed")
        }
    }
}
