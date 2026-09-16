// Copyright (c) 2008, 2020 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

import Foundation
import os

// MARK: - Supporting Types

/// Simple triple for storing dependency/support data
package class DependencyTriple {
    package var firstId: String = ""
    package var secondId: String = ""
    package var value: Any?
    package init() {}
}

// MARK: - Main Service

package final class LayoutMetaDataService {
    private nonisolated(unsafe) static var _instance: LayoutMetaDataService?
    private static let _lock: os_unfair_lock_t = {
        let lock = os_unfair_lock_t.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        return lock
    }()

    /// Thread-safe access to the singleton. Auto-initializes on first access.
    package static var instance: LayoutMetaDataService {
        os_unfair_lock_lock(_lock)
        defer { os_unfair_lock_unlock(_lock) }
        if let inst = _instance { return inst }
        let inst = LayoutMetaDataService()
        _instance = inst
        return inst
    }

    // All six maps are mutated on read-paths (suffix caches) and on registration.
    // Accessing them without synchronization from multiple render threads caused
    // EXC_BAD_ACCESS crashes in Dictionary's subscript. Every access now goes
    // through `_stateLock`.
    private let _stateLock: os_unfair_lock_t = {
        let lock = os_unfair_lock_t.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        return lock
    }()

    private var layoutAlgorithmMap = [String: LayoutAlgorithmData]()
    private var layoutOptionMap = [String: LayoutOptionData]()
    private var legacyLayoutOptionMap = [String: LayoutOptionData]()
    private var layoutCategoryMap = [String: LayoutCategoryData]()
    private var algorithmSuffixMap = [String: LayoutAlgorithmData]()
    private var optionSuffixMap = [String: LayoutOptionData]()

    private init() {
        LayoutMetaDataService.initElkReflect()
    }

    deinit {
        _stateLock.deinitialize(count: 1)
        _stateLock.deallocate()
    }

    // `os_unfair_lock` is non-reentrant. Methods that take the lock must not
    // call other methods that also take it; composing methods call only locked
    // entry points without taking the lock themselves.
    @inline(__always)
    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(_stateLock)
        defer { os_unfair_lock_unlock(_stateLock) }
        return body()
    }

    package static func getInstance(loader: Any? = nil) -> LayoutMetaDataService {
        return instance
    }

    package static func unload() {
        os_unfair_lock_lock(_lock)
        defer { os_unfair_lock_unlock(_lock) }
        _instance = nil
    }

    package static func initElkReflect() {
        // Register types with ElkReflect for property cloning support
        // Uses the (type, newFun:, cloneFun:) signature from ElkReflect
    }

    // MARK: - Registration

    package func registerAlgorithm(_ algorithmData: LayoutAlgorithmData) {
        withLock { layoutAlgorithmMap[algorithmData.id] = algorithmData }
    }

    package func registerOption(_ optionData: LayoutOptionData) {
        withLock {
            layoutOptionMap[optionData.id] = optionData
            if let legacyIds = optionData.getLegacyIds() {
                for legacyId in legacyIds {
                    legacyLayoutOptionMap[legacyId] = optionData
                }
            }
        }
    }

    package func registerCategory(_ categoryData: LayoutCategoryData) {
        withLock { layoutCategoryMap[categoryData.id] = categoryData }
    }

    package func registerLayoutMetaDataProviders(_ providers: ILayoutMetaDataProvider...) {
        for provider in providers {
            let registry = Registry()
            registry.service = self
            provider.apply(registry)
            registry.applyDependencies()
        }
        withLock { optionSuffixMap.removeAll() }
    }

    // MARK: - Queries

    package func getAlgorithmData(_ id: String) -> LayoutAlgorithmData? {
        withLock { layoutAlgorithmMap[id] }
    }

    package func getAlgorithmData() -> [LayoutAlgorithmData] {
        withLock { Array(layoutAlgorithmMap.values) }
    }

    package func getAlgorithmData(by suffix: String) -> LayoutAlgorithmData? {
        guard !suffix.isEmpty else { return nil }
        return withLock {
            if let data = algorithmSuffixMap[suffix] {
                return data
            }

            var data: LayoutAlgorithmData?
            for d in layoutAlgorithmMap.values {
                let id = d.getId()
                if id.hasSuffix(suffix) && (suffix.count == id.count || id[id.index(id.endIndex, offsetBy: -suffix.count - 1)] == ".") {
                    if data != nil {
                        return nil
                    }
                    data = d
                }
            }

            if let found = data {
                algorithmSuffixMap[suffix] = found
            }

            return data
        }
    }

    /// Alias for callers using the old name
    package func getAlgorithmDataBySuffix(_ suffix: String?) -> LayoutAlgorithmData? {
        guard let suffix = suffix else { return nil }
        return getAlgorithmData(by: suffix)
    }

    package func getAlgorithmData(bySuffixOrDefault algorithmId: String?, defaultId: String?) -> LayoutAlgorithmData? {
        // Composes locked calls — must not take the lock itself.
        if let algorithmId = algorithmId, !algorithmId.trimmingCharacters(in: .whitespaces).isEmpty {
            if let data = getAlgorithmData(by: algorithmId) {
                return data
            }
        }

        if let defaultId = defaultId, !defaultId.trimmingCharacters(in: .whitespaces).isEmpty {
            if let data = getAlgorithmData(by: defaultId) {
                return data
            }
        }

        return nil
    }

    /// Alias for callers using old name
    package func getAlgorithmDataBySuffixOrDefault(_ suffix: String?, _ defaultID: String?) -> LayoutAlgorithmData? {
        return getAlgorithmData(bySuffixOrDefault: suffix, defaultId: defaultID)
    }

    package func getOptionData(_ id: String) -> LayoutOptionData? {
        withLock {
            if let data = layoutOptionMap[id] {
                return data
            }
            return legacyLayoutOptionMap[id]
        }
    }

    package func getOptionData() -> [LayoutOptionData] {
        withLock { Array(layoutOptionMap.values) }
    }

    package func getOptionData(by suffix: String) -> LayoutOptionData? {
        guard !suffix.isEmpty else { return nil }
        return withLock {
            if let data = optionSuffixMap[suffix] {
                return data
            }

            var data: LayoutOptionData?

            for d in layoutOptionMap.values {
                let id = d.id
                if id.hasSuffix(suffix) && (suffix.count == id.count || id[id.index(id.endIndex, offsetBy: -suffix.count - 1)] == ".") {
                    if data != nil {
                        return nil
                    }
                    data = d
                }
            }

            if data == nil {
                for d in layoutOptionMap.values {
                    if let legacyIds = d.getLegacyIds() {
                        for id in legacyIds {
                            if id.hasSuffix(suffix) && (suffix.count == id.count || id[id.index(id.endIndex, offsetBy: -suffix.count - 1)] == ".") {
                                if data != nil {
                                    return nil
                                }
                                data = d
                            }
                        }
                    }
                }
            }

            if let found = data {
                optionSuffixMap[suffix] = found
            }

            return data
        }
    }

    /// Alias for callers using bySuffix: label
    package func getOptionData(bySuffix suffix: String) -> LayoutOptionData? {
        return getOptionData(by: suffix)
    }

    package func getOptionData(for algorithm: LayoutAlgorithmData, targetType: LayoutOptionData.Target) -> [LayoutOptionData] {
        withLock {
            var result = [LayoutOptionData]()
            for option in layoutOptionMap.values {
                if algorithm.knowsOption(option.id) || CoreOptions.ALGORITHM.id == option.id {
                    if option.getTargets().contains(targetType) {
                        result.append(option)
                    }
                }
            }
            return result
        }
    }

    package func getCategoryData(_ id: String) -> LayoutCategoryData? {
        withLock { layoutCategoryMap[id] }
    }

    package func getCategoryData() -> [LayoutCategoryData] {
        withLock { Array(layoutCategoryMap.values) }
    }

    // MARK: - Registry

    package class Registry: ILayoutMetaDataProvider_Registry {

        package weak var service: LayoutMetaDataService?

        package var optionDependencies = [DependencyTriple]()
        package var optionSupport = [DependencyTriple]()

        package init() {}

        package func register(_ algorithmData: LayoutAlgorithmData) {
            service?.registerAlgorithm(algorithmData)
        }

        package func register(_ optionData: LayoutOptionData) {
            service?.registerOption(optionData)
        }

        package func register(_ categoryData: LayoutCategoryData) {
            service?.registerCategory(categoryData)
        }

        package func addDependency(_ sourceOption: String, _ targetOption: String, _ requiredValue: Any?) {
            let triple = DependencyTriple()
            triple.firstId = sourceOption
            triple.secondId = targetOption
            triple.value = requiredValue
            optionDependencies.append(triple)
        }

        package func addOptionSupport(_ algorithm: String, _ option: String, _ defaultValue: Any?) {
            let triple = DependencyTriple()
            triple.firstId = algorithm
            triple.secondId = option
            triple.value = defaultValue
            optionSupport.append(triple)
        }

        package func applyDependencies() {
            // Uses locked accessors on the service. The per-object mutations
            // below (dependencies.append / addKnownOption) happen only during
            // registration, which is serialized by ELK.registerAlgorithmsIfNeeded's
            // _registrationLock — so no reader observes a partial state.
            for dep in optionDependencies {
                if let source = service?.getOptionData(dep.firstId),
                   let target = service?.getOptionData(dep.secondId) {
                    if let value = dep.value {
                        source.dependencies.append(Pair(first: target, second: value))
                    }
                }
            }

            for sup in optionSupport {
                if let algorithm = service?.getAlgorithmData(sup.firstId),
                   let option = service?.getOptionData(sup.secondId) {
                    algorithm.addKnownOption(option, defaultValue: sup.value)
                }
            }
        }
    }
}


// MARK: - Supporting Protocols and Classes

package protocol ILayoutMetaDataProviderRegistry {
    func register(_ algorithmData: LayoutAlgorithmData)
    func register(_ optionData: LayoutOptionData)
    func register(_ categoryData: LayoutCategoryData)
    func addDependency(_ sourceOption: String, _ targetOption: String, _ requiredValue: Any?)
    func addOptionSupport(_ algorithm: String, _ option: String, _ defaultValue: Any?)
}

extension LayoutMetaDataService.Registry: ILayoutMetaDataProviderRegistry {}
