import Foundation

/**
 * Base class for classes that want to randomly access a list of elements. Access to non-existent list elements is
 * explicitly permitted. The list is automatically enlarged by adding enough default values for the requested elements
 * to exist. Subclasses must implement `provideDefault()` to provide these default values.
 * 
 * @param T type of elements in the list.
 */
package class AbstractRandomListAccessor<T> {
    
    /** The list which contains all the elements. */
    package var list: [T]
    
    
    /**
     * Creates a new instance.
     */
    package init() {
        list = []
    }
    

    /**
     * Provides a default value for list items. This method is called whenever the list must be enlarged to be able
     * to access an element at a given index.
     * 
     * @return a default element.
     */
    package func provideDefault() -> T {
        fatalError("Subclasses must implement provideDefault() — no safe default for generic T")
    }
    
    /**
     * Returns the list item at the given index. This method is always guaranteed to return an element, provided that
     * the index is at least zero.
     * 
     * @param index the element's index.
     * @return the element at the given index.
     * @throws IndexOutOfBoundsException if the index is negative.
     */
    final func getListItem(_ index: Int) -> T {
        guard index >= 0 else {
            assertionFailure("Invalid index: \(index)")
            return provideDefault()
        }

        ensureListSize(size: index + 1)
        return list[index]
    }
    
    /**
     * Sets the list element at the given index. If the index does not exist yet, the list is enlarged appropriately.
     * 
     * @param index the element's index.
     * @param value the new element.
     * @throws IndexOutOfBoundsException if the index is negative.
     */
    final func setListItem(_ index: Int, _ value: T) {
        guard index >= 0 else {
            assertionFailure("Invalid index: \(index)")
            return
        }
        
        if index < list.count {
            list[index] = value
        } else {
            // Avoid creating a new default value which will be immediately overwritten anyway
            ensureListSize(size: index)
            list.append(value)
        }
    }
    
    /**
     * Returns the number of elements currently in the list.
     * 
     * @return number of elements.
     */
    final func getListSize() -> Int {
        return list.count
    }
    
    /**
     * Removes all items from the list.
     */
    package func clearList() {
        list.removeAll()
    }
    
    /**
     * Ensures that the list has the given size by adding enough default elements.
     * 
     * @param size the list's new size.
     */
    package func ensureListSize(size: Int) {
        for _ in list.count..<size {
            list.append(provideDefault())
        }
    }
    
}
