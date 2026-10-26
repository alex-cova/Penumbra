import Foundation
import JavaIntelligence

/// A Maven application: `pom.xml`, a main class and a JUnit test. No wrapper. Umbra reads the POM
/// natively once the new folder is the window's project.
enum IDEMavenTemplates {
    static let all: [any IDEProjectTemplate] = [IDEMavenApplicationTemplate()]
}

struct IDEMavenApplicationTemplate: IDEProjectTemplate {
    static let junitVersion = "5.11.4"
    static let surefireVersion = "3.5.2"

    var id: String { "java.maven.application" }
    var family: IDEProjectFamily { .java }
    var title: String { "Java Application (Maven)" }
    var summary: String { "A Maven project with a main class and a JUnit test." }
    var systemImage: String { "cup.and.saucer" }
    var fields: Set<IDENewProjectField> { [.organizationIdentifier] }

    func primaryFile(for options: IDENewProjectOptions) -> String? {
        "src/main/java/\(packagePath(options))/Main.java"
    }

    func files(for options: IDENewProjectOptions) throws -> [IDEGeneratedFile] {
        let packageName = packageName(options)
        let directory = packagePath(options)
        return [
            IDEGeneratedFile(path: "pom.xml", text: pom(options)),
            IDEGeneratedFile(path: ".gitignore", text: Self.gitignore),
            IDEGeneratedFile(path: "src/main/java/\(directory)/Main.java", text: mainSource(packageName)),
            IDEGeneratedFile(path: "src/test/java/\(directory)/MainTest.java", text: testSource(packageName)),
        ]
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
        let organization = groupId(options).replacingOccurrences(of: "-", with: "_")
        return organization + "." + artifactId(options)
    }

    private func packagePath(_ options: IDENewProjectOptions) -> String {
        packageName(options).replacingOccurrences(of: ".", with: "/")
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
              <version>\(Self.junitVersion)</version>
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

    private func mainSource(_ packageName: String) -> String {
        """
        package \(packageName);

        public class Main {
            public static void main(String[] args) {
                System.out.println("Hello, world!");
            }
        }

        """
    }

    private func testSource(_ packageName: String) -> String {
        """
        package \(packageName);

        import static org.junit.jupiter.api.Assertions.assertEquals;

        import org.junit.jupiter.api.Test;

        class MainTest {
            @Test
            void adds() {
                assertEquals(2, 1 + 1);
            }
        }

        """
    }

    static let gitignore = """
    target/
    .DS_Store

    """
}
