/*******************************************************************************
 * Copyright (c) 2020 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 ******************************************************************************/

import Foundation

/**
 * Replaces (and removes) any deprecated layout options from CoreOptions with a corresponding new layout option.
 */
package class DeprecatedLayoutOptionReplacer: IGraphElementVisitor {

    package init() {}

    /**
     * Rule to replace CoreOptions.PORT_LABELS_NEXT_TO_PORT_IF_POSSIBLE.
     */
    @available(*, deprecated, message: "Deprecated")
    package static let nextToPortIfPossible: (ElkGraphElement) -> Void = { e in
        var portLabels = e.getProperty(CoreOptions.PORT_LABELS_PLACEMENT) as? PortLabelPlacement ?? PortLabelPlacement()
        portLabels.insert(.nextToPortIfPossible)
        e.setProperty(CoreOptions.PORT_LABELS_PLACEMENT, portLabels)
        e.setProperty(CoreOptions.PORT_LABELS_NEXT_TO_PORT_IF_POSSIBLE, nil)
    }

    /**
     * Rule to move the deprecated SizeOptions.spaceEfficientPortLabels to PortLabelPlacement.
     */
    @available(*, deprecated, message: "Deprecated")
    package static let spaceEfficient: (ElkGraphElement) -> Void = { e in
        if var sizeOpts = e.getProperty(CoreOptions.NODE_SIZE_OPTIONS) as? SizeOptions,
           sizeOpts.contains(.spaceEfficientPortLabels) {
            var portLabels = e.getProperty(CoreOptions.PORT_LABELS_PLACEMENT) as? PortLabelPlacement ?? PortLabelPlacement()
            portLabels.insert(.spaceEfficient)
            e.setProperty(CoreOptions.PORT_LABELS_PLACEMENT, portLabels)
            sizeOpts.remove(.spaceEfficientPortLabels)
            e.setProperty(CoreOptions.NODE_SIZE_OPTIONS, sizeOpts)
        }
    }

    /**
     * Mapping of deprecated layout options to replacing rules.
     */
    @available(*, deprecated, message: "Deprecated")
    package static let rules: [(IProperty, (ElkGraphElement) -> Void)] = [
        (CoreOptions.PORT_LABELS_NEXT_TO_PORT_IF_POSSIBLE, nextToPortIfPossible),
        (CoreOptions.NODE_SIZE_OPTIONS, spaceEfficient)
    ]

    private static let activeRules: [(IProperty, (ElkGraphElement) -> Void)] = [
        (CoreOptions.PORT_LABELS_NEXT_TO_PORT_IF_POSSIBLE, { e in
            var portLabels = e.getProperty(CoreOptions.PORT_LABELS_PLACEMENT) as? PortLabelPlacement ?? PortLabelPlacement()
            portLabels.insert(.nextToPortIfPossible)
            e.setProperty(CoreOptions.PORT_LABELS_PLACEMENT, portLabels)
            e.setProperty(CoreOptions.PORT_LABELS_NEXT_TO_PORT_IF_POSSIBLE, nil)
        }),
        (CoreOptions.NODE_SIZE_OPTIONS, { e in
            if var sizeOpts = e.getProperty(CoreOptions.NODE_SIZE_OPTIONS) as? SizeOptions,
               sizeOpts.contains(SizeOptions(rawValue: 1 << 6)) {
                var portLabels = e.getProperty(CoreOptions.PORT_LABELS_PLACEMENT) as? PortLabelPlacement ?? PortLabelPlacement()
                portLabels.insert(.spaceEfficient)
                e.setProperty(CoreOptions.PORT_LABELS_PLACEMENT, portLabels)
                sizeOpts.remove(SizeOptions(rawValue: 1 << 6))
                e.setProperty(CoreOptions.NODE_SIZE_OPTIONS, sizeOpts)
            }
        })
    ]

    package func visit(_ element: ElkGraphElement) {
        for (option, replacer) in Self.activeRules {
            if element.hasProperty(option) {
                replacer(element)
            }
        }
    }

}
