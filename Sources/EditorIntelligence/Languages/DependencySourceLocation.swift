import Foundation

/// Files the editor opens only to be read: code a language server generated for something the project
/// does not own. Navigation works on them; nothing checks them.
public enum DependencySourceLocation {
    /// A Swift interface SourceKit-LSP wrote for a symbol in the SDK or a dependency
    /// (`<temporary folder>/sourcekit-lsp/GeneratedInterfaces/<hash>/Swift.String.swiftinterface`).
    ///
    /// Judged by path components, not by prefix: the server reports the same folder as `/var/…` or
    /// `/private/var/…`, and `standardizedFileURL` does not settle that on every system. A `.swiftinterface`
    /// anywhere else, even in a project, is the user's own file.
    public static func isGeneratedInterface(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard let folder = components.lastIndex(of: "sourcekit-lsp"), folder + 1 < components.count else { return false }
        return components[folder + 1] == "GeneratedInterfaces"
    }
}
