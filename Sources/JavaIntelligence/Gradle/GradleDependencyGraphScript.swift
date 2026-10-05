import Foundation

/// The init script behind the library view of the Gradle dependency diagram. Like
/// ``GradleProjectModelScript`` it asks Gradle's own API instead of parsing `gradle dependencies` text: it
/// walks the configuration's `ResolutionResult`, so every node is a real `group:name` with the version
/// Gradle selected, and an edge says which version was asked for when conflict resolution replaced it.
///
/// Embedded as a string for the same reason as the project model script: the packaged app has no SPM
/// resource bundle. It needs no Groovy backslashes, so the literal stays plain.
enum GradleDependencyGraphScript {
    static let formatVersion = GradleDependencyGraph.formatVersion

    /// Inputs are properties (`-PumbraDependencyOutput`, `-PumbraDependencyConfiguration`); the task is
    /// registered in every project and run for one path, e.g. `:app:umbraDependencyGraph`.
    static let source = """
    import org.gradle.api.artifacts.component.ModuleComponentIdentifier
    import org.gradle.api.artifacts.component.ModuleComponentSelector
    import org.gradle.api.artifacts.component.ProjectComponentIdentifier
    import org.gradle.api.artifacts.result.ResolvedDependencyResult
    import org.gradle.api.artifacts.result.UnresolvedDependencyResult

    gradle.allprojects { p ->
        p.tasks.register('umbraDependencyGraph') { t ->
            t.doLast {
                def props = p.gradle.startParameter.projectProperties
                def outputPath = props.get('umbraDependencyOutput')
                if (outputPath == null) {
                    throw new GradleException("umbraDependencyGraph requires -PumbraDependencyOutput=<path>")
                }
                def configName = props.get('umbraDependencyConfiguration') ?: 'runtimeClasspath'
                def model = [
                    formatVersion: \(formatVersion),
                    gradleVersion: p.gradle.gradleVersion,
                    project: p.path,
                    configuration: configName,
                    rootKey: '',
                    components: [],
                    edges: []
                ]

                def keyOf = { c ->
                    def id = c.id
                    if (id instanceof ProjectComponentIdentifier) { return 'project:' + id.projectPath }
                    if (id instanceof ModuleComponentIdentifier) { return id.group + ':' + id.module }
                    return id.displayName
                }
                def describe = { c ->
                    def id = c.id
                    if (id instanceof ProjectComponentIdentifier) {
                        def last = id.projectPath == ':' ? p.rootProject.name : id.projectPath.tokenize(':').last()
                        return [key: keyOf(c), kind: 'project', name: last, projectPath: id.projectPath]
                    }
                    if (id instanceof ModuleComponentIdentifier) {
                        def replaced = false
                        try { replaced = c.selectionReason.isConflictResolution() } catch (Exception ignored) {}
                        return [key: keyOf(c), kind: 'module', group: id.group, name: id.module,
                                version: id.version, conflictResolved: replaced]
                    }
                    return [key: keyOf(c), kind: 'module', name: id.displayName]
                }

                def config = p.configurations.findByName(configName)
                if (config == null || !config.canBeResolved) {
                    model.error = "Project " + p.path + " has no resolvable configuration named " + configName
                } else {
                    try {
                        def root = config.incoming.resolutionResult.root
                        def rootKey = keyOf(root)
                        model.rootKey = rootKey
                        def components = new LinkedHashMap()
                        def edges = new LinkedHashMap()
                        components.put(rootKey, describe(root))
                        def visited = [rootKey] as HashSet
                        def queue = new ArrayDeque()
                        queue.add(root)
                        while (!queue.isEmpty() && components.size() < 3000) {
                            def current = queue.poll()
                            def fromKey = keyOf(current)
                            current.dependencies.each { d ->
                                if (d instanceof ResolvedDependencyResult) {
                                    def target = d.selected
                                    def toKey = keyOf(target)
                                    def requestedVersion = null
                                    try {
                                        def requested = d.requested
                                        def selectedId = target.id
                                        if (requested instanceof ModuleComponentSelector && selectedId instanceof ModuleComponentIdentifier
                                            && requested.version && requested.version != selectedId.version
                                            && target.selectionReason.isConflictResolution()) {
                                            requestedVersion = requested.version
                                        }
                                    } catch (Exception ignored) {}
                                    def edgeKey = fromKey + ' -> ' + toKey
                                    def existing = edges.get(edgeKey)
                                    if (existing == null) {
                                        edges.put(edgeKey, [from: fromKey, to: toKey, requestedVersion: requestedVersion,
                                                            constraint: d.constraint])
                                    } else if (!d.constraint) {
                                        existing.constraint = false
                                        if (requestedVersion != null) { existing.requestedVersion = requestedVersion }
                                    }
                                    if (!components.containsKey(toKey)) { components.put(toKey, describe(target)) }
                                    if (visited.add(toKey)) { queue.add(target) }
                                } else if (d instanceof UnresolvedDependencyResult) {
                                    def label = d.requested.displayName
                                    def toKey = 'unresolved:' + label
                                    if (!components.containsKey(toKey)) {
                                        def message = ''
                                        try { message = d.failure.message ?: '' } catch (Exception ignored) {}
                                        components.put(toKey, [key: toKey, kind: 'unresolved', name: label, message: message])
                                    }
                                    def edgeKey = fromKey + ' -> ' + toKey
                                    if (!edges.containsKey(edgeKey)) {
                                        edges.put(edgeKey, [from: fromKey, to: toKey, constraint: false])
                                    }
                                }
                            }
                        }
                        model.components = new ArrayList(components.values())
                        model.edges = new ArrayList(edges.values())
                    } catch (Exception e) {
                        model.error = e.message ?: e.toString()
                    }
                }

                def outputFile = new File(outputPath)
                outputFile.parentFile?.mkdirs()
                outputFile.text = groovy.json.JsonOutput.toJson(model)
            }
        }
    }
    """
}
