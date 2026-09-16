import Foundation

/**
 * A generic factory for layout algorithms.
 */
package class AlgorithmFactory: IFactory {

    /** The class for which instances shall be created. */
    package let clazz: AbstractLayoutProvider.Type
    /** The parameter used for initialization of layout providers. */
    package let parameter: String?

    /**
     * Creates an instance factory for the given layout provider class.
     *
     * @param theclazz the class for which instances shall be created
     */
    package convenience init(_ theclazz: AbstractLayoutProvider.Type) {
        self.init(theclazz, parameter: nil)
    }

    /**
     * Creates an instance factory for the given layout provider class, initialized with a parameter.
     *
     * @param theclazz the class for which instances shall be created
     * @param theparameter the parameter used for initialization of layout providers
     */
    package init(_ theclazz: AbstractLayoutProvider.Type, parameter: String?) {
        self.clazz = theclazz
        self.parameter = parameter
    }

    package func create() -> Any {
        let algorithm = clazz.init()
        algorithm.initialize(parameter ?? "")
        return algorithm
    }

    package func destroy(_ obj: Any) {
        if let provider = obj as? AbstractLayoutProvider {
            provider.dispose()
        }
    }
}

package class Exception: Error {
    package let message: String
    package init(message: String) {
        self.message = message
    }
}
