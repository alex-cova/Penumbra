import CryptoKit
import Foundation
import SubprocessKit

/// An Eclipse Temurin release that can be installed: where it comes from and what it must hash to.
struct IDETemurinRelease: Equatable, Sendable {
    let featureVersion: Int
    /// `21.0.13.1+2`: the release's full version.
    let version: String
    let archiveName: String
    let downloadURL: URL
    /// Lowercase hex SHA-256 of the archive, from the release metadata.
    let checksum: String
    let size: Int64

    /// The name of the installed bundle: `temurin-21.0.13.1_2.jdk`. Only characters that cannot leave the
    /// install directory.
    var bundleName: String {
        let safe = version.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") ? String($0) : "_" }.joined()
        return "temurin-\(safe).jdk"
    }
}

enum IDEJDKInstallError: Error, Equatable, LocalizedError {
    case unsupportedArchitecture
    case noRelease(featureVersion: Int)
    case untrustedSource(String)
    case malformedMetadata
    case downloadFailed(String)
    case checksumMismatch
    case extractionFailed(String)
    case invalidArchive(String)
    case alreadyInstalled(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture: "This Mac's processor has no Temurin build."
        case .noRelease(let version): "Adoptium lists no Temurin \(version) for this Mac."
        case .untrustedSource(let host): "The download came from \(host), which is not an Eclipse Adoptium host. It was not used."
        case .malformedMetadata: "The release information from Adoptium was not in the expected form."
        case .downloadFailed(let reason): "The download failed: \(reason)"
        case .checksumMismatch: "The downloaded file does not match the checksum Adoptium published. It was discarded."
        case .extractionFailed(let reason): "The archive could not be unpacked: \(reason)"
        case .invalidArchive(let reason): "The archive is not a JDK: \(reason)"
        case .alreadyInstalled: "This JDK is already installed."
        }
    }
}

/// What the installer needs from the network, so the whole flow runs offline in tests.
protocol IDEJDKInstallerNetwork: Sendable {
    func release(featureVersion: Int, architecture: String) async throws -> IDETemurinRelease
    /// Downloads `url` to a temporary file and returns it with the URL the data finally came from (after redirects).
    func download(_ url: URL) async throws -> (file: URL, finalURL: URL)
}

/// Downloads and installs an Eclipse Temurin JDK into `~/Library/Java/JavaVirtualMachines`, where the app already
/// looks for JDKs and where no administrator rights are needed.
///
/// Only ever run for an explicit click. The source is pinned (`api.adoptium.net`, with the archive on Adoptium's
/// GitHub release host), the download must match the SHA-256 Adoptium publishes, and nothing is visible in the
/// install directory until the archive has been unpacked and checked: it is staged elsewhere and moved in whole.
struct IDEJDKInstaller: Sendable {
    let network: any IDEJDKInstallerNetwork
    let installDirectory: URL
    let stagingDirectory: URL

    init(
        network: any IDEJDKInstallerNetwork = IDEAdoptiumNetwork(),
        installDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Java/JavaVirtualMachines"),
        stagingDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Umbra/JDKStaging", isDirectory: true)
    ) {
        self.network = network
        self.installDirectory = installDirectory
        self.stagingDirectory = stagingDirectory
    }

    static var currentArchitecture: String? {
        #if arch(arm64)
        "aarch64"
        #elseif arch(x86_64)
        "x64"
        #else
        nil
        #endif
    }

    /// Hosts a release's archive may come from. Adoptium publishes to GitHub, which serves the file from its own CDN.
    static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return ["github.com", "githubusercontent.com", "adoptium.net"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func isChecksum(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// The installed bundle (`….jdk`), after checking and moving it in.
    @discardableResult
    func install(featureVersion: Int) async throws -> URL {
        guard let architecture = Self.currentArchitecture else { throw IDEJDKInstallError.unsupportedArchitecture }
        let release = try await network.release(featureVersion: featureVersion, architecture: architecture)
        guard Self.isTrusted(release.downloadURL) else {
            throw IDEJDKInstallError.untrustedSource(release.downloadURL.host ?? release.downloadURL.absoluteString)
        }
        guard Self.isChecksum(release.checksum), release.featureVersion == featureVersion else { throw IDEJDKInstallError.malformedMetadata }
        let destination = installDirectory.appendingPathComponent(release.bundleName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw IDEJDKInstallError.alreadyInstalled(destination) }

        let work = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let downloaded: (file: URL, finalURL: URL)
        do {
            downloaded = try await network.download(release.downloadURL)
        } catch let error as IDEJDKInstallError {
            throw error
        } catch {
            throw IDEJDKInstallError.downloadFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: downloaded.file) }
        // Redirects must stay on trusted hosts too.
        guard Self.isTrusted(downloaded.finalURL) else {
            throw IDEJDKInstallError.untrustedSource(downloaded.finalURL.host ?? downloaded.finalURL.absoluteString)
        }
        guard try Self.sha256(of: downloaded.file) == release.checksum.lowercased() else { throw IDEJDKInstallError.checksumMismatch }

        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try await Self.extract(downloaded.file, into: extracted)
        let home = try Self.locateBundle(in: extracted, featureVersion: featureVersion)

        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        // The staging area is on the same volume as the home folder, so this is one rename: never half an install.
        try FileManager.default.moveItem(at: home, to: destination)
        return destination
    }

    // MARK: - Steps

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func extract(_ archive: URL, into directory: URL) async throws {
        var request = SubprocessRequest(executable: "/usr/bin/tar", arguments: ["-xzf", archive.path, "-C", directory.path])
        request.timeout = .seconds(300)
        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(request)
        } catch {
            throw IDEJDKInstallError.extractionFailed(error.localizedDescription)
        }
        guard result.exit.status == 0, !result.timedOut, !result.cancelled else {
            throw IDEJDKInstallError.extractionFailed(String(decoding: result.stderr.data, as: UTF8.self).prefix(300).description)
        }
    }

    /// The one top-level folder of the archive (`jdk-21.0.13.1+2`), once it holds a working JDK of the wanted
    /// feature version: `Contents/Home/bin/java` and a `release` file saying so.
    static func locateBundle(in directory: URL, featureVersion: Int) throws -> URL {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )) ?? []
        guard entries.count == 1, let top = entries.first,
              (try? top.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))?.isDirectory == true,
              (try? top.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
            throw IDEJDKInstallError.invalidArchive("expected one folder, found \(entries.map(\.lastPathComponent))")
        }
        let home = top.appendingPathComponent("Contents/Home", isDirectory: true)
        let java = home.appendingPathComponent("bin/java")
        guard FileManager.default.isExecutableFile(atPath: java.path) else {
            throw IDEJDKInstallError.invalidArchive("no bin/java in Contents/Home")
        }
        let release = (try? String(contentsOf: home.appendingPathComponent("release"), encoding: .utf8)) ?? ""
        guard release.split(separator: "\n").contains(where: { line in
            guard line.hasPrefix("JAVA_VERSION=") else { return false }
            let value = line.dropFirst("JAVA_VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            return value == "\(featureVersion)" || value.hasPrefix("\(featureVersion).") || value.hasPrefix("\(featureVersion)+")
                || (featureVersion <= 8 && value.hasPrefix("1.\(featureVersion)"))
        }) else {
            throw IDEJDKInstallError.invalidArchive("its release file does not say Java \(featureVersion)")
        }
        return top
    }
}

/// The real network: Adoptium's release API for what to install, then the archive itself.
struct IDEAdoptiumNetwork: IDEJDKInstallerNetwork {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func release(featureVersion: Int, architecture: String) async throws -> IDETemurinRelease {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.adoptium.net"
        components.path = "/v3/assets/latest/\(featureVersion)/hotspot"
        components.queryItems = [
            URLQueryItem(name: "architecture", value: architecture), URLQueryItem(name: "image_type", value: "jdk"),
            URLQueryItem(name: "os", value: "mac"), URLQueryItem(name: "vendor", value: "eclipse"),
        ]
        guard let url = components.url else { throw IDEJDKInstallError.malformedMetadata }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw IDEJDKInstallError.downloadFailed("the release service answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try Self.parseRelease(data, featureVersion: featureVersion)
    }

    /// The tar.gz release in Adoptium's `assets/latest` answer.
    static func parseRelease(_ data: Data, featureVersion: Int) throws -> IDETemurinRelease {
        struct Asset: Decodable {
            struct Version: Decodable { let openjdk_version: String; let major: Int }
            struct Binary: Decodable {
                struct Package: Decodable { let name: String; let link: String; let checksum: String; let size: Int64 }
                let package: Package
                let image_type: String
                let os: String
            }
            let binary: Binary
            let version: Version
        }
        guard let assets = try? JSONDecoder().decode([Asset].self, from: data) else { throw IDEJDKInstallError.malformedMetadata }
        guard let asset = assets.first(where: {
            $0.binary.image_type == "jdk" && $0.binary.os == "mac" && $0.version.major == featureVersion
                && $0.binary.package.name.hasSuffix(".tar.gz")
        }), let link = URL(string: asset.binary.package.link) else { throw IDEJDKInstallError.noRelease(featureVersion: featureVersion) }
        let version = asset.version.openjdk_version.split(separator: "-").first.map(String.init) ?? asset.version.openjdk_version
        return IDETemurinRelease(
            featureVersion: featureVersion, version: version, archiveName: asset.binary.package.name, downloadURL: link,
            checksum: asset.binary.package.checksum.lowercased(), size: asset.binary.package.size
        )
    }

    func download(_ url: URL) async throws -> (file: URL, finalURL: URL) {
        let (file, response) = try await session.download(for: URLRequest(url: url, timeoutInterval: 120))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let final = response.url else {
            try? FileManager.default.removeItem(at: file)
            throw IDEJDKInstallError.downloadFailed("the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return (file, final)
    }
}
