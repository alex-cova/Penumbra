/**
 * Container protocol for edges that represent external edges.
 */
package protocol IExternalExtension {
    /// The underlying edge representative.
    var representative: Any { get }

    /// The rectangle that represents the external extension.
    var representor: ElkRectangle { get }

    /// An optional placeholder along the original diagram's boundary.
    var placeholder: ElkRectangle? { get }

    /// The rectangle to which this extension connects.
    var parent: ElkRectangle { get }

    /// The direction into which this extension points.
    var direction: Direction { get }
}

// Default implementation for placeholder
extension IExternalExtension {
    package var placeholder: ElkRectangle? {
        return nil
    }
}
