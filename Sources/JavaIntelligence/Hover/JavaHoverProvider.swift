import EditorIntelligence
import Foundation

/// Hover for Java: the declaration of the symbol under the caret and its Javadoc.
///
/// A caret that just rests on an identifier (`.idle`) only gets a popup when there is
/// documentation to show, so the popup doesn't chase every caret move. An explicit request
/// (`.manual`, Quick Documentation) always shows the signature. Attached sources supply Javadoc
/// for the JDK and for dependencies; a `.class` file is never decompiled for a hover.
public actor JavaHoverProvider: HoverProvider {
    public let name = "JavaHover"
    private let index: JavaIndex
    private let indexPaths: JavaIndexPaths
    private var classpathModel: JavaGradleProjectModel?
    private var classpathPaths: JavaIndexPaths?
    private var jdkHome: URL?
    private var openBuffer: (@Sendable (URL) async -> String?)?

    public init(index: JavaIndex, indexPaths: JavaIndexPaths) {
        self.index = index
        self.indexPaths = indexPaths
    }

    public func setSourceSetClasspath(_ model: JavaGradleProjectModel?, indexPaths: JavaIndexPaths) {
        classpathModel = model
        classpathPaths = model == nil ? nil : indexPaths
    }

    public func setJDKHome(_ home: URL?) {
        jdkHome = home
    }

    public func setOpenBufferLookup(_ lookup: (@Sendable (URL) async -> String?)?) {
        openBuffer = lookup
    }

    public func provide(context: HoverContext) async -> HoverResult? {
        guard context.document.languageIdentifier == "java" else { return nil }
        let source = JavaNavigationText.fullText(of: context.document)
        guard !source.isEmpty else { return nil }
        let utf16Offset = context.cursor.position.utf16Offset
        let lookup = openBuffer
        let home = jdkHome
        let cacheRoot = indexPaths.root
        let resolve = { () async -> JavaHoverContent? in
            await JavaHover.resolve(
                source: source,
                fileURL: context.document.url,
                utf16Offset: utf16Offset,
                index: self.index,
                jdkHome: home,
                cacheRoot: cacheRoot,
                openBuffer: lookup
            )
        }
        let content: JavaHoverContent?
        if let scope = scope(for: context.document.url) {
            content = await JavaIndex.$queryScope.withValue(scope) {
                await JavaMemberLookup.$sourceTextProvider.withValue(lookup) { await resolve() }
            }
        } else {
            content = await JavaMemberLookup.$sourceTextProvider.withValue(lookup) { await resolve() }
        }
        guard let content else { return nil }
        if context.trigger == .idle, !content.hasDocumentation { return nil }
        return HoverResult(
            contents: content.markdown,
            range: JavaNavigationText.textRange(for: content.byteRange, in: source),
            source: name
        )
    }

    private func scope(for file: URL?) -> Set<String>? {
        guard let file, let classpathModel, let classpathPaths else { return nil }
        return classpathModel.visibleShardPaths(forFile: file, paths: classpathPaths)
    }
}
