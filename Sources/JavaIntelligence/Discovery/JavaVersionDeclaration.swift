import Foundation

/// A literal version-manager declaration. The value is used for matching installed JDKs.
public struct JavaVersionDeclaration: Sendable, Equatable {
    public static let fileNames: Set<String> = [".sdkmanrc", ".tool-versions", ".java-version"]

    public let utf16Offset: Int
    public let value: String
    public let requirement: Requirement?

    public struct Requirement: Sendable, Equatable {
        public let version: String
        public let featureVersion: Int
        public let vendor: String?

        public func matches(_ installation: JDKInstallation) -> Bool {
            guard installation.featureVersion == featureVersion else { return false }
            let installedVersion = installation.versionString
            guard installedVersion == version || installedVersion.hasPrefix(version + ".")
                    || installedVersion.hasPrefix(version + "+") else { return false }
            guard let vendor else { return true }
            return installation.vendor.map { JDKInstallation.shortVendorName($0).lowercased().contains(vendor) } == true
        }
    }

    public static func parse(fileName: String, source: String) -> [Self] {
        guard Self.fileNames.contains(fileName), source.utf16.count <= 65_536 else { return [] }
        let text = source as NSString
        var results: [Self] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { line, range, _, stop in
            guard let line else { return }
            let body = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { return }
            let token: String
            switch fileName {
            case ".sdkmanrc":
                let fields = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard fields.first?.trimmingCharacters(in: .whitespaces) == "java" else { return }
                token = fields.count == 2 ? fields[1].trimmingCharacters(in: .whitespaces) : ""
            case ".tool-versions":
                let fields = body.split(whereSeparator: \.isWhitespace)
                guard fields.first == "java" else { return }
                // Multiple entries express fallback policy. Surface it for review.
                token = fields.dropFirst().joined(separator: " ")
            default:
                token = body
            }
            results.append(Self(utf16Offset: range.location, value: token, requirement: parseRequirement(token)))
            if results.count >= 32 { stop.pointee = true }
        }
        return results
    }

    private static func parseRequirement(_ text: String) -> Requirement? {
        guard text.utf8.count <= 80, !text.isEmpty else { return nil }
        let aliases = [
            "tem": "temurin", "temurin": "temurin", "amzn": "corretto", "corretto": "corretto",
            "zulu": "zulu", "ms": "microsoft", "microsoft": "microsoft", "librca": "liberica", "oracle": "oracle",
        ]
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let version: String
        let vendor: String?
        if parts.count == 1 {
            version = parts[0]
            vendor = nil
        } else if let name = aliases[parts[0]] {
            version = parts[1]
            vendor = name
        } else if let name = aliases[parts[1]] {
            version = parts[0]
            vendor = name
        } else {
            return nil
        }
        guard version.range(of: #"\A[0-9]+(?:\.[0-9]+)*(?:\+[0-9]+)?\z"#, options: .regularExpression) != nil,
              let feature = ReleaseFileParser.featureVersion(from: version), feature >= 8 else { return nil }
        return Requirement(version: version, featureVersion: feature, vendor: vendor)
    }
}
