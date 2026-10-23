import Foundation

/// One dependency jar of the open project, as the Explorer's External Libraries section lists it.
public struct JavaExternalLibrary: Equatable, Sendable, Identifiable {
    /// `lib:` plus the jar path, so it never collides with a file path in the Explorer.
    public let id: String
    public let label: String
    public let jar: URL
    public let coordinates: JavaLibraryCoordinates

    public init(jar: URL) {
        let standardized = jar.standardizedFileURL
        self.jar = standardized
        self.id = "lib:" + standardized.path
        self.coordinates = JavaLibraryCoordinates.parse(jar: standardized)
        self.label = coordinates.label
    }

    /// A `*-sources.jar` next to the jar. Looks at the disk, so ask only for the rows on screen.
    public var sourcesJar: URL? { JavaAttachedSources.sourcesJar(adjacentTo: jar) }

    /// Every jar on any source set's compile or runtime classpath, once each, in the order IntelliJ
    /// lists them (by label, case-insensitively). Annotation processors are not libraries of the code.
    public static func list(from model: JavaGradleProjectModel) -> [JavaExternalLibrary] {
        var seen = Set<String>()
        var libraries: [JavaExternalLibrary] = []
        for subproject in model.subprojects {
            for sourceSet in subproject.sourceSets {
                for jar in sourceSet.compileClasspathJars + sourceSet.runtimeClasspathJars {
                    let library = JavaExternalLibrary(jar: jar)
                    if seen.insert(library.id).inserted { libraries.append(library) }
                }
            }
        }
        return libraries.sorted {
            let order = $0.label.localizedCaseInsensitiveCompare($1.label)
            return order == .orderedSame ? $0.jar.path < $1.jar.path : order == .orderedAscending
        }
    }
}
