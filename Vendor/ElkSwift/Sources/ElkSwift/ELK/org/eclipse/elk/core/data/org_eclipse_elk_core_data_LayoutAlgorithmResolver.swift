/*******************************************************************************
 * Copyright (c) 2018, 2020 TypeFox GmbH and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 ******************************************************************************/


/**
 * Resolves layout algorithms configured through the CoreOptions.ALGORITHM option and assigns
 * the resulting meta data to the CoreOptions.RESOLVED_ALGORITHM option.
 */
package class LayoutAlgorithmResolver: IGraphElementVisitor {

    package init() {}

    package func visit(_ element: ElkGraphElement) throws {
        if let node = element as? ElkNode {
            let noLayout: Bool = node.getProperty(CoreOptions.NO_LAYOUT) as? Bool ?? false
            if !noLayout {
                try resolveAlgorithm(node)
            }
        }
    }

    package func resolveAlgorithm(_ node: ElkNode) throws {
        let algorithmId: String? = node.getProperty(CoreOptions.ALGORITHM) as? String

        // Stage 1: Try to resolve the intended algorithm
        if resolveAndSetAlgorithm(algorithmId, node) {
            return
        }

        // Stage 2: If we must resolve a layout algorithm, try to fall back on the default if none was specified
        if mustResolve(node) {
            if let id = algorithmId, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // An algorithm was specified, but not found. Fail!
                var message = "Layout algorithm '"
                message.append(id)
                message.append("' not found for ")
                ElkUtil.printElementPath(node, builder: &message)
                throw ELK.Error.runtimeError(message)
            } else {
                // No algorithm was specified, load the default one
                let defaultAlgorithmId = getDefaultLayoutAlgorithmID()

                if !resolveAndSetAlgorithm(defaultAlgorithmId, node) {
                    var message = "Unable to load default layout algorithm "
                    message.append(defaultAlgorithmId)
                    message.append(" for unconfigured node ")
                    ElkUtil.printElementPath(node, builder: &message)
                    throw ELK.Error.runtimeError(message)
                }
            }
        }
    }

    @discardableResult
    package func resolveAndSetAlgorithm(_ algorithmId: String?, _ node: ElkNode) -> Bool {
        guard let algorithmId = algorithmId else { return false }
        let algorithmData = LayoutMetaDataService.getInstance().getAlgorithmData(by: algorithmId)

        if let algorithmData = algorithmData {
            node.setProperty(CoreOptions.RESOLVED_ALGORITHM, algorithmData)
            return true
        } else {
            return false
        }
    }

    package func mustResolve(_ node: ElkNode) -> Bool {
        let hasResolved = node.hasProperty(CoreOptions.RESOLVED_ALGORITHM)
        let hasChildren = !node.children.isEmpty
        let insideSelfLoops: Bool = node.getProperty(CoreOptions.INSIDE_SELF_LOOPS_ACTIVATE) as? Bool ?? false
        return !hasResolved && (hasChildren || insideSelfLoops)
    }

    package func getDefaultLayoutAlgorithmID() -> String {
        return "org.eclipse.elk.layered"
    }

}
