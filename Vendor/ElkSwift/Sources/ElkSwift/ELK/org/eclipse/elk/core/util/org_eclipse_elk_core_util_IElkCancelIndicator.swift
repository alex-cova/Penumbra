/**
 * Copyright (c) 2015 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 */

/// Interface for indicators of task cancellation. Possibly long-running tasks such as layout algorithms
/// should query the indicator from time to time in order to allow users to abort the process.
package protocol IElkCancelIndicator {
    
    /// Returns whether cancellation of the task has been requested.
    /// - Returns: true if cancellation has been requested
    func isCanceled() -> Bool
}
