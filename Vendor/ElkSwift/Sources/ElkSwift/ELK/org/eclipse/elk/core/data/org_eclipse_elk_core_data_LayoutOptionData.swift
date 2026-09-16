// Copyright (c) 2009, 2017 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

import Foundation

// MARK: - LayoutOptionData

/// Data type used to store information for a layout option.
package final class LayoutOptionData: ILayoutMetaData, IProperty, Hashable {

    // MARK: - OptionType (renamed from Type to avoid Swift conflict)

    /// Enumeration of data types for layout options.
    package enum OptionType: String {
        /// undefined type.
        case UNDEFINED
        /// boolean type.
        case BOOLEAN
        /// integer type.
        case INT
        /// string type.
        case STRING
        /// double type.
        case DOUBLE
        /// enumeration type.
        case ENUM
        /// enumeration set type.
        case ENUMSET
        /// IDataObject type.
        case OBJECT
    }

    // MARK: - Target

    /// Enumeration of target elements for layout options.
    package enum Target: String, Hashable {
        /// parents target (hierarchical nodes).
        case PARENTS
        /// nodes target.
        case NODES
        /// edges target.
        case EDGES
        /// ports target.
        case PORTS
        /// labels target.
        case LABELS
    }

    // MARK: - Visibility

    /// Enumeration of visibility options for layout options.
    package enum Visibility: String {
        /// The option shall always be visible in the UI.
        case VISIBLE
        /// The option shall be visible only for advanced users.
        case ADVANCED
        /// The option shall never be visible in the UI.
        case HIDDEN
    }

    // MARK: - Properties

    /// identifier of the layout option.
    package let id: String
    /// the group this layout option is associated with. Note that the group is included in the `id`.
    package let group: String
    /// legacy identifiers of this option.
    package let legacyIds: [String]?
    /// the default value of this option.
    package let defaultValue: Any?
    /// the class that represents this option type.
    package let clazz: AnyClass?
    /// type of the layout option.
    package let type: OptionType
    /// user friendly name of the layout option.
    package let name: String
    /// a description to be displayed in the UI.
    package let optionDescription: String
    /// configured targets.
    package let targets: Set<Target>
    /// dependencies to other layout options.
    package var dependencies: [Pair<LayoutOptionData, Any>] = []
    /// cached value of the available choices.
    package var choices: [String]?
    /// visibility in the UI.
    package let visibility: Visibility
    /// the lower bound for option values.
    package var lowerBound: Any?
    /// the upper bound for option values.
    package var upperBound: Any?

    // MARK: - ILayoutMetaData conformance

    /// description property required by ILayoutMetaData
    package var description: String { return optionDescription }

    // MARK: - Initializer

    /// Create a layout option data entry.
    private init(builder: Builder) {
        self.id = builder.id
        self.group = builder.group
        self.name = builder.name
        self.optionDescription = builder.optionDescription
        self.defaultValue = builder.defaultValue
        self.lowerBound = builder.lowerBound
        self.upperBound = builder.upperBound
        self.type = builder.type
        self.clazz = builder.clazz

        if let targets = builder.targets {
            self.targets = targets
        } else {
            self.targets = []
        }

        self.visibility = builder.visibility
        self.legacyIds = builder.legacyIds
    }

    /// Convenience initializer that creates a LayoutOptionData with just an id.
    package convenience init(id: String) {
        let b = Builder()
        _ = b.id(id)
        self.init(builder: b)
    }

    // MARK: - Private Methods

    /// Checks whether the enumeration class is set correctly.
    package func checkEnumClass() {
        guard let _ = clazz else {
            assertionFailure("Enumeration class expected for layout option \(id)")
            return
        }
    }

    /// Checks whether the IDataType class is set correctly and creates an instance.
    package func createDataInstance() throws -> Any {
        guard let clazz = clazz else {
            throw ELK.Error.runtimeError("IDataType class expected for layout option \(id)")
        }
        // ElkReflect is not available in the Swift port.
        // Return a default instance for known data types.
        if clazz == KVector.self || "\(clazz)" == "KVector" {
            return KVector()
        }
        if clazz == KVectorChain.self || "\(clazz)" == "KVectorChain" {
            return KVectorChain()
        }
        throw ELK.Error.runtimeError("Couldn't create new instance of property '\(id)'. ElkReflect is not available in Swift.")
    }

    /// Tries to turn the given string representation into an enumeration.
    package func enumForString(_ leString: String) -> Any? {
        guard let clazz = clazz, let enumType = clazz as? AnyEnum.Type else {
            return nil
        }

        // Try to parse as enum case name
        if let value = enumType.init(rawValue: leString) {
            return value
        }

        // Try to parse as enum index
        if let index = Int(leString) {
            let mirror = Mirror(reflecting: enumType)
            guard mirror.displayStyle == .enum else {
                return nil
            }

            let children = Array(mirror.children)
            guard index >= 0 && index < children.count else {
                return nil
            }

            return children[index].value
        }

        return nil
    }

    /// Tries to turn the given string representation into a set.
    package func enumSetForStringArray<T: RawRepresentable>(leClazz: T.Type, leString: String) -> Set<T>? where T.RawValue == String, T: Hashable {
        var set = Set<T>()

        let components = leString.components(separatedBy: CharacterSet(charactersIn: "[] ,")).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        for component in components {
            if let value = enumForString(component) as? T {
                set.insert(value)
            } else {
                return nil
            }
        }

        return set
    }

    // MARK: - Hashable / Equatable

    package static func == (lhs: LayoutOptionData, rhs: LayoutOptionData) -> Bool {
        return lhs.id == rhs.id
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: - Public Methods

    /// Checks whether or not the `parseValue(_:)` will be conceivably able to parse Strings.
    package func canParseValue() -> Bool {
        switch type {
        case .UNDEFINED:
            return false
        case .OBJECT:
            guard let _ = clazz else { return false }
            return true
        default:
            return true
        }
    }

    /// Parses a string value for this layout option.
    package func parseValue(_ valueString: String) -> Any? {
        if valueString.isEmpty || valueString == "null" {
            return nil
        }

        if valueString.isEmpty && type != .ENUMSET {
            return nil
        }

        switch type {
        case .BOOLEAN:
            if valueString.lowercased() == "true" {
                return true
            } else if valueString.lowercased() == "false" {
                return false
            } else {
                return nil
            }
        case .INT:
            return Int(valueString)
        case .DOUBLE:
            return Double(valueString)
        case .STRING:
            return valueString
        case .ENUM:
            checkEnumClass()
            return enumForString(valueString)
        case .ENUMSET:
            checkEnumClass()
            return nil // Would need concrete enum type
        case .OBJECT:
            return nil // Would need IDataObject parsing
        case .UNDEFINED:
            return nil
        }
    }

    /// Creates a default-default value for this layout option.
    package func getDefaultDefault() -> Any? {
        switch type {
        case .STRING:
            return ""
        case .BOOLEAN:
            return false
        case .INT:
            return 0
        case .DOUBLE:
            return 0.0
        case .ENUM:
            return nil
        case .ENUMSET:
            return nil
        case .OBJECT:
            return nil
        case .UNDEFINED:
            return nil
        }
    }

    /// Creates an array of choices.
    package func getChoices() -> [String] {
        if choices == nil {
            switch type {
            case .ENUM, .ENUMSET:
                checkEnumClass()
                guard let clazz = clazz, let enumType = clazz as? AnyEnum.Type else {
                    choices = []
                    return []
                }

                let mirror = Mirror(reflecting: enumType)
                choices = mirror.children.map { String(describing: $0.value) }

            case .BOOLEAN:
                choices = ["false", "true"]

            default:
                choices = []
            }
        }

        return choices ?? []
    }

    /// Returns the number of items in the enumeration class.
    package func getEnumValueCount() -> Int {
        switch type {
        case .ENUM, .ENUMSET:
            checkEnumClass()
            guard let clazz = clazz, let enumType = clazz as? AnyEnum.Type else {
                return 0
            }

            let mirror = Mirror(reflecting: enumType)
            return mirror.children.count

        default:
            return 0
        }
    }

    /// Returns the enumeration value for a given index.
    package func getEnumValue(intValue: Int) -> Any? {
        switch type {
        case .ENUM, .ENUMSET:
            checkEnumClass()
            guard let clazz = clazz, let enumType = clazz as? AnyEnum.Type else {
                return nil
            }

            let mirror = Mirror(reflecting: enumType)
            let children = Array(mirror.children)
            guard intValue >= 0 && intValue < children.count else {
                return nil
            }

            return children[intValue].value

        default:
            return nil
        }
    }

    /// Returns the set of layout option targets.
    package func getTargets() -> Set<Target> {
        return targets
    }

    /// Returns the dependencies to other layout options.
    package func getDependencies() -> [Pair<LayoutOptionData, Any>] {
        return dependencies
    }

    /// Returns the type.
    package func getType() -> OptionType {
        return type
    }

    /// Returns the name.
    package func getName() -> String {
        return name
    }

    /// Returns the description.
    package func getDescription() -> String {
        return optionDescription
    }

    /// Returns the default value of this layout option.
    package func getDefault() -> Any? {
        return defaultValue
    }

    /// Returns the lower bound for layout option values.
    package func getLowerBound() -> Any? {
        return lowerBound
    }

    /// Sets the lower bound for layout option values.
    package func setLowerBound(_ lowerBound: Any?) {
        self.lowerBound = lowerBound
    }

    /// Returns the upper bound for layout option values.
    package func getUpperBound() -> Any? {
        return upperBound
    }

    /// Sets the upper bound for layout option values.
    package func setUpperBound(_ upperBound: Any?) {
        self.upperBound = upperBound
    }

    /// Returns the option type class.
    package func getOptionClass() -> AnyClass? {
        return clazz
    }

    /// Returns the visibility of this option in the UI.
    package func getVisibility() -> Visibility {
        return visibility
    }

    /// Returns the legacyIds.
    package func getLegacyIds() -> [String]? {
        return legacyIds
    }
}

// MARK: - Builder

extension LayoutOptionData {
    /// Builder for `LayoutOptionData` instances.
    package class Builder {

        package var id: String = ""
        package var group: String = ""
        package var legacyIds: [String]?
        package var defaultValue: Any?
        package var clazz: AnyClass?
        package var type: OptionType = .UNDEFINED
        package var name: String = ""
        package var optionDescription: String = ""
        package var targets: Set<Target>?
        package var visibility: Visibility = .VISIBLE
        package var lowerBound: Any?
        package var upperBound: Any?

        package init() {}

        /// Create an instance with the configured values.
        package func create() -> LayoutOptionData {
            return LayoutOptionData(builder: self)
        }

        /// Configure the `id`.
        @discardableResult
        package func id(_ aid: String) -> Builder {
            self.id = aid
            return self
        }

        /// Configure the `group`.
        @discardableResult
        package func group(_ agroup: String) -> Builder {
            self.group = agroup
            return self
        }

        /// Configure the `legacyIds`.
        @discardableResult
        package func legacyIds(_ alegacyIds: [String]) -> Builder {
            self.legacyIds = alegacyIds
            return self
        }

        /// Configure the `defaultValue`.
        @discardableResult
        package func defaultValue(_ adefaultValue: Any?) -> Builder {
            self.defaultValue = adefaultValue
            return self
        }

        /// Configure the `optionClass`.
        @discardableResult
        package func optionClass(_ aclazz: AnyClass?) -> Builder {
            self.clazz = aclazz
            return self
        }

        /// Configure the `type`.
        @discardableResult
        package func type(_ atype: OptionType) -> Builder {
            self.type = atype
            return self
        }

        /// Configure the `name`.
        @discardableResult
        package func name(_ aname: String) -> Builder {
            self.name = aname
            return self
        }

        /// Configure the `description`.
        @discardableResult
        package func description(_ adescription: String) -> Builder {
            self.optionDescription = adescription
            return self
        }

        /// Configure the `targets`.
        @discardableResult
        package func targets(_ atargets: Set<Target>) -> Builder {
            self.targets = atargets
            return self
        }

        /// Configure the `visibility`.
        @discardableResult
        package func visibility(_ avisibility: Visibility) -> Builder {
            self.visibility = avisibility
            return self
        }

        /// Configure the `lowerBound`.
        @discardableResult
        package func lowerBound(_ alowerBound: Any?) -> Builder {
            self.lowerBound = alowerBound
            return self
        }

        /// Configure the `upperBound`.
        @discardableResult
        package func upperBound(_ aupperBound: Any?) -> Builder {
            self.upperBound = aupperBound
            return self
        }
    }
}

// MARK: - Helper Protocols
package protocol AnyEnum: RawRepresentable where RawValue == String {}

// MARK: - Pair
