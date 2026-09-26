import Foundation

/// Aggregates folding providers, preferring a primary provider when one claims the document.
public actor FoldingEngine {
    private let providers: [FoldingProviding]

    public init(providers: [FoldingProviding]) {
        self.providers = providers
    }

    public func foldRegions(for document: Document) async -> [FoldingDescriptor] {
        let active = providers(for: document)
        var all: [FoldingDescriptor] = []
        await withTaskGroup(of: [FoldingDescriptor].self) { group in
            for provider in active {
                group.addTask {
                    await provider.foldRegions(for: document)
                }
            }
            for await descriptors in group {
                all.append(contentsOf: descriptors)
            }
        }
        return all.sorted {
            if $0.range.start.utf16Offset != $1.range.start.utf16Offset {
                return $0.range.start.utf16Offset < $1.range.start.utf16Offset
            }
            return $0.range.end.utf16Offset < $1.range.end.utf16Offset
        }
    }

    private func providers(for document: Document) -> [FoldingProviding] {
        let primary = providers.filter { $0.isPrimary(for: document.languageIdentifier) }
        return primary.isEmpty ? providers : primary
    }
}
