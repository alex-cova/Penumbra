import CryptoKit
import Foundation
import XCTest
@testable import Umbra

/// The trust policy against the real signed artifacts for codex-acp 2.6.0 and claude-agent-acp
/// 0.106.0, plus tampered copies of them.
final class IDEACPTrustPolicyTests: XCTestCase {
    private var codex: IDEACPNpmSource { IDEACPAdapterCatalog.codex.npm! }
    private var claude: IDEACPNpmSource { IDEACPAdapterCatalog.claude.npm! }

    private func verify(
        _ version: IDEACPPackageVersion, attestations: Data?, source: IDEACPNpmSource? = nil, expected: String? = nil,
        keys: [String: String] = IDEACPTrustPolicy.pinnedKeys
    ) throws -> IDEACPVerifiedPackage {
        try IDEACPTrustPolicy.verify(
            version: version, attestations: attestations, source: source ?? codex, expectedVersion: expected, pinnedKeys: keys)
    }

    private func assertUntrusted(_ body: () throws -> Any, _ fragment: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case .untrusted(let reason)? = error as? IDEACPAdapterError else {
                return XCTFail("expected untrusted, got \(error)", file: file, line: line)
            }
            if let fragment { XCTAssertTrue(reason.localizedCaseInsensitiveContains(fragment), reason, file: file, line: line) }
        }
    }

    // MARK: Real artifacts

    func testTheRealCodexAndClaudeReleasesVerify() throws {
        let codexVersion = try ACPFixtures.version(ACPFixtures.codex)
        let verified = try verify(codexVersion, attestations: ACPFixtures.attestations(ACPFixtures.codex), expected: "2.6.0")
        XCTAssertEqual(verified.package, "@agentclientprotocol/codex-acp")
        XCTAssertEqual(verified.version, "2.6.0")
        XCTAssertEqual(verified.signatureKeyID, "SHA256:DhQ8wR5APBvFHLF/+Tc+AYvPOdTpcIDqOhxsBHRwC7U")
        XCTAssertEqual(verified.integrity, codexVersion.dist.integrity)

        let claudeVersion = try ACPFixtures.version(ACPFixtures.claude)
        let claudeVerified = try verify(
            claudeVersion, attestations: ACPFixtures.attestations(ACPFixtures.claude), source: claude, expected: "0.106.0")
        XCTAssertEqual(claudeVerified.package, "@agentclientprotocol/claude-agent-acp")
        XCTAssertEqual(claudeVersion.engines?["node"], ">=22")
    }

    func testTheRepositoryFormsNpmPublishesAllCompareEqual() {
        XCTAssertEqual(
            IDEACPPackageVersion.normalizeRepository("git+https://github.com/Agent/Repo.git"),
            IDEACPPackageVersion.normalizeRepository("https://github.com/agent/repo/"))
        XCTAssertEqual(
            IDEACPPackageVersion.normalizeRepository("git://github.com/a/b.git"), "https://github.com/a/b")
        XCTAssertNil(IDEACPPackageVersion.normalizeRepository(nil))
    }

    // MARK: Tampering

    private func mutated(_ change: (inout [String: Any]) -> Void) throws -> IDEACPPackageVersion {
        var json = try ACPFixtures.versionJSON(ACPFixtures.codex)
        change(&json)
        return try JSONDecoder().decode(IDEACPPackageVersion.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testATamperedIntegrityFailsTheSignature() throws {
        let tampered = try mutated { json in
            var dist = json["dist"] as! [String: Any]
            var integrity = dist["integrity"] as! String
            let index = integrity.index(integrity.startIndex, offsetBy: 12)
            integrity.replaceSubrange(index...index, with: integrity[index] == "A" ? "B" : "A")
            dist["integrity"] = integrity
            json["dist"] = dist
        }
        assertUntrusted({ try self.verify(tampered, attestations: ACPFixtures.attestations(ACPFixtures.codex)) }, "signature")
    }

    func testATamperedVersionOrNameFails() throws {
        let otherVersion = try mutated { $0["version"] = "2.6.1" }
        assertUntrusted({ try self.verify(otherVersion, attestations: ACPFixtures.attestations(ACPFixtures.codex)) })
        let otherName = try mutated { $0["name"] = "@evil/codex-acp" }
        assertUntrusted({ try self.verify(otherName, attestations: ACPFixtures.attestations(ACPFixtures.codex)) })
        let real = try ACPFixtures.version(ACPFixtures.codex)
        assertUntrusted({ try self.verify(real, attestations: ACPFixtures.attestations(ACPFixtures.codex), expected: "2.5.0") }, "instead of 2.5.0")
    }

    func testAnUnknownSigningKeyMeansAuthenticityCannotBeEstablished() throws {
        let real = try ACPFixtures.version(ACPFixtures.codex)
        assertUntrusted({ try self.verify(real, attestations: ACPFixtures.attestations(ACPFixtures.codex), keys: [:]) }, "key Umbra does not know")
        let unsigned = try mutated { json in
            var dist = json["dist"] as! [String: Any]
            dist["signatures"] = []
            json["dist"] = dist
        }
        assertUntrusted({ try self.verify(unsigned, attestations: ACPFixtures.attestations(ACPFixtures.codex)) }, "did not sign")
    }

    func testASignatureFromTheWrongKeyFails() throws {
        let real = try ACPFixtures.version(ACPFixtures.codex)
        let other = P256.Signing.PrivateKey()
        let keyID = "SHA256:" + String(repeating: "x", count: 43)
        let keys = [keyID: other.publicKey.derRepresentation.base64EncodedString()]
        let forged = try mutated { json in
            var dist = json["dist"] as! [String: Any]
            let signatures = dist["signatures"] as! [[String: Any]]
            dist["signatures"] = signatures.map { ["keyid": keyID, "sig": $0["sig"] as! String] }
            json["dist"] = dist
        }
        assertUntrusted({ try self.verify(forged, attestations: ACPFixtures.attestations(ACPFixtures.codex), keys: keys) }, "not valid")
        XCTAssertNotNil(real)
    }

    func testAFreshlySignedMessageVerifiesWithItsKey() throws {
        // Proves the verifier accepts exactly what npm's scheme produces, independent of the fixtures.
        let key = P256.Signing.PrivateKey()
        let integrity = "sha512-" + Data(repeating: 7, count: 64).base64EncodedString()
        let message = Data("@agentclientprotocol/codex-acp@9.9.9:\(integrity)".utf8)
        let signature = try key.signature(for: message).derRepresentation.base64EncodedString()
        let version = IDEACPPackageVersion(
            name: "@agentclientprotocol/codex-acp", version: "9.9.9",
            dist: .init(integrity: integrity, signatures: [.init(keyid: "SHA256:test", sig: signature)]))
        let keyID = try IDEACPTrustPolicy.verifySignature(
            version: version, integrity: integrity,
            pinnedKeys: ["SHA256:test": key.publicKey.derRepresentation.base64EncodedString()])
        XCTAssertEqual(keyID, "SHA256:test")
    }

    // MARK: Publisher, repository, provenance

    func testPublisherAndRepositoryMustMatchTheCatalog() throws {
        let real = try ACPFixtures.version(ACPFixtures.codex)
        let attestations = try ACPFixtures.attestations(ACPFixtures.codex)
        var wrongPublisher = codex
        wrongPublisher.trustedPublisher = "gitlab"
        assertUntrusted({ try self.verify(real, attestations: attestations, source: wrongPublisher) }, "trusted publishing")
        var wrongRepository = codex
        wrongRepository.repository = "https://github.com/someone-else/codex-acp"
        assertUntrusted({ try self.verify(real, attestations: attestations, source: wrongRepository) }, "repository")
        let noPublisher = try mutated { $0["_npmUser"] = ["name": "someone"] }
        assertUntrusted({ try self.verify(noPublisher, attestations: attestations) }, "trusted publishing")
        let movedRepository = try mutated { $0["repository"] = ["url": "git+https://github.com/evil/codex-acp.git"] }
        assertUntrusted({ try self.verify(movedRepository, attestations: attestations) }, "repository")
    }

    func testMissingOrMismatchedProvenanceIsRefused() throws {
        let real = try ACPFixtures.version(ACPFixtures.codex)
        assertUntrusted({ try self.verify(real, attestations: nil) }, "no provenance")
        assertUntrusted({ try self.verify(real, attestations: Data("not json".utf8)) }, "could not be read")
        assertUntrusted({ try self.verify(real, attestations: Data(#"{"attestations":[]}"#.utf8)) }, "no SLSA provenance")
        // Claude's genuine provenance is for another package.
        assertUntrusted({ try self.verify(real, attestations: ACPFixtures.attestations(ACPFixtures.claude)) }, "different package")
    }

    func testProvenanceFromAnotherRepositoryIsRefused() throws {
        let real = try ACPFixtures.version(ACPFixtures.codex)
        let data = try ACPFixtures.attestations(ACPFixtures.codex)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var list = root["attestations"] as! [[String: Any]]
        let index = try XCTUnwrap(list.firstIndex { $0["predicateType"] as? String == IDEACPTrustPolicy.provenancePredicate })
        var bundle = list[index]["bundle"] as! [String: Any]
        var envelope = bundle["dsseEnvelope"] as! [String: Any]
        let payload = try XCTUnwrap(Data(base64Encoded: envelope["payload"] as! String))
        var statement = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        var predicate = statement["predicate"] as! [String: Any]
        var build = predicate["buildDefinition"] as! [String: Any]
        var external = build["externalParameters"] as! [String: Any]
        var workflow = external["workflow"] as! [String: Any]
        workflow["repository"] = "https://github.com/evil/codex-acp"
        external["workflow"] = workflow
        build["externalParameters"] = external
        predicate["buildDefinition"] = build
        statement["predicate"] = predicate
        envelope["payload"] = try JSONSerialization.data(withJSONObject: statement).base64EncodedString()
        bundle["dsseEnvelope"] = envelope
        list[index]["bundle"] = bundle
        root["attestations"] = list
        let forged = try JSONSerialization.data(withJSONObject: root)
        assertUntrusted({ try self.verify(real, attestations: forged) }, "built from")
    }

    // MARK: After npm install

    private func lock(
        top: [String: Any]? = nil, extra: [String: [String: Any]] = [:]
    ) throws -> Data {
        var packages: [String: Any] = [
            "": ["dependencies": ["p": "1.0.0"]],
            "node_modules/p": top ?? ["version": "1.0.0", "integrity": "sha512-ok", "resolved": "https://registry.npmjs.org/p/-/p-1.0.0.tgz"],
        ]
        for (key, value) in extra { packages[key] = value }
        return try JSONSerialization.data(withJSONObject: ["lockfileVersion": 3, "packages": packages])
    }

    func testLockfileAcceptsRegistryPackagesAndBundledDependencies() throws {
        let data = try lock(extra: [
            "node_modules/q": ["version": "2.0.0", "integrity": "sha512-q", "resolved": "https://registry.npmjs.org/q/-/q-2.0.0.tgz"],
            "node_modules/p/node_modules/inner": ["version": "1.0.0", "inBundle": true],
        ])
        XCTAssertNoThrow(try IDEACPTrustPolicy.verifyLockfile(data, package: "p", version: "1.0.0", integrity: "sha512-ok"))
    }

    func testLockfileRejectsADifferentChecksumOrVersionForTheAdapter() throws {
        XCTAssertThrowsError(try IDEACPTrustPolicy.verifyLockfile(lock(), package: "p", version: "1.0.0", integrity: "sha512-other")) {
            guard case .integrity? = $0 as? IDEACPAdapterError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try IDEACPTrustPolicy.verifyLockfile(lock(), package: "p", version: "1.0.1", integrity: "sha512-ok"))
        XCTAssertThrowsError(try IDEACPTrustPolicy.verifyLockfile(lock(), package: "missing", version: "1.0.0", integrity: "sha512-ok"))
        XCTAssertThrowsError(try IDEACPTrustPolicy.verifyLockfile(Data("nope".utf8), package: "p", version: "1", integrity: "x")) {
            guard case .corruptManifest? = $0 as? IDEACPAdapterError else { return XCTFail("\($0)") }
        }
    }

    func testLockfileRejectsGitFileTarballAndLinkDependencies() throws {
        let sources: [(String, [String: Any])] = [
            ("git", ["version": "1", "integrity": "sha512-x", "resolved": "git+ssh://git@github.com/evil/x.git#abc"]),
            ("file", ["version": "1", "integrity": "sha512-x", "resolved": "file:../x"]),
            ("other host", ["version": "1", "integrity": "sha512-x", "resolved": "https://evil.example/x.tgz"]),
            ("http", ["version": "1", "integrity": "sha512-x", "resolved": "http://registry.npmjs.org/x.tgz"]),
            ("no resolved", ["version": "1", "integrity": "sha512-x"]),
            ("link", ["link": true, "resolved": "../x"]),
        ]
        for (name, entry) in sources {
            let data = try lock(extra: ["node_modules/x": entry])
            XCTAssertThrowsError(try IDEACPTrustPolicy.verifyLockfile(data, package: "p", version: "1.0.0", integrity: "sha512-ok"), name) {
                guard case .untrusted? = $0 as? IDEACPAdapterError else { return XCTFail("\(name): \($0)") }
            }
        }
        let noIntegrity = try lock(extra: ["node_modules/x": ["version": "1", "resolved": "https://registry.npmjs.org/x/-/x-1.tgz"]])
        XCTAssertThrowsError(try IDEACPTrustPolicy.verifyLockfile(noIntegrity, package: "p", version: "1.0.0", integrity: "sha512-ok"))
    }

    func testAuditSignatures() throws {
        XCTAssertEqual(try IDEACPTrustPolicy.checkAuditSignatures(Data(#"{"invalid":[],"missing":[]}"#.utf8), package: "p"), [])
        XCTAssertThrowsError(try IDEACPTrustPolicy.checkAuditSignatures(
            Data(#"{"invalid":[{"name":"dep","version":"1"}],"missing":[]}"#.utf8), package: "p")) {
            guard case .untrusted(let reason)? = $0 as? IDEACPAdapterError else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("dep"))
        }
        XCTAssertThrowsError(try IDEACPTrustPolicy.checkAuditSignatures(
            Data(#"{"invalid":[],"missing":[{"name":"p","version":"1"}]}"#.utf8), package: "p"))
        let warnings = try IDEACPTrustPolicy.checkAuditSignatures(
            Data(#"{"invalid":[],"missing":[{"name":"old-dep","version":"1"}]}"#.utf8), package: "p")
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("old-dep"))
        XCTAssertThrowsError(try IDEACPTrustPolicy.checkAuditSignatures(Data("<html>".utf8), package: "p"))
    }

    func testSha512HexFromIntegrity() {
        let integrity = "sha512-" + Data(repeating: 0xAB, count: 64).base64EncodedString()
        XCTAssertEqual(IDEACPTrustPolicy.sha512Hex(fromIntegrity: integrity), String(repeating: "ab", count: 64))
        XCTAssertNil(IDEACPTrustPolicy.sha512Hex(fromIntegrity: "sha1-abc"))
        XCTAssertNil(IDEACPTrustPolicy.sha512Hex(fromIntegrity: "sha512-" + Data(repeating: 1, count: 10).base64EncodedString()))
    }
}
