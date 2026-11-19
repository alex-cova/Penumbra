struct IDEJavaApplicationSources {
    static let junitVersion = "5.11.4"

    let packageName: String

    private var packagePath: String { packageName.replacing(".", with: "/") }

    var mainPath: String { "src/main/java/\(packagePath)/Main.java" }

    var files: [IDEGeneratedFile] {
        [
            IDEGeneratedFile(path: mainPath, text: """
            package \(packageName);

            public class Main {
                public static void main(String[] args) {
                    System.out.println("Hello, world!");
                }
            }

            """),
            IDEGeneratedFile(path: "src/test/java/\(packagePath)/MainTest.java", text: """
            package \(packageName);

            import static org.junit.jupiter.api.Assertions.assertEquals;

            import org.junit.jupiter.api.Test;

            class MainTest {
                @Test
                void adds() {
                    assertEquals(2, 1 + 1);
                }
            }

            """),
        ]
    }
}
