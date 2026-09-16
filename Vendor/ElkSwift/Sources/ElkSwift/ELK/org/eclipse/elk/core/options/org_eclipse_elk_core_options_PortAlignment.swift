// Copyright (c) 2015 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0


/// Defines the distribution of ports.
package enum PortAlignment {
    /// Ports are evenly distributed, with the same amount of space between and around them.
    case distributed
    
    /// Ports are justified and use up all the space except for the surrounding ports spacing.
    case justified
    
    /// Ports are placed at the most top respectively left position with minimal spacing.
    case begin
    
    /// Ports are centered with minimal spacing.
    case center
    
    /// Ports are placed at the most top respectively left position with minimal spacing.
    case end
}
