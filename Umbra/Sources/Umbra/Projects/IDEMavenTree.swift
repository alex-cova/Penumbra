import Foundation
import JavaIntelligence

/// The Maven tool window's tree: one node per module, with lifecycle goals, the plugins that module
/// declares, and its dependency tree. Profiles are checkboxes above the tree, not nodes.
enum IDEMavenTree {
    enum Kind: Equatable {
        case module
        case group
        case goal
        case dependency
    }

    struct Node: Identifiable, Equatable {
        var id: String
        var title: String
        var detail: String
        var systemImage: String
        var kind: Kind
        /// `compile`, or `compiler:compile`. Nil for modules, groups and dependencies.
        var goal: String?
        /// `groupId:artifactId` for `-pl`. Nil when the row is not run on one module.
        var moduleSelector: String?
        var missing: Bool
        var omitted: Bool
        var children: [Node]

        var canDisclose: Bool { !children.isEmpty }
    }

    struct Row: Identifiable, Equatable {
        var id: String
        var node: Node
        var depth: Int
        var canDisclose: Bool
        var isExpanded: Bool
    }

    static let lifecycleGoals = ["clean", "validate", "compile", "test", "package", "verify", "install", "deploy"]

    /// Goals offered for a plugin the module actually declares, beside the goals its executions name.
    static let commonGoals: [String: [String]] = [
        "maven-compiler-plugin": ["compile", "testCompile"],
        "maven-surefire-plugin": ["test"],
        "maven-jar-plugin": ["jar"],
        "maven-resources-plugin": ["resources", "testResources"],
        "maven-clean-plugin": ["clean"],
        "maven-install-plugin": ["install"],
        "maven-deploy-plugin": ["deploy"],
        "maven-dependency-plugin": ["tree", "resolve", "sources"],
        "maven-source-plugin": ["jar-no-fork"],
        "jacoco-maven-plugin": ["prepare-agent", "report"],
        "spring-boot-maven-plugin": ["run", "repackage"],
        "exec-maven-plugin": ["java", "exec"],
        "maven-failsafe-plugin": ["integration-test", "verify"],
        "maven-shade-plugin": ["shade"],
        "maven-assembly-plugin": ["single"],
        "maven-enforcer-plugin": ["enforce"],
        "maven-antrun-plugin": ["run"],
        "build-helper-maven-plugin": ["add-source", "add-test-source"],
    ]

    static func build(_ model: MavenProjectModel) -> [Node] {
        model.modules.map { moduleNode($0) }
    }

    static func flatten(_ nodes: [Node], expanded: Set<String>, filter: String) -> [Row] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var rows: [Row] = []
        for node in nodes {
            append(node, depth: 0, expanded: expanded, filter: query, into: &rows)
        }
        return rows
    }

    /// `maven-compiler-plugin` is `compiler`. `spring-boot-maven-plugin` is `spring-boot`.
    static func pluginPrefix(_ artifactId: String) -> String {
        let mavenPrefix = "maven-"
        let pluginSuffix = "-plugin"
        if artifactId.hasPrefix(mavenPrefix), artifactId.hasSuffix(pluginSuffix),
           artifactId.count > mavenPrefix.count + pluginSuffix.count {
            return String(artifactId.dropFirst(mavenPrefix.count).dropLast(pluginSuffix.count))
        }
        let mavenPlugin = "-maven-plugin"
        if artifactId.hasSuffix(mavenPlugin) {
            return String(artifactId.dropLast(mavenPlugin.count))
        }
        return artifactId
    }

    static func goals(for plugin: MavenPlugin) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for goal in plugin.goals + (commonGoals[plugin.artifactId] ?? []) where seen.insert(goal).inserted {
            result.append(goal)
        }
        return result
    }

    private static func moduleNode(_ module: MavenModule) -> Node {
        let selector = module.selector
        let title = module.path == ":" ? module.artifactId : module.path
        var children: [Node] = [
            group(
                id: "\(module.path)/lifecycle",
                title: "Lifecycle",
                systemImage: "arrow.triangle.2.circlepath",
                children: lifecycleGoals.map { goal in
                    goalNode(id: "\(module.path)/lifecycle/\(goal)", title: goal, goal: goal, selector: selector, systemImage: "play")
                }
            )
        ]
        let plugins = module.plugins.compactMap { plugin -> Node? in
            let names = goals(for: plugin)
            guard !names.isEmpty else { return nil }
            let prefix = pluginPrefix(plugin.artifactId)
            return group(
                id: "\(module.path)/plugin/\(plugin.key)",
                title: prefix,
                systemImage: "puzzlepiece",
                children: names.map { name in
                    goalNode(
                        id: "\(module.path)/plugin/\(plugin.key)/\(name)",
                        title: name,
                        goal: "\(prefix):\(name)",
                        selector: selector,
                        systemImage: "play"
                    )
                }
            )
        }
        if !plugins.isEmpty {
            children.append(group(
                id: "\(module.path)/plugins",
                title: "Plugins",
                systemImage: "puzzlepiece.extension",
                children: plugins
            ))
        }
        if !module.dependencyTree.isEmpty {
            children.append(group(
                id: "\(module.path)/dependencies",
                title: "Dependencies",
                systemImage: "shippingbox",
                children: module.dependencyTree.enumerated().map { index, node in
                    dependencyNode(node, module: module.path, parent: "\(module.path)/dependencies", index: index)
                }
            ))
        }
        return Node(
            id: "module:\(module.path)",
            title: title,
            detail: module.packaging,
            systemImage: "square.stack.3d.up",
            kind: .module,
            goal: nil,
            moduleSelector: selector,
            missing: false,
            omitted: false,
            children: children
        )
    }

    private static func group(id: String, title: String, systemImage: String, children: [Node]) -> Node {
        Node(
            id: id, title: title, detail: "", systemImage: systemImage, kind: .group,
            goal: nil, moduleSelector: nil, missing: false, omitted: false, children: children
        )
    }

    private static func goalNode(id: String, title: String, goal: String, selector: String, systemImage: String) -> Node {
        Node(
            id: id, title: title, detail: "", systemImage: systemImage, kind: .goal,
            goal: goal, moduleSelector: selector, missing: false, omitted: false, children: []
        )
    }

    private static func dependencyNode(_ node: MavenDependencyNode, module: String, parent: String, index: Int) -> Node {
        let id = "\(parent)/\(index)/\(node.coordinate)"
        var detail = node.scope
        if node.omitted { detail = detail.isEmpty ? "omitted" : detail + " · omitted" }
        if node.missing { detail = detail.isEmpty ? "missing" : detail + " · missing" }
        return Node(
            id: id,
            title: node.coordinate,
            detail: detail,
            systemImage: node.projectPath == nil ? "archivebox" : "square.stack.3d.up",
            kind: .dependency,
            goal: nil,
            moduleSelector: nil,
            missing: node.missing,
            omitted: node.omitted,
            children: node.children.enumerated().map { childIndex, child in
                dependencyNode(child, module: module, parent: id, index: childIndex)
            }
        )
    }

    private static func append(
        _ node: Node, depth: Int, expanded: Set<String>, filter: String, into rows: inout [Row]
    ) {
        let matches = filter.isEmpty || node.title.lowercased().contains(filter) || node.detail.lowercased().contains(filter)
        let childRows = matchingChildren(node.children, depth: depth + 1, expanded: expanded, filter: filter)
        guard matches || !childRows.isEmpty else { return }
        let isExpanded = filter.isEmpty ? expanded.contains(node.id) : true
        rows.append(Row(id: node.id, node: node, depth: depth, canDisclose: node.canDisclose, isExpanded: isExpanded && node.canDisclose))
        if isExpanded || !filter.isEmpty {
            rows.append(contentsOf: childRows)
        }
    }

    private static func matchingChildren(
        _ children: [Node], depth: Int, expanded: Set<String>, filter: String
    ) -> [Row] {
        var rows: [Row] = []
        for child in children {
            append(child, depth: depth, expanded: expanded, filter: filter, into: &rows)
        }
        return rows
    }
}
