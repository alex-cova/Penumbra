import Foundation

/**
 * Allows to reroute access to properties through other property constants which may provide different default values.
 */
package final class PropertyConstantsDelegator {

    /** Set of property constants to be used for accessing their respective property. */
    package var propertyDelegates: [String: IProperty] = [:]

    // MARK: - Creation

    private init() {}

    package static func createEmpty() -> PropertyConstantsDelegator {
        return PropertyConstantsDelegator()
    }

    package static func createForLayoutAlgorithmData(_ algorithmData: LayoutAlgorithmData) -> PropertyConstantsDelegator {
        let delegator = PropertyConstantsDelegator()

        for optionId in algorithmData.getKnownOptionIds() {
            let defaultValue = algorithmData.getDefaultValue(optionId)
            let delegate = Property<Any>(optionId, defaultValue: defaultValue as Any)
            delegator.addDelegate(delegate)
        }

        return delegator
    }

    package static func createForLayoutAlgorithmWithId(_ algorithmId: String) -> PropertyConstantsDelegator {
        guard let algorithmData = LayoutMetaDataService.getInstance().getAlgorithmData(algorithmId) else {
            return createEmpty()
        }
        return createForLayoutAlgorithmData(algorithmData)
    }

    // MARK: - Configuration

    @discardableResult
    package func addDelegate(_ delegate: IProperty) -> PropertyConstantsDelegator {
        propertyDelegates[delegate.id] = delegate
        return self
    }

    // MARK: - Getters

    package func getPropertyOrDelegate(_ property: IProperty) -> IProperty {
        if let actualProperty = propertyDelegates[property.id] {
            return actualProperty
        } else {
            return property
        }
    }

    // MARK: - Property Access

    package func getProperty(_ propertyHolder: IPropertyHolder, _ property: IProperty) -> Any? {
        return propertyHolder.getProperty(getPropertyOrDelegate(property))
    }

    package func getProperty(_ adapter: any GraphElementAdapter, _ property: IProperty) -> Any? {
        return adapter.getProperty(getPropertyOrDelegate(property))
    }

    package func getIndividualOrInheritedProperty(_ node: ElkNode, _ property: IProperty) -> Any? {
        return IndividualSpacings.getIndividualOrInherited(node, getPropertyOrDelegate(property))
    }

    package func getIndividualOrInheritedProperty(_ nodeAdapter: any NodeAdapterProtocol, _ property: IProperty) -> Any? {
        return IndividualSpacings.getIndividualOrInherited(nodeAdapter, getPropertyOrDelegate(property))
    }
}
