/*******************************************************************************
 * Copyright (c) 2020 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 ******************************************************************************/

// NOTE: This file contains complex Java generics (self-referential builder pattern)
// that don't translate cleanly to Swift. Stubbed out for now.
// The ElkSpacings utility is only used for convenient spacing configuration,
// not for core layout algorithm functionality.

package final class ElkSpacings {
    private init() {}

    package static func withBaseValue(_ baseSpacing: Double) -> ElkCoreSpacingsBuilder {
        return ElkCoreSpacingsBuilder(baseSpacing: baseSpacing)
    }

    package final class ElkCoreSpacingsBuilder {
        package let baseSpacing: Double
        package var overwrite: Bool = false
        private var factorMap: [String: Double] = [:]

        package init(baseSpacing: Double) {
            self.baseSpacing = baseSpacing
        }

        package func withFactor(spacingOption: IProperty, factor: Double) -> ElkCoreSpacingsBuilder {
            factorMap[spacingOption.id] = factor
            return self
        }

        package func withValue(spacingOption: IProperty, value: Double) -> ElkCoreSpacingsBuilder {
            factorMap[spacingOption.id] = value / baseSpacing
            return self
        }

        package func withOverwrite(shallOverwrite: Bool) -> ElkCoreSpacingsBuilder {
            self.overwrite = shallOverwrite
            return self
        }

        package func apply(holder: IPropertyHolder) {
            for (key, factor) in factorMap {
                holder.setProperty(key, factor * baseSpacing)
            }
        }
    }
}
