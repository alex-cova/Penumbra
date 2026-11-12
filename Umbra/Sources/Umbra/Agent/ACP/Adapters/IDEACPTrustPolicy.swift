import CryptoKit
import Foundation

/// What the pre-download checks established about a version.
struct IDEACPVerifiedPackage: Equatable, Sendable {
    var package: String
    var version: String
    var integrity: String
    var signatureKeyID: String
    var publisher: String
    var repository: String
}

/// The explicit trust policy for npm-installed adapters.
///
/// A matching checksum is not trusted on its own: the checksum comes from the same registry as
/// the tarball. A version is accepted only when
/// 1. its name, publisher type and repository match the catalog entry (compiled into Umbra);
/// 2. the registry's ECDSA signature over `name@version:integrity` verifies against a key
///    **pinned in this file**, not one fetched from the registry;
/// 3. it carries SLSA provenance whose subject is this package and integrity and whose workflow
///    repository is the catalog's.
/// After `npm install`, the lockfile and `npm audit signatures` must agree (see the lock and
/// audit checks below). The DSSE envelope and certificate chain of the provenance bundle are
/// checked by npm (`npm audit signatures`), not re-implemented here.
///
/// If a key rotates, installs are refused ("authenticity cannot be established") until an Umbra
/// update pins the new key. That is deliberate.
enum IDEACPTrustPolicy {
    /// npm's registry signing key (https://registry.npmjs.org/-/npm/v1/keys), by key id.
    static let pinnedKeys: [String: String] = [
        "SHA256:DhQ8wR5APBvFHLF/+Tc+AYvPOdTpcIDqOhxsBHRwC7U":
            "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEY6Ya7W++7aUPzvMTrezH6Ycx3c+HOKYCcNGybJZSCJq/fd7Qa8uuAKtdIkUQtQiEKERhAmE5lMMJhP8OkDOa2g==",
    ]

    static let provenancePredicate = "https://slsa.dev/provenance/v1"

    // MARK: - Before download

    static func verify(
        version: IDEACPPackageVersion,
        attestations: Data?,
        source: IDEACPNpmSource,
        expectedVersion: String? = nil,
        pinnedKeys: [String: String] = IDEACPTrustPolicy.pinnedKeys
    ) throws -> IDEACPVerifiedPackage {
        guard version.name == source.package else {
            throw IDEACPAdapterError.untrusted("The registry returned “\(version.name)” instead of \(source.package).")
        }
        if let expectedVersion, version.version != expectedVersion {
            throw IDEACPAdapterError.untrusted("The registry returned version \(version.version) instead of \(expectedVersion).")
        }
        guard let publisher = version.npmUser?.trustedPublisher?.id, publisher == source.trustedPublisher else {
            throw IDEACPAdapterError.untrusted(
                "\(version.name)@\(version.version) was not published through npm trusted publishing from \(source.trustedPublisher).")
        }
        let expectedRepository = IDEACPPackageVersion.normalizeRepository(source.repository)
        guard version.normalizedRepository == expectedRepository else {
            throw IDEACPAdapterError.untrusted("The package names the repository \(version.repositoryURL ?? "(none)"), not \(source.repository).")
        }
        guard let integrity = version.dist.integrity, let digest = sha512Hex(fromIntegrity: integrity) else {
            throw IDEACPAdapterError.untrusted("The version has no sha512 integrity value.")
        }
        let keyID = try verifySignature(version: version, integrity: integrity, pinnedKeys: pinnedKeys)
        try verifyProvenance(
            attestations, package: version.name, version: version.version, sha512Hex: digest,
            repository: source.repository)
        return IDEACPVerifiedPackage(
            package: version.name, version: version.version, integrity: integrity, signatureKeyID: keyID,
            publisher: "npm trusted publisher (\(publisher)) · \(source.repository)", repository: source.repository)
    }

    /// The key id that verified. Throws when no signature verifies against a pinned key.
    static func verifySignature(
        version: IDEACPPackageVersion, integrity: String, pinnedKeys: [String: String]
    ) throws -> String {
        let signatures = version.dist.signatures ?? []
        guard !signatures.isEmpty else {
            throw IDEACPAdapterError.untrusted("The registry did not sign \(version.name)@\(version.version).")
        }
        let message = Data("\(version.name)@\(version.version):\(integrity)".utf8)
        var sawUnknownKey = false
        for signature in signatures {
            guard let keyText = pinnedKeys[signature.keyid] else {
                sawUnknownKey = true
                continue
            }
            guard let keyData = Data(base64Encoded: keyText),
                  let key = try? P256.Signing.PublicKey(derRepresentation: keyData),
                  let signatureData = Data(base64Encoded: signature.sig),
                  let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signatureData)
            else { continue }
            if key.isValidSignature(parsed, for: message) { return signature.keyid }
        }
        if sawUnknownKey {
            throw IDEACPAdapterError.untrusted(
                "The signature was made with a key Umbra does not know. Update Umbra, or check the key list at \(IDEACPNpmRegistry.host)/-/npm/v1/keys.")
        }
        throw IDEACPAdapterError.untrusted("The registry signature for \(version.name)@\(version.version) is not valid.")
    }

    static func verifyProvenance(
        _ data: Data?, package: String, version: String, sha512Hex: String, repository: String
    ) throws {
        guard let data else {
            throw IDEACPAdapterError.untrusted("\(package)@\(version) has no provenance attestation.")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["attestations"] as? [[String: Any]]
        else { throw IDEACPAdapterError.untrusted("The provenance attestation could not be read.") }

        guard let entry = list.first(where: { $0["predicateType"] as? String == provenancePredicate }),
              let bundle = entry["bundle"] as? [String: Any],
              let envelope = bundle["dsseEnvelope"] as? [String: Any],
              let payloadText = envelope["payload"] as? String,
              let payloadData = Data(base64Encoded: payloadText),
              let statement = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { throw IDEACPAdapterError.untrusted("\(package)@\(version) has no SLSA provenance.") }

        let expectedName = "pkg:npm/\(package.replacingOccurrences(of: "@", with: "%40"))@\(version)"
        let subjects = statement["subject"] as? [[String: Any]] ?? []
        guard subjects.contains(where: { subject in
            subject["name"] as? String == expectedName
                && (subject["digest"] as? [String: String])?["sha512"] == sha512Hex
        }) else {
            throw IDEACPAdapterError.untrusted("The provenance is for a different package or file than \(package)@\(version).")
        }
        let predicate = statement["predicate"] as? [String: Any]
        let build = predicate?["buildDefinition"] as? [String: Any]
        let external = build?["externalParameters"] as? [String: Any]
        let workflow = external?["workflow"] as? [String: Any]
        let built = IDEACPPackageVersion.normalizeRepository(workflow?["repository"] as? String)
        guard built == IDEACPPackageVersion.normalizeRepository(repository) else {
            throw IDEACPAdapterError.untrusted(
                "The provenance says it was built from \(workflow?["repository"] as? String ?? "an unknown repository"), not \(repository).")
        }
    }

    /// `sha512-<base64>` as lowercase hex, or nil when it is not a 64-byte sha512 value.
    static func sha512Hex(fromIntegrity integrity: String) -> String? {
        guard integrity.hasPrefix("sha512-"), let data = Data(base64Encoded: String(integrity.dropFirst(7))),
              data.count == 64
        else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - After npm install

    static let registryPrefix = "https://\(IDEACPNpmRegistry.host)/"

    /// Every package npm installed came from the public registry with an integrity value, and the
    /// adapter itself has the integrity that was verified before the download.
    static func verifyLockfile(_ data: Data, package: String, version: String, integrity: String) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packages = root["packages"] as? [String: [String: Any]]
        else { throw IDEACPAdapterError.corruptManifest("package-lock.json could not be read.") }

        guard let top = packages["node_modules/\(package)"] else {
            let listed = packages.keys.filter { !$0.isEmpty }.sorted().prefix(4).joined(separator: ", ")
            throw IDEACPAdapterError.integrity(
                "\(package) is missing from the lockfile, which lists \(max(packages.count - 1, 0)) package(s)"
                    + (listed.isEmpty ? "." : " (\(listed), …)."))
        }
        guard top["version"] as? String == version, top["integrity"] as? String == integrity else {
            throw IDEACPAdapterError.integrity(
                "npm installed \(package) with a different version or checksum than the one verified.")
        }
        for (path, entry) in packages where !path.isEmpty {
            if entry["link"] as? Bool == true {
                throw IDEACPAdapterError.untrusted("\(path) is a link dependency.")
            }
            if entry["inBundle"] as? Bool == true { continue }
            guard let resolved = entry["resolved"] as? String, resolved.hasPrefix(registryPrefix) else {
                let origin = (entry["resolved"] as? String) ?? "an unknown source"
                throw IDEACPAdapterError.untrusted("\(path) was fetched from \(origin), not from \(IDEACPNpmRegistry.host).")
            }
            guard let value = entry["integrity"] as? String, !value.isEmpty else {
                throw IDEACPAdapterError.integrity("\(path) has no integrity value.")
            }
        }
    }

    /// Parses `npm audit signatures --json`. Any invalid signature fails; a missing signature on
    /// the adapter itself fails; missing signatures on other packages are returned as warnings.
    static func checkAuditSignatures(_ data: Data, package: String) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IDEACPAdapterError.untrusted("npm audit signatures gave an answer Umbra cannot read.")
        }
        let invalid = (root["invalid"] as? [[String: Any]]) ?? []
        if !invalid.isEmpty {
            let names = invalid.compactMap { $0["name"] as? String }.prefix(5).joined(separator: ", ")
            throw IDEACPAdapterError.untrusted("npm reports an invalid signature or attestation for: \(names).")
        }
        let missing = (root["missing"] as? [[String: Any]]) ?? []
        let missingNames = missing.compactMap { $0["name"] as? String }
        if missingNames.contains(package) {
            throw IDEACPAdapterError.untrusted("npm found no signature for \(package).")
        }
        guard missingNames.isEmpty else {
            return ["\(missingNames.count) dependenc\(missingNames.count == 1 ? "y has" : "ies have") no registry signature: \(missingNames.prefix(3).joined(separator: ", "))."]
        }
        return []
    }
}
