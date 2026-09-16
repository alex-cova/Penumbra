import Foundation

/**
 * Provider for meta data of layout algorithms and layout options.
 */
package protocol ILayoutMetaDataProvider {

    /**
     * Apply this provider by registering all contained meta data into the given registry instance.
     */
    func apply(_ registry: ILayoutMetaDataProvider_Registry)
}

/**
 * Registry for layout meta data. Extracted from ILayoutMetaDataProvider since
 * Swift does not support nested protocols.
 */
package protocol ILayoutMetaDataProvider_Registry {

    /**
     * Register a layout algorithm.
     */
    func register(_ algorithmData: LayoutAlgorithmData)

    /**
     * Register a layout option.
     */
    func register(_ optionData: LayoutOptionData)

    /**
     * Register a layout category.
     */
    func register(_ categoryData: LayoutCategoryData)

    /**
     * Specify a dependency between two layout options.
     */
    func addDependency(_ sourceOption: String, _ targetOption: String, _ requiredValue: Any?)

    /**
     * Specify support of a layout algorithm for the given layout option.
     */
    func addOptionSupport(_ algorithm: String, _ option: String, _ defaultValue: Any?)
}

// Backwards compatibility: allow code that references ILayoutMetaDataProvider.Registry
extension ILayoutMetaDataProvider {
    package typealias Registry = ILayoutMetaDataProvider_Registry
}
