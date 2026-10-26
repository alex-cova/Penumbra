import Foundation
import SwiftIntelligence
import XCTest
@testable import SwiftIntelligence
@testable import Umbra

final class SwiftModelTests: XCTestCase {
    private func model(_ source: String, file: StaticString = #filePath, line: UInt = #line) -> SwiftFileModel {
        guard let parsed = SwiftAnalysis.parse(source) else {
            XCTFail("Swift source did not parse", file: file, line: line)
            return SwiftFileModel()
        }
        return parsed.model
    }

    private func declaration(
        _ name: String, in declarations: [SwiftFileModel.Declaration], kind: SwiftFileModel.Kind? = nil
    ) -> SwiftFileModel.Declaration? {
        declarations.first { $0.name == name && (kind == nil || $0.kind == kind) }
    }

    func testStructMembersParametersAndWrittenTypes() throws {
        let m = model("""
        public struct Point: Equatable, Codable {
            var x: Int = 0
            let y: Double
            private(set) var z = 1
            static let origin = Point(x: 0, y: 0)
            init(x: Int, y: Double) { self.x = x; self.y = y }
            func move(by dx: Int, _ dy: Int = 0) -> Point { Point(x: x + dx, y: y) }
            mutating func reset() {}
        }
        """)
        let point = try XCTUnwrap(declaration("Point", in: m.declarations))
        XCTAssertEqual(point.kind, .struct)
        XCTAssertEqual(point.access, .public)
        XCTAssertEqual(point.inherits, ["Equatable", "Codable"])
        XCTAssertTrue(point.isTopLevel)

        let x = try XCTUnwrap(declaration("x", in: point.members))
        XCTAssertEqual(x.kind, .property)
        XCTAssertEqual(x.typeName, "Int")
        let z = try XCTUnwrap(declaration("z", in: point.members))
        XCTAssertNil(z.typeName)
        XCTAssertEqual(z.valueChain, SwiftChain(base: .instance("Int"), steps: []))
        let origin = try XCTUnwrap(declaration("origin", in: point.members))
        XCTAssertTrue(origin.isStatic)
        // `Point(x: 0, y: 0)`: a call of the name `Point` with two labels.
        let originChain = try XCTUnwrap(origin.valueChain)
        guard case .name(let originBase, _) = originChain.base else { return XCTFail("base \(originChain.base)") }
        XCTAssertEqual(originBase, "Point")
        XCTAssertEqual(originChain.steps, [.call(labels: ["x", "y"])])

        let initializer = try XCTUnwrap(point.members.first { $0.kind == .initializer })
        XCTAssertEqual(initializer.parameters.map(\.name), ["x", "y"])
        XCTAssertEqual(initializer.parameters.map(\.typeName), ["Int", "Double"])

        let move = try XCTUnwrap(declaration("move", in: point.members))
        XCTAssertEqual(move.typeName, "Point")
        XCTAssertEqual(move.parameters.map(\.label), ["by", nil])
        XCTAssertEqual(move.parameters.map(\.name), ["dx", "dy"])
        XCTAssertEqual(move.parameters.map(\.hasDefault), [false, true])
        XCTAssertTrue(move.signature.hasPrefix("func move(by dx: Int"), move.signature)
    }

    func testClassGenericsInheritanceDocCommentAndModifiers() throws {
        let m = model("""
        /// A dog.
        open class Dog<T: Hashable>: Animal, Walker {
            override func speak() async throws -> String { "w" }
            class func make() -> Dog<Int> { Dog() }
            subscript(i: Int) -> Int { i }
            deinit {}
        }
        """)
        let dog = try XCTUnwrap(declaration("Dog", in: m.declarations))
        XCTAssertEqual(dog.access, .open)
        XCTAssertEqual(dog.generics, ["T"])
        XCTAssertEqual(dog.inherits, ["Animal", "Walker"])
        XCTAssertEqual(dog.docComment, "A dog.")
        let speak = try XCTUnwrap(declaration("speak", in: dog.members))
        XCTAssertTrue(speak.isOverride)
        XCTAssertEqual(speak.typeName, "String")
        let make = try XCTUnwrap(declaration("make", in: dog.members))
        XCTAssertTrue(make.isStatic)
        XCTAssertEqual(make.typeName, "Dog")
        XCTAssertTrue(dog.members.contains { $0.kind == .subscript })
        XCTAssertTrue(dog.members.contains { $0.kind == .deinitializer })
    }

    func testExtensionsAreNamedForTheTypeTheyExtend() throws {
        let m = model("""
        extension Point: Equatable {
            func distance() -> Double { 0 }
        }
        extension Swift.Array {}
        """)
        let extensions = m.declarations.filter { $0.kind == .extension }
        XCTAssertEqual(extensions.map(\.name), ["Point", "Array"])
        XCTAssertEqual(extensions[0].inherits, ["Equatable"])
        XCTAssertEqual(extensions[0].members.map(\.name), ["distance"])
    }

    func testProtocolRequirementsAndEnumCases() throws {
        let m = model("""
        protocol Shape: AnyObject {
            associatedtype Item
            var area: Double { get }
            func scale(by: Double) -> Self
            init(side: Double)
        }
        enum Color: String, CaseIterable {
            case red = "r", green
            case rgb(Int, Int, Int)
        }
        """)
        let shape = try XCTUnwrap(declaration("Shape", in: m.declarations))
        XCTAssertEqual(shape.kind, .protocol)
        XCTAssertEqual(shape.inherits, ["AnyObject"])
        XCTAssertTrue(shape.members.contains { $0.kind == .associatedType && $0.name == "Item" })
        XCTAssertEqual(declaration("area", in: shape.members)?.typeName, "Double")
        XCTAssertEqual(declaration("scale", in: shape.members)?.typeName, "Self")
        XCTAssertTrue(shape.members.contains { $0.kind == .initializer })

        let color = try XCTUnwrap(declaration("Color", in: m.declarations))
        XCTAssertEqual(color.kind, .enum)
        XCTAssertEqual(color.inherits, ["String", "CaseIterable"])
        XCTAssertEqual(color.members.filter { $0.kind == .enumCase }.map(\.name), ["red", "green", "rgb"])
        XCTAssertEqual(declaration("rgb", in: color.members)?.parameters.count, 3)
    }

    func testImportsAndAttributes() {
        let m = model("""
        import Foundation
        @testable import MyModule
        import struct Swift.Int
        @main struct App { static func main() {} }
        """)
        XCTAssertEqual(m.imports.map(\.module), ["Foundation", "MyModule", "Swift"])
        XCTAssertEqual(m.imports.map(\.isTestable), [false, true, false])
        XCTAssertEqual(declaration("App", in: m.declarations)?.attributes, ["main"])
    }

    func testLocalBindingsHaveBlockScopes() throws {
        let source = """
        func f(items: [Int], name: String?) {
            guard let name = name else { return }
            if let a = items.first { print(a) }
            for (i, item) in items.enumerated() { print(i, item) }
            let c = items.map { x in x + 1 }
            do { try g() } catch { print(error) }
        }
        """
        let m = model(source)
        let function = try XCTUnwrap(declaration("f", in: m.declarations))
        let afterGuard = (source as NSString).range(of: "if let a").location
        // The guard's binding outlives the guard; the parameter is shadowed from there on.
        let bound = try XCTUnwrap(m.binding(named: "name", at: afterGuard))
        XCTAssertEqual(bound.symbolKind, .local)
        // `a` is visible inside the if body only.
        let inside = (source as NSString).range(of: "print(a)").location
        XCTAssertNotNil(m.binding(named: "a", at: inside))
        XCTAssertNil(m.binding(named: "a", at: (source as NSString).range(of: "for (i").location))
        // Tuple pattern, closure parameter, implicit error.
        XCTAssertNotNil(m.binding(named: "i", at: (source as NSString).range(of: "print(i").location))
        XCTAssertNotNil(m.binding(named: "item", at: (source as NSString).range(of: "print(i").location + 8))
        XCTAssertNotNil(m.binding(named: "x", at: (source as NSString).range(of: "x + 1").location))
        XCTAssertNotNil(m.binding(named: "error", at: (source as NSString).range(of: "print(error)").location))
        XCTAssertEqual(function.parameters.map(\.name), ["items", "name"])
        XCTAssertEqual(function.parameters.first?.typeName, "[Int]")
        XCTAssertEqual(function.parameters.last?.typeName, "String")
    }

    func testMemberUsesCarryTheirReceiverChain() throws {
        let source = "func f() { let r = obj?.first.name(label: 1) }\n"
        let m = model(source)
        let name = try XCTUnwrap(m.uses.first { $0.name == "name" })
        guard case .member(let chain) = name.role else { return XCTFail("not a member use") }
        XCTAssertEqual(chain.steps, [.member("first")])
        guard case .name(let base, _) = chain.base else { return XCTFail("base \(chain.base)") }
        XCTAssertEqual(base, "obj")
        XCTAssertTrue(name.isCall)
        XCTAssertEqual(name.callLabels, ["label"])
    }

    func testImplicitMemberAndConstructorUses() throws {
        let m = model("""
        let a: Color = .red
        let b = Array<Int>()
        """)
        XCTAssertTrue(m.uses.contains { $0.name == "red" && { if case .implicitMember = $0.role { return true }; return false }($0) })
        XCTAssertTrue(m.uses.contains { $0.name == "Array" && $0.isCall })
    }

    func testSwitchPatternsBindOnlyWhatTheyBind() {
        let source = """
        func f() {
            switch c {
            case .rgb(let r, let g, _): print(r)
            case let .named(n): print(n)
            case .a, .b: break
            case let (x, y): print(x)
            }
        }
        """
        let m = model(source)
        func visible(_ name: String, at marker: String) -> Bool {
            m.binding(named: name, at: (source as NSString).range(of: marker).location) != nil
        }
        XCTAssertTrue(visible("r", at: "print(r)"))
        XCTAssertTrue(visible("n", at: "print(n)"))
        XCTAssertTrue(visible("x", at: "print(x)"))
        // Case names are not bindings.
        XCTAssertNil(m.binding(named: "named", at: (source as NSString).range(of: "print(n)").location))
        XCTAssertNil(m.binding(named: "rgb", at: (source as NSString).range(of: "print(r)").location))
        // A binding of one case is not visible in the next.
        XCTAssertFalse(visible("r", at: "print(n)"))
    }

    func testClassMembersAreStaticAndTypesNameDictionariesAndArrays() throws {
        let m = model("""
        class A {
            class func make() {}
            class var v: Int { 1 }
            var d: [String: Int] = [:]
            var e: [Int?] = []
        }
        """)
        let a = try XCTUnwrap(declaration("A", in: m.declarations))
        XCTAssertEqual(a.kind, .class)
        XCTAssertTrue(try XCTUnwrap(declaration("make", in: a.members)).isStatic)
        XCTAssertTrue(try XCTUnwrap(declaration("v", in: a.members)).isStatic)
        XCTAssertEqual(declaration("d", in: a.members)?.typeName, "[String: Int]")
        XCTAssertEqual(declaration("e", in: a.members)?.typeName, "[Int]")
    }

    func testBrokenSourceReportsErrorsAndStillFindsDeclarations() {
        let m = model("struct Broken {\n    func a( {\n    var x: = \n}\nlet y = \n")
        XCTAssertFalse(m.errors.isEmpty)
        XCTAssertNotNil(declaration("Broken", in: m.declarations))
    }

    func testModernSyntaxParsesAtTheOriginalOffsets() throws {
        let source = """
        struct S {
            nonisolated(unsafe) static var cache = 0
            var v = 0 { didSet { v = 1 } }
            func f(x: Int) -> Int {
                let y = switch x {
                case 0: 1
                default: 2
                }
                let z =
                    switch x {
                case 0: 1
                default: 2
                }
                if await ready() { return y }
                if await gate.ready { return y }
                while await gate.ready { return y }
                let pattern = /at\\s+/
                let hunk = /^@@ -(\\d+)/
                let located = /at\\s+(?:[\\w.$\\/@]+\\/)?([\\w.$]+)/
                let open = "/*"
                let close = "*/"
                let gated = true
                let id = "a"
                let body = #"{"gated":\\#(gated ? #""manual""# : "false"),"id":"\\#(id)"}"#
                let metatype = (Int?, Array<String>).self
                let scaled = y
                    * z
                let unit = ()
                return y + z + scaled
            }
        }
        let table = [1]
        ///**
        // * kept
        // */
        let after = table
        @available(tvOS, unavailable)
        @available(watchOS, unavailable)
        #Preview("p") { Text("é") }
        @Test func t() { #expect(1 == 1) }
        #if swift(>=5.10)
        @available(macOS 10.15, *)
        #endif
        struct Wrapped {}
        func bits(_ a: UInt64, _ b: UInt64) -> UInt64 {
            switch a {
            case 0x24 where a, 0x4C where b:
                return a
                    ^ UInt64(b)
            default:
                return 0
            }
        }
        """
        let m = model(source)
        XCTAssertTrue(m.errors.isEmpty, "\(m.errors.map(\.bytes))")
        let s = try XCTUnwrap(declaration("S", in: m.declarations))
        XCTAssertTrue(s.members.contains { $0.name == "cache" && $0.isStatic })
        XCTAssertNotNil(declaration("v", in: s.members))
        XCTAssertTrue(s.members.contains { $0.name == "f" })
        XCTAssertEqual(declaration("t", in: m.declarations)?.attributes, ["Test"])
        XCTAssertNotNil(declaration("bits", in: m.declarations))
        let f = try XCTUnwrap(declaration("f", in: s.members))
        XCTAssertEqual(String(decoding: Array(source.utf8)[f.nameBytes], as: UTF8.self), "f")
        let cache = try XCTUnwrap(declaration("cache", in: s.members))
        XCTAssertEqual(String(decoding: Array(source.utf8)[cache.nameBytes], as: UTF8.self), "cache")
    }

    /// Paths that still produce a syntax problem. Empty: the Swift in this repository parses.
    /// A file that starts failing has to be fixed, or added here with the construct that failed.
    private static let grammarGapAllowlist: Set<String> = []

    /// Fails when a `.swift` file outside `grammarGapAllowlist` starts producing a syntax problem.
    func testRepositorySwiftFilesStayWithinTheSyntaxProblemCeiling() throws {
        let root = repositoryRoot()
        // SwiftCorpus files are completion probes and stop mid-expression (`name./*|*/`).
        let skip: Set<String> = [".build", ".git", "checkouts", ".swiftpm", "DerivedData", "node_modules", "SwiftCorpus"]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("could not list \(root.path)")
            return
        }
        var unexpected: [String] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory, skip.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "swift" else { continue }
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = url.path.hasPrefix(root.path + "/")
                ? String(url.path.dropFirst(root.path.count + 1))
                : url.lastPathComponent
            guard !Self.grammarGapAllowlist.contains(relative) else { continue }
            guard let parsed = SwiftAnalysis.parseModel(source) else {
                unexpected.append("\(relative) (no tree)")
                continue
            }
            if let first = parsed.errors.first {
                let bytes = Array(source.utf8)
                let start = min(first.bytes.lowerBound, bytes.count)
                let end = min(max(first.bytes.upperBound, start + 1), bytes.count)
                let windowStart = max(0, start - 24)
                let windowEnd = min(bytes.count, end + 24)
                let snippet = String(decoding: bytes[windowStart..<windowEnd], as: UTF8.self)
                    .replacingOccurrences(of: "\n", with: "↵")
                unexpected.append("\(relative) [\(parsed.errors.count)] \(snippet)")
            }
        }
        XCTAssertTrue(
            unexpected.isEmpty,
            "Swift files outside the grammar-gap allowlist have syntax problems:\n" + unexpected.joined(separator: "\n")
        )
    }

    private func repositoryRoot(file: StaticString = #filePath) -> URL {
        // The outermost package: `Umbra/` has its own Package.swift, the repository root is above it.
        var url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        let manager = FileManager.default
        var found: URL?
        while url.path != "/" {
            if manager.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                found = url
            }
            url.deleteLastPathComponent()
        }
        return found ?? URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
    }

    func testDeepNestingDoesNotOverflowTheStack() {
        let depth = 250
        let source = "let value = " + String(repeating: "(", count: depth) + "1" + String(repeating: ")", count: depth)
            + "\nlet chain = a" + String(repeating: ".b", count: depth) + "\nstruct Leaf {}\n"
        let m = model(source)
        XCTAssertNotNil(declaration("Leaf", in: m.declarations))
    }
}
