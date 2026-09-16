import Foundation

/**
 * Data type used to store information for a layout category.
 */
package final class LayoutCategoryData: Equatable, Hashable {

    /** identifier of the layout type. */
    package let id: String
    /** user friendly name of the layout type. */
    package let name: String
    /** detail description. */
    package let categoryDescription: String
    /** the list of layout algorithms that are registered for this category. */
    package let layouters: [LayoutAlgorithmData]

    // ILayoutMetaData-like conformance
    package var description: String { return categoryDescription }

    /**
     * Create a layout category data entry.
     */
    private init(builder: Builder) {
        self.id = builder.id ?? ""
        self.name = builder.name ?? ""
        self.categoryDescription = builder.categoryDescription ?? ""
        self.layouters = []
    }

    package static func == (lhs: LayoutCategoryData, rhs: LayoutCategoryData) -> Bool {
        return lhs.id == rhs.id
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    package func getLayouters() -> [LayoutAlgorithmData] {
        return layouters
    }

    package func getId() -> String {
        return id
    }

    package func getName() -> String {
        return name
    }

    package func getDescription() -> String {
        return categoryDescription
    }

    /**
     * Builder for `LayoutCategoryData` instances.
     */
    package struct Builder {

        package var id: String?
        package var name: String?
        package var categoryDescription: String?

        package init() {}

        package func create() -> LayoutCategoryData {
            return LayoutCategoryData(builder: self)
        }

        @discardableResult
        package mutating func id(_ aid: String) -> Self {
            self.id = aid
            return self
        }

        @discardableResult
        package mutating func name(_ aname: String) -> Self {
            self.name = aname
            return self
        }

        @discardableResult
        package mutating func description(_ adescription: String) -> Self {
            self.categoryDescription = adescription
            return self
        }

    }

}
