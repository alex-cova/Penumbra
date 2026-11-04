import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// F16: JPMS exports narrow the class names offered across module boundaries.
final class JavaModuleVisibilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jpms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: - Descriptor

    func testTheDescriptorParserReadsRequiresAndExports() throws {
        let descriptor = try XCTUnwrap(JavaModuleDescriptor.parse(source: """
        /* header */
        @Deprecated
        open module com.acme.app { // trailing
            requires transitive com.acme.core;
            requires static java.sql;
            requires java.logging;
            exports com.acme.app.api;
            exports com.acme.app.spi to com.acme.plugin, com.acme.other;
            opens com.acme.app.model;
            uses com.acme.app.spi.Plugin;
        }
        """))
        XCTAssertEqual(descriptor.name, "com.acme.app")
        XCTAssertTrue(descriptor.isOpen)
        XCTAssertEqual(descriptor.requires.map(\.module), ["com.acme.core", "java.sql", "java.logging"])
        XCTAssertEqual(descriptor.requires.map(\.isTransitive), [true, false, false])
        XCTAssertEqual(descriptor.requires.map(\.isStatic), [false, true, false])
        XCTAssertTrue(descriptor.exports(package: "com.acme.app.api", to: "anyone"))
        XCTAssertTrue(descriptor.exports(package: "com.acme.app.spi", to: "com.acme.plugin"))
        XCTAssertFalse(descriptor.exports(package: "com.acme.app.spi", to: "com.acme.stranger"))
        XCTAssertFalse(descriptor.exports(package: "com.acme.app.model", to: nil), "opens is not exports")
        XCTAssertNil(JavaModuleDescriptor.parse(source: "package p; class NotAModule {}"))
    }

    func testARequiresNamedLikeAModifierIsAModule() throws {
        let descriptor = try XCTUnwrap(JavaModuleDescriptor.parse(source: "module m { requires transitive; }"))
        XCTAssertEqual(descriptor.requires.map(\.module), ["transitive"])
    }

    func testRestrictionPlacesAClassInItsLongestPackage() {
        let restriction = JavaModuleVisibility.Restriction(
            packages: ["com.a.api", "com.a.api.internal", "com.a.impl"], exported: ["com.a.api"]
        )
        XCTAssertTrue(restriction.allows(qualifiedName: "com.a.api.Api"))
        XCTAssertTrue(restriction.allows(qualifiedName: "com.a.api.Api.Nested"), "a nested class follows its outer class")
        XCTAssertFalse(restriction.allows(qualifiedName: "com.a.api.internal.Hidden"), "a subpackage is its own package")
        XCTAssertFalse(restriction.allows(qualifiedName: "com.a.impl.Impl"))
        XCTAssertTrue(restriction.allows(qualifiedName: "com.a.unknown.Elsewhere"), "an unknown package fails open")
    }

    // MARK: - Fixture

    /// Modules `:a` (its types under `com.a…`) and `:b`, whose `main` source set depends on `:a`.
    private struct Project {
        let index: JavaIndex
        let provider: JavaCompletionProvider
        let use: URL
    }

    private func write(_ path: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeProject(
        aModuleInfo: String?, bModuleInfo: String?, aTypes: [String], extraModule: (name: String, info: String)? = nil,
        aMembers: [String: [JavaMethodStub]] = [:]
    ) async throws -> Project {
        let aDir = root.appendingPathComponent("a/src/main/java")
        let bDir = root.appendingPathComponent("b/src/main/java")
        if let aModuleInfo { _ = try write("a/src/main/java/module-info.java", aModuleInfo) }
        if let bModuleInfo { _ = try write("b/src/main/java/module-info.java", bModuleInfo) }
        let use = try write("b/src/main/java/com/b/Use.java", "package com.b; class Use {}")

        let paths = JavaIndexPaths(root: root.appendingPathComponent("index"))
        let shard = paths.projectSourcesShard(for: aDir.standardizedFileURL)
        try FileManager.default.createDirectory(at: shard.deletingLastPathComponent(), withIntermediateDirectories: true)
        var stubs: [JavaClassStub] = []
        for name in aTypes {
            // The package is the lowercase prefix; a nested class (`com.a.api.Api.Inner`) shares its outer class's file.
            let packageName = name.split(separator: ".").prefix { $0.first?.isLowercase == true }.joined(separator: ".")
            let topLevel = name.split(separator: ".").first { $0.first?.isUppercase == true }.map(String.init) ?? name
            let url = try write("a/src/main/java/\(packageName.replacingOccurrences(of: ".", with: "/"))/\(topLevel).java", "// \(name)")
            let simple = String(name.split(separator: ".").last!)
            stubs.append(JavaClassStub(
                binaryName: name, qualifiedName: name, simpleName: simple, packageName: packageName,
                kind: .classKind, modifiers: [.publicFlag], methods: aMembers[name] ?? [], origin: .source(url, nameRange: 0..<1)
            ))
        }
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 1, modificationDate: 0), to: shard)
        let sources: [JavaIndex.Source] = [.init(precedence: 1, reader: try JavaIndexShardReader(url: shard), shardPath: shard.path)]
        var subprojects: [JavaGradleProjectModel.Subproject] = [
            .init(path: ":a", directory: root.appendingPathComponent("a"), sourceSets: [.init(name: "main", sourceDirs: [aDir])])
        ]
        var bDependencies: [JavaGradleProjectModel.ProjectDependency] = [.init(projectPath: ":a", sourceSetName: "main")]
        if let extraModule {
            let dir = root.appendingPathComponent("\(extraModule.name)/src/main/java")
            _ = try write("\(extraModule.name)/src/main/java/module-info.java", extraModule.info)
            subprojects.append(.init(path: ":\(extraModule.name)", directory: root.appendingPathComponent(extraModule.name), sourceSets: [
                .init(name: "main", sourceDirs: [dir], projectDependencies: [.init(projectPath: ":a", sourceSetName: "main")])
            ]))
            // A Gradle compile classpath is flattened: b sees a through mid, so both are listed.
            bDependencies = [.init(projectPath: ":\(extraModule.name)", sourceSetName: "main"), .init(projectPath: ":a", sourceSetName: "main")]
        }
        subprojects.append(.init(path: ":b", directory: root.appendingPathComponent("b"), sourceSets: [
            .init(name: "main", sourceDirs: [bDir], projectDependencies: bDependencies)
        ]))
        let index = JavaIndex()
        await index.setSources(sources)
        let model = JavaGradleProjectModel(formatVersion: 2, gradleVersion: "9.0", subprojects: subprojects)
        let provider = JavaCompletionProvider(index: index)
        await provider.setSourceSetClasspath(model, indexPaths: paths)
        return Project(index: index, provider: provider, use: use)
    }

    private func complete(_ source: String, in project: Project, invocationCount: Int = 1) async -> Set<String> {
        let marker = source.range(of: "€")!
        let text = source.replacingOccurrences(of: "€", with: "")
        let offset = source.utf16.distance(from: source.utf16.startIndex, to: marker.lowerBound.samePosition(in: source.utf16)!)
        let before = text.prefix(offset)
        let position = TextPosition(
            line: before.filter { $0 == "\n" }.count,
            column: before.split(separator: "\n", omittingEmptySubsequences: false).last?.utf16.count ?? 0,
            utf16Offset: offset
        )
        let document = Document(
            id: DocumentID(), url: project.use, displayName: "Use.java",
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
        )
        let items = await project.provider.provide(
            context: makeCompletionContext(document: document, trigger: .manual, invocationCount: invocationCount)
        )
        return Set(items.map { "\($0.label)|\($0.labelDetail ?? "")" })
    }

    private func offers(_ simple: String, _ qualified: String, in project: Project, invocationCount: Int = 1) async -> Bool {
        let found = await complete("package com.b; class Use { void m() { \(simple)€ } }", in: project, invocationCount: invocationCount)
        return found.contains("\(simple)| (\(qualified))") || found.contains { $0.hasPrefix("\(simple)|") && $0.contains(qualified) }
    }

    // MARK: - Completion

    func testANonExportedPackageOfAReadModuleIsNotOffered() async throws {
        let project = try await makeProject(
            aModuleInfo: "module com.a { exports com.a.api; }", bModuleInfo: "module com.b { requires com.a; }",
            aTypes: ["com.a.api.Api", "com.a.internal.Secret"]
        )
        let exported = await offers("Api", "com.a.api", in: project)
        let internalType = await offers("Secret", "com.a.internal", in: project)
        XCTAssertTrue(exported, "the exported type is offered")
        XCTAssertFalse(internalType, "com.a.internal is not exported: javac rejects it")
    }

    func testAClasspathProjectSeesEverything() async throws {
        let project = try await makeProject(
            aModuleInfo: "module com.a { exports com.a.api; }", bModuleInfo: nil,
            aTypes: ["com.a.api.Api", "com.a.internal.Secret"]
        )
        let internalType = await offers("Secret", "com.a.internal", in: project)
        XCTAssertTrue(internalType, "no module-info in the file's source root: classpath rules")
    }

    func testAnUnrequiredModuleIsLeftAlone() async throws {
        let project = try await makeProject(
            aModuleInfo: "module com.a { exports com.a.api; }", bModuleInfo: "module com.b { }",
            aTypes: ["com.a.api.Api", "com.a.internal.Secret"]
        )
        let internalType = await offers("Secret", "com.a.internal", in: project)
        XCTAssertTrue(internalType, "a module this one does not read is not restricted: the editor offers it and the compiler explains")
    }

    func testAQualifiedExportIsVisibleOnlyToItsTargets() async throws {
        let target = try await makeProject(
            aModuleInfo: "module com.a { exports com.a.internal to com.b; }", bModuleInfo: "module com.b { requires com.a; }",
            aTypes: ["com.a.internal.Secret"]
        )
        let toTarget = await offers("Secret", "com.a.internal", in: target)
        XCTAssertTrue(toTarget)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let other = try await makeProject(
            aModuleInfo: "module com.a { exports com.a.internal to com.somebody.else; }", bModuleInfo: "module com.b { requires com.a; }",
            aTypes: ["com.a.internal.Secret"]
        )
        let toOther = await offers("Secret", "com.a.internal", in: other)
        XCTAssertFalse(toOther)
    }

    func testRequiresTransitiveCarriesTheRestrictionThrough() async throws {
        // com.b requires com.mid, which `requires transitive com.a`: b reads a, so a's exports apply.
        let transitive = try await makeProject(
            aModuleInfo: "module com.a { exports com.a.api; }", bModuleInfo: "module com.b { requires com.mid; }",
            aTypes: ["com.a.api.Api", "com.a.internal.Secret"],
            extraModule: ("mid", "module com.mid { requires transitive com.a; }")
        )
        let hiddenThrough = await offers("Secret", "com.a.internal", in: transitive)
        XCTAssertFalse(hiddenThrough)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Without `transitive`, b does not read a at all, so a is not restricted.
        let plain = try await makeProject(
            aModuleInfo: "module com.a { exports com.a.api; }", bModuleInfo: "module com.b { requires com.mid; }",
            aTypes: ["com.a.api.Api", "com.a.internal.Secret"],
            extraModule: ("mid", "module com.mid { requires com.a; }")
        )
        let visibleWithout = await offers("Secret", "com.a.internal", in: plain)
        XCTAssertTrue(visibleWithout)
    }

    func testNestedClassesFollowTheirOuterClassAndSubpackagesAreSeparate() async throws {
        let project = try await makeProject(
            aModuleInfo: "module com.a { exports com.a.api; }", bModuleInfo: "module com.b { requires com.a; }",
            aTypes: ["com.a.api.Api", "com.a.api.Api.Inner", "com.a.api.internal.Hidden"]
        )
        let nested = await offers("Inner", "com.a.api", in: project)
        let subpackage = await offers("Hidden", "com.a.api.internal", in: project)
        XCTAssertTrue(nested)
        XCTAssertFalse(subpackage, "exporting com.a.api does not export com.a.api.internal")
    }

    func testAValueFromANonExportedTypeStillCompletesItsMembers() async throws {
        let secretMethod = JavaMethodStub(name: "reveal", parameters: [], returnType: .primitive(.int), modifiers: [.publicFlag])
        let secretType = JavaTypeRef.classType(qualifiedName: "com.a.internal.Secret", arguments: [], outer: nil)
        let project = try await makeProject(
            aModuleInfo: "module com.a { exports com.a.api; }", bModuleInfo: "module com.b { requires com.a; }",
            aTypes: ["com.a.api.Api", "com.a.internal.Secret"],
            aMembers: [
                "com.a.api.Api": [JavaMethodStub(name: "secret", parameters: [], returnType: secretType, modifiers: [.publicFlag])],
                "com.a.internal.Secret": [secretMethod]
            ]
        )
        let members = await complete("package com.b; import com.a.api.Api; class Use { void m(Api api) { api.secret().€ } }", in: project)
        XCTAssertTrue(members.contains { $0.hasPrefix("reveal") }, "type resolution is not narrowed, only the names offered: \(members.sorted().prefix(8))")
    }

    func testASecondInvocationLooksPastTheModuleBoundary() async throws {
        let project = try await makeProject(
            aModuleInfo: "module com.a { exports com.a.api; }", bModuleInfo: "module com.b { requires com.a; }",
            aTypes: ["com.a.api.Api", "com.a.internal.Secret"]
        )
        let first = await offers("Secret", "com.a.internal", in: project, invocationCount: 1)
        let second = await offers("Secret", "com.a.internal", in: project, invocationCount: 2)
        XCTAssertFalse(first)
        XCTAssertTrue(second, "like IntelliJ's second basic completion, it looks past the classpath and module rules")
    }

    func testAnEditToModuleInfoIsPickedUp() async throws {
        let project = try await makeProject(
            aModuleInfo: "module com.a { exports com.a.api; }", bModuleInfo: "module com.b { requires com.a; }",
            aTypes: ["com.a.api.Api", "com.a.internal.Secret"]
        )
        let before = await offers("Secret", "com.a.internal", in: project)
        XCTAssertFalse(before)
        let info = root.appendingPathComponent("a/src/main/java/module-info.java")
        try "module com.a { exports com.a.api; exports com.a.internal; }".write(to: info, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: info.path)
        let after = await offers("Secret", "com.a.internal", in: project)
        XCTAssertTrue(after)
    }
}
