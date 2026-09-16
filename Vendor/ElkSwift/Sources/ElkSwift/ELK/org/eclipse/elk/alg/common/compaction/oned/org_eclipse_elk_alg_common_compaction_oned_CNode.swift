// org.eclipse.elk.alg.common.compaction.oned.CNode
// This type is superseded by the layered compaction CNode.
// See: org_eclipse_elk_alg_layered_compaction_oned_CNode.swift

// The layered CNode class is the canonical implementation used throughout the codebase.
// The "common" version (CommonCNode) is not needed since the layered CNode provides
// all required functionality including hitbox, constraints, cGroup, cGroupOffset, startPos, etc.

// CNodeBuilder functionality:
// In the original Java code, CNode.of() returns a builder. In the Swift port,
// CNodes are constructed directly via CNode(hitbox:) and added to CGroups/CGraphs manually.
