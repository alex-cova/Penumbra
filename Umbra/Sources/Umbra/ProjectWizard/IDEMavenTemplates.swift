import Foundation
import JavaIntelligence

/// A Maven application: `pom.xml`, a main class and a JUnit test. No wrapper. Umbra reads the POM
/// natively once the new folder is the window's project.
enum IDEMavenTemplates {
    static let all: [any IDEProjectTemplate] = [IDEMavenApplicationTemplate()]
}

struct IDEMavenApplicationTemplate: IDEProjectTemplate {
    static let surefireVersion = "3.5.2"

    var id: String { "java.maven.application" }
    var family: IDEProjectFamily { .java }
    var title: String { "Java Application (Maven)" }
    var summary: String { "A Maven project with a main class and a JUnit test." }
    var systemImage: String { "cup.and.saucer" }
    var fields: Set<IDENewProjectField> { [.organizationIdentifier] }

    func primaryFile(for options: IDENewProjectOptions) -> String? {
        IDEJavaApplicationSources(packageName: packageName(options)).mainPath
    }

    func files(for options: IDENewProjectOptions) throws -> [IDEGeneratedFile] {
        return [
            IDEGeneratedFile(path: "pom.xml", text: pom(options)),
            IDEGeneratedFile(path: ".gitignore", text: Self.gitignore),
        ] + IDEJavaApplicationSources(packageName: packageName(options)).files
    }

    private func artifactId(_ options: IDENewProjectOptions) -> String {
        options.productName.lowercased()
    }

    private func groupId(_ options: IDENewProjectOptions) -> String {
        let trimmed = options.organizationIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "com.example" : trimmed
    }

    /// `com.example` plus the artifact id. A hyphen in the organization becomes `_` so the name is a
    /// Java package.
    private func packageName(_ options: IDENewProjectOptions) -> String {
        let organization = groupId(options).replacing("-", with: "_")
        return organization + "." + artifactId(options)
    }

    /// The newest installed JDK, or 17 when none is found.
    private func compilerRelease() -> Int {
        JDKLocator().discoverAll().map(\.featureVersion).max() ?? 17
    }

    private func pom(_ options: IDENewProjectOptions) -> String {
        let release = compilerRelease()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <project xmlns="http://maven.apache.org/POM/4.0.0">
          <modelVersion>4.0.0</modelVersion>
          <groupId>\(groupId(options))</groupId>
          <artifactId>\(artifactId(options))</artifactId>
          <version>1.0.0</version>
          <properties>
            <maven.compiler.release>\(release)</maven.compiler.release>
            <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
          </properties>
          <dependencies>
            <dependency>
              <groupId>org.junit.jupiter</groupId>
              <artifactId>junit-jupiter</artifactId>
              <version>\(IDEJavaApplicationSources.junitVersion)</version>
              <scope>test</scope>
            </dependency>
          </dependencies>
          <build>
            <plugins>
              <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-surefire-plugin</artifactId>
                <version>\(Self.surefireVersion)</version>
              </plugin>
            </plugins>
          </build>
        </project>

        """
    }

    static let gitignore = """
    target/
    .DS_Store

    """
}
