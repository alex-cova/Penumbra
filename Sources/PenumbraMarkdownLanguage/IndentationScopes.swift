import Penumbra

public extension TreeSitterIndentationScopes {
    static var markdown: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(
            indent: [
                "list_item",
                "block_quote"
            ],
            whitespaceDenotesBlocks: true)
    }
}
