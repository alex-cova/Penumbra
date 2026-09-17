import Foundation

/// All requirements are already satisfied by internal members on `TextInputView` (`lineManager`,
/// `stringView`, `theme`, `indentStrategy`, `textContainerInset`, `syntaxParseGeneration`) and the
/// three forwarders declared next to `isSyntaxTreeReady` in `TextInputView.swift`. Keeping the
/// conformance here documents the seam and lets tests substitute a fake `MinimapContentSource`.
extension TextInputView: MinimapContentSource {}
