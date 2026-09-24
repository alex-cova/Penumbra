import Foundation

/// The bundled Gradle init script that extracts a ``JavaGradleProjectModel`` from a project via
/// Gradle's own APIs (source sets, resolved classpaths) rather than parsing free-text output like
/// `./gradlew :app:dependencies` -- fragile across Gradle versions/configurations, and gives no
/// source directories at all.
///
/// This is embedded as a Swift string literal rather than an SPM resource: `Scripts/build-app.sh`
/// never copies SPM resource bundles into `Umbra.app`, and `JavaIntelligence` has no resources
/// today, so an embedded string can't go missing from a packaged build the way a resource could.
enum GradleProjectModelScript {
    /// Bumped whenever the emitted JSON shape changes; mirrored in
    /// ``JavaGradleProjectModel/formatVersion``.
    static let formatVersion = 4

    /// Groovy, not Kotlin DSL: a Groovy init script doesn't need the `kotlin-dsl` plugin resolved
    /// first, which keeps this working on older Gradle versions with no extra project-side setup.
    ///
    /// Walks `rootProject.allprojects`, having each project describe *itself* (its own source sets
    /// and resolved classpaths) rather than a single root task reaching into other projects'
    /// configurations from a different execution context -- the same posture Gradle's own tooling
    /// API model builders take, and it naturally scales to any number of subprojects with no extra
    /// wiring. Every project registers its own `umbraProjectModelFragment` task; the root
    /// `umbraProjectModel` task depends on all of them and merges their output into one JSON
    /// document once they've all run.
    static let source = """
    import org.gradle.api.artifacts.component.ProjectComponentIdentifier
    import org.gradle.api.plugins.JavaPluginExtension

    gradle.rootProject { r ->
        r.ext.umbraFragments = Collections.synchronizedList([])
    }

    // Resolves one of a source set's classpath configurations (compile or runtime) into jar URIs
    // and project dependencies, leniently, so one bad dependency degrades instead of failing.
    def umbraResolveClasspath = { p, ss, configName, label, described, jarsKey, dependenciesKey ->
        def config = p.configurations.findByName(configName)
        if (config == null || !config.canBeResolved) {
            return
        }
        try {
            p.logger.lifecycle("Umbra: resolving " + p.path + " " + ss.name + " " + label)
            def view = config.incoming.artifactView { viewSpec ->
                viewSpec.lenient(true)
            }
            def seenJars = [] as LinkedHashSet
            def seenProjects = [] as HashSet
            view.artifacts.each { artifact ->
                def owner = null
                def variantName = ''
                try {
                    owner = artifact.variant.owner
                    variantName = artifact.variant.displayName ?: ''
                } catch (Exception ignored) {}
                if (owner instanceof ProjectComponentIdentifier) {
                    def sourceSetName = variantName.contains('testFixtures') ? 'testFixtures' : 'main'
                    // A source set's own output is not a dependency; its directories are already listed.
                    if (owner.projectPath == p.path && sourceSetName == ss.name) {
                        return
                    }
                    def key = owner.projectPath + '@' + sourceSetName
                    if (seenProjects.add(key)) {
                        described[dependenciesKey].add([projectPath: owner.projectPath, sourceSetName: sourceSetName])
                    }
                } else if (artifact.file.name.endsWith('.jar')) {
                    def uri = artifact.file.toURI().toString()
                    if (seenJars.add(uri)) {
                        described[jarsKey].add(uri)
                    }
                }
            }
            view.artifacts.failures.each { failure ->
                def message = failure.message ?: failure.toString()
                if (!described.unresolved.contains(message)) {
                    described.unresolved.add(message)
                }
            }
        } catch (Exception e) {
            def message = e.message ?: e.toString()
            if (!described.unresolved.contains(message)) {
                described.unresolved.add(message)
            }
        }
    }

    def umbraDescribeSourceSet = { p, ss ->
        def described = [
            name: ss.name,
            sourceDirs: ss.java.srcDirs.collect { it.toURI().toString() },
            outputDirs: [],
            compileClasspathJars: [],
            projectDependencies: [],
            runtimeClasspathJars: [],
            runtimeProjectDependencies: [],
            unresolved: []
        ]
        try {
            ss.output.classesDirs.files.each { described.outputDirs.add(it.toURI().toString()) }
            def resources = ss.output.resourcesDir
            if (resources != null) {
                described.outputDirs.add(resources.toURI().toString())
            }
        } catch (Exception ignored) {}
        umbraResolveClasspath(p, ss, ss.compileClasspathConfigurationName, 'compile classpath', described,
            'compileClasspathJars', 'projectDependencies')
        umbraResolveClasspath(p, ss, ss.runtimeClasspathConfigurationName, 'runtime classpath', described,
            'runtimeClasspathJars', 'runtimeProjectDependencies')
        return described
    }

    def umbraDescribeTasks = { p ->
        def skip = ['umbraProjectModelFragment', 'umbraProjectModel'] as Set
        return p.tasks.matching { t ->
            t.enabled && t.group != null && !t.group.isEmpty() && !skip.contains(t.name)
        }.collect { t ->
            [
                path: t.path,
                name: t.name,
                group: t.group,
                description: t.description ?: ''
            ]
        }.sort { a, b ->
            def ga = a.group <=> b.group
            ga != 0 ? ga : a.path <=> b.path
        }
    }

    def umbraDescribeProject = { p ->
        def result = [
            path: p.path,
            directory: p.projectDir.toURI().toString(),
            languageLevel: null,
            sourceSets: [],
            tasks: umbraDescribeTasks(p),
            unresolved: []
        ]

        def hasJava = p.plugins.hasPlugin('java') || p.plugins.hasPlugin('java-library')
        if (!hasJava) {
            return result
        }
        def javaExt = p.extensions.findByType(JavaPluginExtension)
        if (javaExt == null) {
            return result
        }

        Integer level = null
        try {
            def toolchain = javaExt.toolchain
            if (toolchain != null && toolchain.languageVersion.isPresent()) {
                level = toolchain.languageVersion.get().asInt()
            }
        } catch (Exception ignored) {}
        if (level == null) {
            try {
                level = javaExt.sourceCompatibility.majorVersion.toInteger()
            } catch (Exception ignored) {}
        }
        result.languageLevel = level

        javaExt.sourceSets.each { ss ->
            def described = umbraDescribeSourceSet(p, ss)
            result.unresolved.addAll(described.unresolved)
            described.remove('unresolved')
            result.sourceSets.add(described)
        }

        return result
    }

    gradle.allprojects { p ->
        p.tasks.register('umbraProjectModelFragment') { t ->
            t.doLast {
                p.rootProject.ext.umbraFragments.add(umbraDescribeProject(p))
            }
        }
    }

    gradle.projectsEvaluated { g ->
        def root = g.rootProject
        root.tasks.register('umbraProjectModel') { t ->
            t.dependsOn(root.allprojects.collect { it.tasks.named('umbraProjectModelFragment') })
            t.doLast {
                def outputPath = g.startParameter.projectProperties.get('umbraModelOutput')
                if (outputPath == null) {
                    throw new GradleException("umbraProjectModel requires -PumbraModelOutput=<path>")
                }
                def subprojectsList = new ArrayList(root.ext.umbraFragments)
                def unresolvedAll = []
                subprojectsList.each { sp ->
                    if (sp.unresolved) { unresolvedAll.addAll(sp.unresolved) }
                    sp.remove('unresolved')
                }
                def model = [
                    formatVersion: \(formatVersion),
                    gradleVersion: g.gradleVersion,
                    subprojects: subprojectsList,
                    unresolved: unresolvedAll
                ]
                def outputFile = new File(outputPath)
                outputFile.parentFile?.mkdirs()
                outputFile.text = groovy.json.JsonOutput.toJson(model)
            }
        }
    }
    """
}
