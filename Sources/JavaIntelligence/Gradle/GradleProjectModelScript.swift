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
    static let formatVersion = 8

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
    import org.gradle.api.tasks.testing.Test

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

    // The `--add-modules` roots of the source set's `JavaCompile` task (e.g.
    // `jdk.incubator.vector`), in both `--add-modules X` and `--add-modules=X` spellings, with
    // comma-separated lists split. Only `--add-modules` is captured: `--add-exports` is rejected
    // alongside `--release` (which Umbra always passes), and `--add-opens`/`--add-reads` are
    // runtime-only no-ops at compile time, so replaying them would only add noise or errors.
    def umbraCompileAddModules = { p, ss ->
        def modules = [] as LinkedHashSet
        try {
            def compileTask = p.tasks.findByName(ss.compileJavaTaskName)
            def args = compileTask?.options?.compilerArgs
            if (args != null) {
                def takeNext = false
                args.each { raw ->
                    def arg = raw?.toString()
                    if (arg == null || arg.isEmpty()) {
                        takeNext = false
                        return
                    }
                    if (takeNext) {
                        takeNext = false
                        if (!arg.startsWith('-')) {
                            arg.split(',').each { m ->
                                def name = m.trim()
                                if (!name.isEmpty()) { modules.add(name) }
                            }
                        }
                        return
                    }
                    if (arg == '--add-modules') {
                        takeNext = true
                    } else if (arg.startsWith('--add-modules=')) {
                        arg.substring('--add-modules='.length()).split(',').each { m ->
                            def name = m.trim()
                            if (!name.isEmpty()) { modules.add(name) }
                        }
                    }
                }
            }
        } catch (Exception ignored) {}
        return new ArrayList(modules)
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
            generatedSourceDirs: [],
            annotationProcessorJars: [],
            annotationProcessorProjects: [],
            addModules: umbraCompileAddModules(p, ss),
            unresolved: []
        ]
        try {
            def compileTask = p.tasks.findByName(ss.compileJavaTaskName)
            def generated = compileTask?.options?.generatedSourceOutputDirectory
            if (generated != null && generated.isPresent()) {
                described.generatedSourceDirs.add(generated.get().asFile.toURI().toString())
            }
        } catch (Exception ignored) {}
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
        umbraResolveClasspath(p, ss, ss.annotationProcessorConfigurationName, 'annotation processors', described,
            'annotationProcessorJars', 'annotationProcessorProjects')
        described.remove('annotationProcessorProjects')
        return described
    }

    // Enumerate by registered name and realize one task at a time. A blanket `tasks.matching { }`
    // collect forces every matching task to be created; version-control plugins (e.g. `storeVersion`
    // from grgit/axion) can fail there when Git isn't configured, which would abort the whole sync.
    def umbraDescribeTasks = { p ->
        def skip = ['umbraProjectModelFragment', 'umbraProjectModel'] as Set
        def result = []
        p.tasks.names.each { name ->
            if (skip.contains(name)) {
                return
            }
            try {
                def t = p.tasks.named(name).get()
                if (t.enabled && t.group != null && !t.group.isEmpty()) {
                    result.add([
                        path: t.path,
                        name: t.name,
                        group: t.group,
                        description: t.description ?: ''
                    ])
                }
            } catch (Exception ignored) {}
        }
        return result.sort { a, b ->
            def ga = a.group <=> b.group
            ga != 0 ? ga : a.path <=> b.path
        }
    }

    // Every `Test` task with the directory its JUnit XML reports land in and the source set whose
    // classes it runs (matched by `testClassesDirs` against each source set's output classes dirs).
    def umbraDescribeTestTasks = { p, javaExt ->
        def result = []
        try {
            p.tasks.withType(Test).each { t ->
                def resultsDir = null
                try {
                    resultsDir = t.reports.junitXml.outputLocation.get().asFile
                } catch (Throwable ignored) {}
                if (resultsDir == null) {
                    try {
                        resultsDir = t.reports.junitXml.destination
                    } catch (Throwable ignored) {}
                }
                if (resultsDir == null) {
                    resultsDir = new File(p.layout.buildDirectory.get().asFile, "test-results/${t.name}")
                }
                def sourceSetName = null
                try {
                    def testDirs = t.testClassesDirs.files
                    def match = javaExt.sourceSets.find { ss ->
                        def outs = ss.output.classesDirs.files
                        !outs.isEmpty() && testDirs.any { outs.contains(it) }
                    }
                    sourceSetName = match?.name
                } catch (Throwable ignored) {}
                def entry = [path: t.path, name: t.name, resultsDir: resultsDir.toURI().toString()]
                if (sourceSetName != null) { entry.sourceSetName = sourceSetName }
                result.add(entry)
            }
        } catch (Throwable ignored) {}
        return result.sort { it.path }
    }

    // The effective main class of the project's `run` task (the `application` plugin's
    // extension, unless the task sets its own), or null: a `run` task without one fails with
    // "No main class specified". `mainClass` is a `Property` on recent Gradle versions and a
    // plain `main` string on old ones; anything unreadable degrades to null.
    def umbraRunMainClass = { p ->
        try {
            def run = p.tasks.findByName('run')
            if (run == null) { return null }
            try {
                def mc = run.mainClass
                if (mc instanceof String) { return mc }
                if (mc != null) {
                    try {
                        def v = mc.getOrNull()
                        if (v != null) { return v.toString() }
                    } catch (Exception ignored) {}
                }
            } catch (Exception ignored) {}
            try {
                def main = run.main
                if (main != null) { return main.toString() }
            } catch (Exception ignored) {}
        } catch (Exception ignored) {}
        return null
    }

    def umbraDescribeProject = { p ->
        def result = [
            path: p.path,
            directory: p.projectDir.toURI().toString(),
            languageLevel: null,
            sourceSets: [],
            tasks: umbraDescribeTasks(p),
            testTasks: [],
            runMainClass: umbraRunMainClass(p),
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
        result.testTasks = umbraDescribeTestTasks(p, javaExt)

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
