import Foundation

/**
 * A factory that uses a creator closure to create instances.
 *
 * @param T type of instances that are created by this factory
 */
package final class DefaultFactory<T>: IFactory {

    /** the creator closure. */
    package let creator: () -> T

    /**
     * Creates an instance factory with a creator closure.
     *
     * @param creator a closure that creates instances of T
     */
    package init(_ creator: @escaping () -> T) {
        self.creator = creator
    }

    package func create() -> Any {
        return creator()
    }

    package func destroy(_ obj: Any) {
        // do nothing by default
    }
}
