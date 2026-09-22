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
    static let formatVersion = 1

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

    def umbraDescribeProject = { p ->
        def result = [
            path: p.path,
            directory: p.projectDir.toURI().toString(),
            sourceDirs: [],
            testSourceDirs: [],
            languageLevel: null,
            compileClasspathJars: [],
            testClasspathJars: [],
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

        javaExt.sourceSets.each { ss ->
            def dirs = ss.java.srcDirs.collect { it.toURI().toString() }
            if (ss.name.toLowerCase().contains('test')) {
                result.testSourceDirs.addAll(dirs)
            } else {
                result.sourceDirs.addAll(dirs)
            }
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

        def resolveJars = { String configurationName ->
            def jars = []
            def unresolvedDeps = []
            def config = p.configurations.findByName(configurationName)
            if (config == null || !config.canBeResolved) {
                return [jars: jars, unresolved: unresolvedDeps]
            }
            try {
                def view = config.incoming.artifactView { viewSpec ->
                    viewSpec.lenient(true)
                    viewSpec.componentFilter { id -> !(id instanceof ProjectComponentIdentifier) }
                }
                view.artifacts.each { artifact ->
                    if (artifact.file.name.endsWith('.jar')) {
                        jars.add(artifact.file.toURI().toString())
                    }
                }
                view.artifacts.failures.each { failure ->
                    unresolvedDeps.add(failure.message ?: failure.toString())
                }
            } catch (Exception e) {
                unresolvedDeps.add(e.message ?: e.toString())
            }
            return [jars: jars, unresolved: unresolvedDeps]
        }

        def compile = resolveJars('compileClasspath')
        result.compileClasspathJars = compile.jars
        result.unresolved.addAll(compile.unresolved)

        def testCompile = resolveJars('testCompileClasspath')
        result.testClasspathJars = testCompile.jars
        result.unresolved.addAll(testCompile.unresolved)

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
