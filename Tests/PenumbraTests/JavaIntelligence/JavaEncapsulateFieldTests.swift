import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaEncapsulateFieldTests: XCTestCase {
    private var fixture: JavaReferenceFixture!

    override func setUpWithError() throws {
        fixture = try JavaReferenceFixture()
    }

    func testGenerateAccessorsInsertsGetterAndSetter() async throws {
        try add("p/T.java", """
        package p;
        class T {
            private int €value;
        }
        """)
        let plan = try await generatePlan()
        XCTAssertNil(plan.blockingError)
        let text = try XCTUnwrap(try apply(plan)["p/T.java"])
        XCTAssertTrue(text.contains("public int getValue()"))
        XCTAssertTrue(text.contains("return this.value;"))
        XCTAssertTrue(text.contains("public void setValue(int value)"))
        XCTAssertTrue(text.contains("this.value = value;"))
    }

    func testGenerateAccessorsBooleanUsesIsPrefix() async throws {
        try add("p/T.java", """
        package p;
        class T {
            private boolean €active;
        }
        """)
        let plan = try await generatePlan()
        XCTAssertNil(plan.blockingError)
        let text = try XCTUnwrap(try apply(plan)["p/T.java"])
        XCTAssertTrue(text.contains("public boolean isActive()"))
        XCTAssertFalse(text.contains("getActive()"))
    }

    func testGenerateAccessorsSkipsWhenPresent() async throws {
        try add("p/T.java", """
        package p;
        class T {
            private int value;
            public int getValue() { return value; }
            public void setValue(int value) { this.value = value; }
            void run() { €value++; }
        }
        """)
        let plan = try await generatePlan()
        XCTAssertEqual(plan.blockingError, "Getter and setter already exist.")
    }

    func testEncapsulateMakesFieldPrivate() async throws {
        try add("p/T.java", """
        package p;
        class T {
            public int €count;
        }
        """)
        let plan = try await encapsulatePlan()
        XCTAssertNil(plan.blockingError)
        let text = try XCTUnwrap(try apply(plan)["p/T.java"])
        XCTAssertTrue(text.contains("private int count;"))
        XCTAssertFalse(text.contains("public int count;"))
        XCTAssertTrue(text.contains("public int getCount()"))
        XCTAssertTrue(text.contains("public void setCount(int count)"))
    }

    func testEncapsulateReplacesExternalRead() async throws {
        try add("p/Holder.java", """
        package p;
        class Holder {
            public int €value;
        }
        """)
        try add("p/Client.java", """
        package p;
        class Client {
            void run(Holder h) {
                int x = h.value;
            }
        }
        """)
        let plan = try await encapsulatePlan()
        XCTAssertNil(plan.blockingError)
        let result = try apply(plan)
        let holder = try XCTUnwrap(result["p/Holder.java"])
        let client = try XCTUnwrap(result["p/Client.java"])
        XCTAssertTrue(holder.contains("private int value;"))
        XCTAssertTrue(holder.contains("getValue()"))
        XCTAssertTrue(client.contains("h.getValue()"))
        XCTAssertFalse(client.contains("h.value"))
    }

    func testEncapsulateKeepsAccessInsideDeclaringClass() async throws {
        try add("p/T.java", """
        package p;
        class T {
            public int €value;
            void run() {
                value = 1;
                int x = value;
            }
        }
        """)
        let plan = try await encapsulatePlan()
        XCTAssertNil(plan.blockingError)
        let text = try XCTUnwrap(try apply(plan)["p/T.java"])
        XCTAssertTrue(text.contains("value = 1;"))
        XCTAssertTrue(text.contains("int x = value;"))
        XCTAssertFalse(text.contains("int x = getValue();"))
        XCTAssertFalse(text.contains("setValue(1)"))
    }

    func testEncapsulateFinalFieldOmitsSetter() async throws {
        try add("p/T.java", """
        package p;
        class T {
            public final int €value = 1;
        }
        """)
        let plan = try await encapsulatePlan()
        XCTAssertNil(plan.blockingError)
        let text = try XCTUnwrap(try apply(plan)["p/T.java"])
        XCTAssertTrue(text.contains("getValue()"))
        XCTAssertFalse(text.contains("setValue("))
    }

    // MARK: - Helpers

    private func add(_ name: String, _ marked: String) throws {
        try fixture.add(name, marked)
    }

    private func fieldContext() async throws -> JavaEncapsulateField.FieldContext {
        let environment = try await fixture.build()
        let caret = try XCTUnwrap(fixture.caretLocation)
        let source = try XCTUnwrap(fixture.sources[caret.file])
        let context = await JavaEncapsulateField.fieldContext(
            source: source, url: fixture.url(caret.file), caretUTF16: caret.utf16Offset,
            index: environment.index, environment: environment
        )
        return try XCTUnwrap(context)
    }

    private func generatePlan() async throws -> WorkspaceEditPlan {
        let field = try await fieldContext()
        return await JavaEncapsulateField.generateAccessorsPlan(field: field)
    }

    private func encapsulatePlan() async throws -> WorkspaceEditPlan {
        let environment = try await fixture.build()
        let field = try await fieldContext()
        return await JavaEncapsulateField.encapsulatePlan(
            field: field, roots: [fixture.root], candidates: JavaTextScanCandidateSource(), environment: environment
        )
    }

    private func apply(_ plan: WorkspaceEditPlan) throws -> [String: String] {
        let edit = plan.workspaceEdit()
        var result: [String: String] = [:]
        for url in edit.changes.keys {
            var text = try String(contentsOf: url, encoding: .utf8) as NSString
            for change in edit.orderedEdits(for: url) {
                let length = change.range.end.utf16Offset - change.range.start.utf16Offset
                text = text.replacingCharacters(
                    in: NSRange(location: change.range.start.utf16Offset, length: length), with: change.replacement
                ) as NSString
            }
            let prefix = fixture.root.standardizedFileURL.path + "/"
            result[url.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "")] = text as String
        }
        return result
    }
}
