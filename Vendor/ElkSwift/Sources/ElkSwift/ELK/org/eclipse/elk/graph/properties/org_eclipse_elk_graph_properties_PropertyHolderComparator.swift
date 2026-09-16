package struct PropertyHolderComparator {
    package let property: IProperty

    private init(_ property: IProperty) {
        self.property = property
    }

    package static func with(_ property: IProperty) -> PropertyHolderComparator {
        return PropertyHolderComparator(property)
    }

    package func compare(_ ph1: any IPropertyHolder, _ ph2: any IPropertyHolder) -> Int {
        let p1 = ph1.getProperty(property)
        let p2 = ph2.getProperty(property)

        if p1 != nil && p2 != nil {
            return 0
        } else if p1 != nil {
            return -1
        } else if p2 != nil {
            return 1
        } else {
            return 0
        }
    }
}
