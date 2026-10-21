import EditorIntelligence
import Foundation

/// Show Siblings (IntelliJ): for the method at the caret, the other implementations of the
/// methods it overrides or implements, so a change to one can be compared with its neighbours.
enum JavaGoToSiblings {
    static func resolve(
        source: String,
        fileURL: URL?,
        utf16Offset: Int,
        index: JavaIndex,
        jdkHome: URL?,
        cacheRoot: URL,
        openBuffer: (@Sendable (URL) async -> String?)?
    ) async -> [JavaDefinitionHit] {
        guard let tree = JavaSyntaxParser().parse(source) else { return [] }
        let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: utf16Offset, in: source)
        // Siblings are project sources, so there is never a reason to decompile.
        let session = JavaNavigationSession(
            source: source, fileURL: fileURL, tree: tree, byteOffset: byteOffset,
            index: index, jdkHome: jdkHome, cacheRoot: cacheRoot, openBuffer: openBuffer,
            decompile: JavaDecompileGate(policy: .denied)
        )
        return await session.siblingHits()
    }
}

extension JavaNavigationSession {
    func siblingHits() async -> [JavaDefinitionHit] {
        guard let found = await methodAtCaret() else { return [] }
        let supers = await JavaSuperMethods.overridden(
            method: found.method, owner: found.owner,
            stub: { await self.liveStub($0) },
            supertypes: { await self.directSupertypes(of: $0) }
        )
        guard !supers.isEmpty else { return [] }

        // The declaration the caret's method itself lives at, which is not its own sibling.
        let own = await methodHits([MethodTarget(declaringClass: found.owner, method: found.method)])
        let excluded = Set(own.map(Self.key))

        var hits: [JavaDefinitionHit] = []
        for target in supers {
            hits.append(contentsOf: await implementationHits(forMethod: target))
        }
        return dedupe(hits).filter { !excluded.contains(Self.key($0)) }
    }

    private static func key(_ hit: JavaDefinitionHit) -> String {
        "\(hit.url?.standardizedFileURL.path ?? "")#\(hit.range.start.utf16Offset)"
    }
}
