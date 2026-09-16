import Foundation

/**
 * Interface for holders of property values.
 */
package protocol IPropertyHolder: AnyObject {

    @discardableResult
    func setProperty(_ property: IProperty, _ value: Any?) -> Self

    func getProperty(_ property: IProperty) -> Any?

    func hasProperty(_ property: IProperty) -> Bool

    @discardableResult
    func copyProperties(_ holder: IPropertyHolder) -> Self

    func getAllProperties() -> [String: Any]

    // String-key overloads
    @discardableResult
    func setProperty(_ key: String, _ value: Any?) -> Self
    func getProperty(_ key: String) -> Any?
    func hasProperty(_ key: String) -> Bool
}

// MARK: - Convenience overloads

extension IPropertyHolder {
    @discardableResult
    package func copyProperties(from holder: IPropertyHolder) -> Self {
        return copyProperties(holder)
    }

    /// Typed getter (optional): casts the Any? result to T?.
    package func getProperty<T>(_ property: IProperty) -> T? {
        if let value = (getProperty(property) as Any?) as? T {
            return value
        }
        return property.defaultValue as? T
    }

    /// Labeled-parameter overload: `getProperty(option:)`
    package func getProperty(option property: IProperty) -> Any? {
        return getProperty(property)
    }

    /// Labeled-parameter overload for setProperty(option:_:)
    @discardableResult
    package func setProperty(option property: IProperty, _ value: Any?) -> Self {
        return setProperty(property, value)
    }

    /// Labeled-parameter overload: `setProperty(prop, value: val)`
    @discardableResult
    package func setProperty(_ property: IProperty, value: Any?) -> Self {
        return setProperty(property, value)
    }

}

// MARK: - Default value helper

@inline(__always)
internal func _defaultValue<T>(for type: T.Type) throws -> T {
    switch type {
    case is Bool.Type:
        guard let value = false as? T else { throw ELK.Error.runtimeError("Type mismatch") }
        return value
    case is Int.Type:
        guard let value = 0 as? T else { throw ELK.Error.runtimeError("Type mismatch") }
        return value
    case is Double.Type:
        guard let value = 0.0 as? T else { throw ELK.Error.runtimeError("Type mismatch") }
        return value
    case is Float.Type:
        guard let value = Float(0) as? T else { throw ELK.Error.runtimeError("Type mismatch") }
        return value
    case is String.Type:
        guard let value = "" as? T else { throw ELK.Error.runtimeError("Type mismatch") }
        return value
    default:
        throw ELK.Error.runtimeError("No property value and no default for type \(T.self)")
    }
}
