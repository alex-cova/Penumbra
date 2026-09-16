import Foundation

/**
 * Data type used to store information for a layout algorithm.
 */
package final class LayoutAlgorithmData: ILayoutMetaData, Hashable {

    /** identifier of the layout provider. */
    package let id: String
    /** user friendly name of the layout algorithm. */
    package let name: String
    /** runtime instance of the layout algorithm. */
    package let providerPool: InstancePool<AbstractLayoutProvider>
    /** layout category identifier. */
    package let category: String
    /** name of the bundle of which this algorithm is part of. */
    package let melkBundleName: String
    /** id of the (eclipse) bundle in which the melk file resides. */
    package let definingBundleId: String
    /** detail description. */
    package let algorithmDescription: String
    /** a path to a preview image for displaying in user interfaces. */
    package let imagePath: String
    /** Set of supported graph features. */
    package let supportedFeatures: Set<GraphFeature>
    /** Validator that can be applied to input graphs before the algorithm is executed. */
    package let validatorClass: AnyClass?

    /** Map of known layout options. Keys are option IDs, values are the default values. */
    package var knownOptions: [String: Any] = [:]

    // MARK: - ILayoutMetaData conformance
    package var description: String { return algorithmDescription }

    /**
     * Create a layout algorithm data entry.
     */
    private init(builder: Builder) {
        self.id = builder.id
        self.name = builder.name
        self.algorithmDescription = builder.algorithmDescription
        guard let factory = builder.providerFactory else {
            fatalError("LayoutAlgorithmData requires a providerFactory to be set on the Builder")
        }
        self.providerPool = InstancePool(providerFactory: factory)
        self.category = builder.category
        self.melkBundleName = builder.melkBundleName
        self.definingBundleId = builder.definingBundleId
        self.imagePath = builder.imagePath
        self.supportedFeatures = builder.supportedFeatures ?? []
        self.validatorClass = builder.validatorClass
    }

    package func equals(_ obj: Any) -> Bool {
        guard let other = obj as? LayoutAlgorithmData else { return false }
        return self.id == other.id
    }

    package static func == (lhs: LayoutAlgorithmData, rhs: LayoutAlgorithmData) -> Bool {
        return lhs.id == rhs.id
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /**
     * Sets the knowledge status of the given layout option.
     */
    package func addKnownOption(_ property: IProperty, defaultValue: Any?) {
        knownOptions[property.id] = defaultValue
    }

    /**
     * Returns the set of IDs of layout options declared to be known by this algorithm.
     */
    package func getKnownOptionIds() -> Set<String> {
        return Set(knownOptions.keys)
    }

    /**
     * Determines whether the layout algorithm knows the given layout option.
     */
    package func knowsOption(_ property: IProperty) -> Bool {
        return knowsOption(property.id)
    }

    /**
     * Determines whether the layout algorithm knows the given layout option.
     */
    package func knowsOption(_ propertyId: String) -> Bool {
        return knownOptions.keys.contains(propertyId)
    }

    /**
     * Returns the layout algorithm's default value for the given option.
     */
    package func getDefaultValue(_ property: IProperty) -> Any? {
        return getDefaultValue(property.id)
    }

    /**
     * Returns the layout algorithm's default value for the given option.
     */
    package func getDefaultValue(_ propertyId: String) -> Any? {
        return knownOptions[propertyId]
    }

    /**
     * Check whether the given graph feature is supported.
     */
    package func supportsFeature(_ graphFeature: GraphFeature) -> Bool {
        return supportedFeatures.contains(graphFeature)
    }

    package func getSupportedFeatures() -> Set<GraphFeature> {
        return supportedFeatures
    }

    package func getId() -> String {
        return id
    }

    package func getName() -> String {
        return name
    }

    package func getDescription() -> String {
        return algorithmDescription
    }

    package func getInstancePool() -> InstancePool<AbstractLayoutProvider> {
        return providerPool
    }

    package func getValidatorClass() -> AnyClass? {
        return validatorClass
    }

    package func getCategoryId() -> String {
        return category
    }

    package func getBundleName() -> String {
        return melkBundleName
    }

    package func getDefiningBundleId() -> String {
        return definingBundleId
    }

    package func getPreviewImagePath() -> String {
        return imagePath
    }

    /**
     * Builder for `LayoutAlgorithmData` instances.
     */
    package class Builder {

        package var id: String = ""
        package var name: String = ""
        package var providerFactory: IFactory?
        package var category: String = ""
        package var melkBundleName: String = ""
        package var definingBundleId: String = ""
        package var algorithmDescription: String = ""
        package var imagePath: String = ""
        package var supportedFeatures: Set<GraphFeature>?
        package var validatorClass: AnyClass?

        package init() {}

        package func create() -> LayoutAlgorithmData {
            return LayoutAlgorithmData(builder: self)
        }

        @discardableResult
        package func id(_ aid: String) -> Builder {
            self.id = aid
            return self
        }

        @discardableResult
        package func name(_ aname: String) -> Builder {
            self.name = aname
            return self
        }

        @discardableResult
        package func providerFactory(_ aproviderFactory: IFactory) -> Builder {
            self.providerFactory = aproviderFactory
            return self
        }

        @discardableResult
        package func category(_ acategory: String) -> Builder {
            self.category = acategory
            return self
        }

        @discardableResult
        package func melkBundleName(_ amelkBundleName: String) -> Builder {
            self.melkBundleName = amelkBundleName
            return self
        }

        @discardableResult
        package func definingBundleId(_ adefiningBundleId: String) -> Builder {
            self.definingBundleId = adefiningBundleId
            return self
        }

        @discardableResult
        package func description(_ adescription: String) -> Builder {
            self.algorithmDescription = adescription
            return self
        }

        @discardableResult
        package func imagePath(_ aimagePath: String) -> Builder {
            self.imagePath = aimagePath
            return self
        }

        @discardableResult
        package func supportedFeatures(_ asupportedFeatures: Set<GraphFeature>) -> Builder {
            self.supportedFeatures = asupportedFeatures
            return self
        }

        @discardableResult
        package func validatorClass(_ avalidator: AnyClass?) -> Builder {
            self.validatorClass = avalidator
            return self
        }

    }

}
