/// The module every preview thunk and the host share (`UmbraPreviewSupport`), compiled once per
/// work directory into a dylib the host links and the thunks import.
///
/// - `UmbraPreview.content()`: what the canvas shows. It is compiled `dynamic` (the module is built
///   with `-enable-implicit-dynamic`) and every thunk replaces it with its own preview.
/// - `UmbraReload.epoch`: the root view's identity. `reset()` makes the root create its content
///   again, so after a reload nothing keeps the metadata of the types it replaced.
///
/// A reload never replaces a member of the user's types in place: SwiftUI caches a view type's
/// `Body` at first use and aborts when a replaced `body` has another concrete type
/// (`docs/SWIFTUI_PREVIEW_PLAN.md`, P2). Each thunk holds its own copy of the file instead.
public enum SwiftPreviewSupportSource {
    public static let moduleName = "UmbraPreviewSupport"
    public static let fileName = "UmbraPreviewSupport.swift"
    /// Part of the directory name: a change to the source below must change this.
    public static let version = 3

    public static let text = #"""
    import Observation
    import SwiftUI

    @Observable
    public final class UmbraReload: @unchecked Sendable {
        public static let shared = UmbraReload()
        public var epoch = 0
        /// Create the content again.
        public func reset() { epoch += 1 }
    }

    public enum UmbraPreview {
        /// Replaced by the loaded thunk.
        public static func content() -> AnyView { AnyView(EmptyView()) }
    }

    public struct UmbraPreviewRoot: View {
        public init() {}
        public var body: some View {
            UmbraPreview.content().id(UmbraReload.shared.epoch)
        }
    }
    """#
}
