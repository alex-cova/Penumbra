import Foundation

/**
 * A pool for class instances. The pool can hold a configurable number of instances of the class.
 *
 * @param T the type of instances that are held by this pool
 */
package final class InstancePool<T> {

    /** the instance factory to use for this pool. */
    package let factory: IFactory
    /** the list of currently held instances. */
    private var instances: [T] = []
    /** the configured instance limit. */
    package var limit: Int
    /** lock used for synchronization. */
    package let lock: NSLock = NSLock()

    /**
     * Create an instance pool with an infinite capacity.
     *
     * @param factory the instance factory
     */
    package convenience init(_ factory: IFactory) {
        self.init(factory, -1)
    }

    /**
     * Create an instance pool with given capacity.
     *
     * @param factory the instance factory
     * @param limit the maximal number of instances that shall be kept in the pool
     */
    package init(_ factory: IFactory, _ limit: Int) {
        self.factory = factory
        self.limit = limit
    }

    /**
     * Create an instance pool with a provider factory (AlgorithmFactory).
     */
    package init(providerFactory factory: IFactory, limit: Int = -1) {
        self.factory = factory
        self.limit = limit
    }

    /**
     * Fetch an instance from the pool. If no instance is available, a new one is created.
     *
     * @return a class instance
     */
    package func fetch() -> T {
        lock.lock()
        defer { lock.unlock() }

        if instances.isEmpty {
            let created = factory.create()
            if let instance = created as? T {
                return instance
            }
            fatalError("InstancePool: factory created \(type(of: created)) but expected \(T.self)")
        }
        return instances.removeFirst()
    }

    /**
     * Release an instance into the pool to be used again unless the pool's capacity is already reached.
     *
     * @param obj a class instance
     */
    package func release(_ obj: T) {
        lock.lock()
        defer { lock.unlock() }

        if limit < 0 || instances.count < limit {
            instances.append(obj)
        } else {
            factory.destroy(obj)
        }
    }

    /**
     * Clear the instance pool by disposing all instances that are currently held.
     */
    package func clear() {
        lock.lock()
        defer { lock.unlock() }

        for obj in instances {
            factory.destroy(obj)
        }
        instances.removeAll()
    }
}
