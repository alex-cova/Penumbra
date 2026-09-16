import Foundation
package class QuadraticConstraintCalculation: IConstraintCalculationAlgorithm {
    
    package init() {}
    
    package func calculateConstraints(_ compactor: OneDimensionalCompactor) {
        // resetting constraints
        for cNode in compactor.cGraph.cNodes {
            cNode.constraints.removeAll()
        }
        
        // inferring constraints from hitbox intersections
        for cNode1 in compactor.cGraph.cNodes {
            for cNode2 in compactor.cGraph.cNodes {
                // no self constraints
                if cNode1 === cNode2 {
                    continue
                }
                // no constraints between nodes of the same group
                if let group1 = cNode1.cGroup, group1 === cNode2.cGroup {
                    continue
                }
                
                let spacing: Double
                if compactor.direction.isHorizontal() {
                    spacing = max(cNode1.getVerticalSpacing(), cNode2.getVerticalSpacing())
                } else {
                    spacing = max(cNode1.getHorizontalSpacing(), cNode2.getHorizontalSpacing())
                }
                
                // add constraint if cNode2 is to the right of cNode1 and could collide if moved
                // horizontally
                // exclude parentNodes because they don't constrain their north/south segments
                if cNode1 !== cNode2.parentNode
                    // '>' avoids simultaneous constraints A->B and B->A
                    && (cNode2.hitbox.x > cNode1.hitbox.x
                        // 
                        || (cNode1.hitbox.x == cNode2.hitbox.x
                            && cNode1.hitbox.width < cNode2.hitbox.width))
                    
                    && CompareFuzzy.gt(cNode2.hitbox.y + cNode2.hitbox.height + spacing,
                                       cNode1.hitbox.y)
                    
                    && CompareFuzzy.lt(cNode2.hitbox.y,
                                       cNode1.hitbox.y + cNode1.hitbox.height + spacing) {
                    
                    cNode1.constraints.append(cNode2)
                }
            }
        }
    }
}
