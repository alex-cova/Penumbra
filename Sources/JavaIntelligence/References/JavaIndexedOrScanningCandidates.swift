import Foundation

/// Candidate source that asks the name index about roots it has a loaded shard for, and scans the
/// rest of the roots on disk. When a role index is present, indexed roots are narrowed by role
/// first: only files that use the name in a matching role are parsed and resolved.
public struct JavaIndexedOrScanningCandidates: JavaUsageCandidateSource {
    public let nameIndex: JavaNameIndex?
    public let roleIndex: JavaRoleIndex?
    public let scan: JavaTextScanCandidateSource

    public init(
        nameIndex: JavaNameIndex?, roleIndex: JavaRoleIndex? = nil,
        scan: JavaTextScanCandidateSource = JavaTextScanCandidateSource()
    ) {
        self.nameIndex = nameIndex
        self.roleIndex = roleIndex
        self.scan = scan
    }

    public func candidateFiles(containing identifier: String, in roots: [URL]) async -> [URL] {
        await candidateFiles(containing: identifier, roles: .all, in: roots)
    }

    public func candidateFiles(
        containing identifier: String, roles: JavaIdentifierRoles, in roots: [URL]
    ) async -> [URL] {
        guard let nameIndex else { return await scan.candidateFiles(containing: identifier, in: roots) }
        var indexed: [URL] = []
        var roleNarrowed: [URL] = []
        var unindexed: [URL] = []
        for root in roots {
            if await nameIndex.indexedFileCount(in: root) != nil {
                // A root the role index has not built yet keeps the name index's answer: a
                // missing role shard must never narrow anything out.
                if let roleIndex, !roles.isEmpty, await roleIndex.indexedFileCount(in: root) != nil {
                    roleNarrowed.append(root)
                } else {
                    indexed.append(root)
                }
            } else {
                unindexed.append(root)
            }
        }
        var found = Set<String>()
        if !indexed.isEmpty {
            for url in await nameIndex.candidateFiles(containing: identifier, in: indexed) { found.insert(url.standardizedFileURL.path) }
        }
        if !roleNarrowed.isEmpty, let roleIndex {
            for url in await roleIndex.candidateFiles(containing: identifier, roles: roles, in: roleNarrowed) {
                found.insert(url.standardizedFileURL.path)
            }
        }
        if !unindexed.isEmpty {
            for url in await scan.candidateFiles(containing: identifier, in: unindexed) { found.insert(url.standardizedFileURL.path) }
        }
        return found.sorted().map { URL(fileURLWithPath: $0) }
    }
}
