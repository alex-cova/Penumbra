struct IDEGradleApplicationTemplate: IDEProjectTemplate {
    var id: String { "java.gradle.application" }
    var family: IDEProjectFamily { .java }
    var title: String { "Java Application (Gradle)" }
    var summary: String { "A Java 17 application with a JUnit test. Building requires Gradle on your PATH." }
    var systemImage: String { "hammer" }
    var fields: Set<IDENewProjectField> { [.organizationIdentifier, .gradleDSL] }

    func primaryFile(for options: IDENewProjectOptions) -> String? {
        sources(for: options).mainPath
    }

    func files(for options: IDENewProjectOptions) throws -> [IDEGeneratedFile] {
        let sources = sources(for: options)
        let group = group(options)
        let mainClass = "\(sources.packageName).Main"
        let settings: String
        let build: String
        switch options.gradleDSL {
        case .kotlin:
            settings = "rootProject.name = \"\(options.productName)\"\n"
            build = kotlinBuildScript(group: group, mainClass: mainClass)
        case .groovy:
            settings = "rootProject.name = '\(options.productName)'\n"
            build = groovyBuildScript(group: group, mainClass: mainClass)
        }
        let scriptExtension = options.gradleDSL.scriptExtension
        return [
            IDEGeneratedFile(path: "settings.\(scriptExtension)", text: settings),
            IDEGeneratedFile(path: "build.\(scriptExtension)", text: build),
            IDEGeneratedFile(path: ".gitignore", text: ".gradle/\nbuild/\n.DS_Store\n"),
        ] + sources.files
    }

    private func kotlinBuildScript(group: String, mainClass: String) -> String {
        """
        plugins {
            application
        }

        group = "\(group)"
        version = "1.0.0"

        repositories {
            mavenCentral()
        }

        dependencies {
            testImplementation("org.junit.jupiter:junit-jupiter:\(IDEJavaApplicationSources.junitVersion)")
            testRuntimeOnly("org.junit.platform:junit-platform-launcher")
        }

        java {
            sourceCompatibility = JavaVersion.VERSION_17
        }

        tasks.withType<JavaCompile>().configureEach {
            options.release.set(17)
        }

        application {
            mainClass.set("\(mainClass)")
        }

        tasks.test {
            useJUnitPlatform()
        }

        """
    }

    private func groovyBuildScript(group: String, mainClass: String) -> String {
        """
        plugins {
            id 'application'
        }

        group = '\(group)'
        version = '1.0.0'

        repositories {
            mavenCentral()
        }

        dependencies {
            testImplementation 'org.junit.jupiter:junit-jupiter:\(IDEJavaApplicationSources.junitVersion)'
            testRuntimeOnly 'org.junit.platform:junit-platform-launcher'
        }

        java {
            sourceCompatibility = JavaVersion.VERSION_17
        }

        tasks.withType(JavaCompile).configureEach {
            options.release = 17
        }

        application {
            mainClass = '\(mainClass)'
        }

        tasks.named('test') {
            useJUnitPlatform()
        }

        """
    }

    private func group(_ options: IDENewProjectOptions) -> String {
        let identifier = options.organizationIdentifier
        return IDENewProjectValidator.isReverseDNS(identifier) ? identifier : "com.example"
    }

    private func sources(for options: IDENewProjectOptions) -> IDEJavaApplicationSources {
        let qualifiedName = "\(group(options)).\(options.productName.lowercased())"
        let packageName = qualifiedName.split(separator: ".").enumerated().map { index, label in
            let segment = String(label).replacing("-", with: "_")
            // The JVM reserves java.* even though javac allows it as a package name.
            if segment.first?.isNumber == true || Self.reservedWords.contains(segment)
                || (index == 0 && segment == "java") {
                return "_" + segment
            }
            return segment
        }.joined(separator: ".")
        return IDEJavaApplicationSources(packageName: packageName)
    }

    private static let reservedWords: Set<String> = [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue",
        "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "goto", "if",
        "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private",
        "protected", "public", "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this",
        "throw", "throws", "transient", "try", "void", "volatile", "while", "true", "false", "null", "_",
    ]
}
