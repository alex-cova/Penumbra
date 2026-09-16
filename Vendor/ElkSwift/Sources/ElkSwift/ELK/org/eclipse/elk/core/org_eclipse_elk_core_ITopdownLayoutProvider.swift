/**
 * Copyright (c) 2022 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 */


/**
 * A topdown layout provider allows layout algorithms to provide predictions over their outputs
 * before the layout algorithms are called.
 */
package protocol ITopdownLayoutProvider {
    
    /**
     * Computes the size that will be required of the graph to fit the layout once it has been calculated.
     * @return the predicted size
     */
    func getPredictedGraphSize(_ graph: ElkNode) -> KVector
    
}
