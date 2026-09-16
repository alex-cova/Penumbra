/**
 * Copyright (c) 2016 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 */


/**
 * <!-- begin-user-doc -->
 * The <b>Factory</b> for the model.
 * It provides a create method for each non-package class of the model.
 * <!-- end-user-doc -->
 * @see org.eclipse.elk.graph.ElkGraphPackage
 * @generated
 */
package protocol ElkGraphFactory: EFactory {
    /**
     * The singleton instance of the factory.
     * <!-- begin-user-doc -->
     * <!-- end-user-doc -->
     * @generated
     */
    static var eINSTANCE: ElkGraphFactory { get }

    /**
     * Returns a new object of class '<em>Elk Label</em>'.
     * <!-- begin-user-doc -->
     * <!-- end-user-doc -->
     * @return a new object of class '<em>Elk Label</em>'.
     * @generated
     */
    func createElkLabel() -> ElkLabel

    /**
     * Returns a new object of class '<em>Elk Node</em>'.
     * <!-- begin-user-doc -->
     * <!-- end-user-doc -->
     * @return a new object of class '<em>Elk Node</em>'.
     * @generated
     */
    func createElkNode() -> ElkNode

    /**
     * Returns a new object of class '<em>Elk Port</em>'.
     * <!-- begin-user-doc -->
     * <!-- end-user-doc -->
     * @return a new object of class '<em>Elk Port</em>'.
     * @generated
     */
    func createElkPort() -> ElkPort

    /**
     * Returns a new object of class '<em>Elk Edge</em>'.
     * <!-- begin-user-doc -->
     * <!-- end-user-doc -->
     * @return a new object of class '<em>Elk Edge</em>'.
     * @generated
     */
    func createElkEdge() -> ElkEdge

    /**
     * Returns a new object of class '<em>Elk Bend Point</em>'.
     * <!-- begin-user-doc -->
     * <!-- end-user-doc -->
     * @return a new object of class '<em>Elk Bend Point</em>'.
     * @generated
     */
    func createElkBendPoint() -> ElkBendPoint

    /**
     * Returns a new object of class '<em>Elk Edge Section</em>'.
     * <!-- begin-user-doc -->
     * <!-- end-user-doc -->
     * @return a new object of class '<em>Elk Edge Section</em>'.
     * @generated
     */
    func createElkEdgeSection() -> ElkEdgeSection

    /**
     * Returns the package supported by this factory.
     * <!-- begin-user-doc -->
     * <!-- end-user-doc -->
     * @return the package supported by this factory.
     * @generated
     */
    func getElkGraphPackage() -> ElkGraphPackage
}
