import Foundation

/**
 Thrown when a layout algorithm is executed on a graph that has properties set on it that are not
 supported by the algorithm.
 */
package class UnsupportedConfigurationException: RuntimeException {

    package static let serialVersionUID: Int64 = -3617468773969103109

    /**
     Create an unsupported graph configuration exception with no parameters.
     */
    package override init(_ message: String = "") {
        super.init(message)
    }
}
