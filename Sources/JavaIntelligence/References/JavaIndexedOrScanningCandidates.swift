import Foundation

/// Candidate source that asks the name index about roots it has a loaded shard for, and scans the
/// rest of the roots on disk.
public struct JavaIndexedOrScanningCandidates: JavaUsageCandidateSource {
    public let nameIndex: JavaNameIndex?
    public let scan: JavaTextScanCandidateSource

    public init(nameIndex: JavaNameIndex?, scan: JavaTextScanCandidateSource = JavaTextScanCandidateSource()) {
        self.nameIndex = nameIndex
        self.scan = scan
    }

    public func candidateFiles(containing identifier: String, in roots: [URL]) async -> [URL] {
        guard let nameIndex else { return await scan.candidateFiles(containing: identifier, in: roots) }
        var indexed: [URL] = []
        var unindexed: [URL] = []
        for root in roots {
            if await nameIndex.indexedFileCount(in: root) != nil {
                indexed.append(root)
            } else {
                unindexed.append(root)
            }
        }
        var found = Set<String>()
        if !indexed.isEmpty {
            for url in await nameIndex.candidateFiles(containing: identifier, in: indexed) { found.insert(url.standardizedFileURL.path) }
        }
        if !unindexed.isEmpty {
            for url in await scan.candidateFiles(containing: identifier, in: unindexed) { found.insert(url.standardizedFileURL.path) }
        }
        return found.sorted().map { URL(fileURLWithPath: $0) }
    }
}
