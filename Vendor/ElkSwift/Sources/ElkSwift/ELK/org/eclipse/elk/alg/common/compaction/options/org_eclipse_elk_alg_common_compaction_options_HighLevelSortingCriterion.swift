// Copyright (c) 2017 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0


/// <p>
/// Possible primary sorting criteria for the processing order of polyominoes.
/// </p>
package enum HighLevelSortingCriterion {
    case numOfExternalSidesThanNumOfExtensionsLast
    case cornerCasesThanSingleSideLast
}
