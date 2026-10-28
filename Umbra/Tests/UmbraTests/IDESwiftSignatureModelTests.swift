import AppKit
import EditorIntelligence
import SwiftIntelligence
import SwiftUI
import XCTest
@testable import Umbra

/// The state behind Change Function Signature for Swift, and the form that shows it.
@MainActor
final class IDESwiftSignatureModelTests: XCTestCase {
    private func model() -> IDESwiftSignatureModel {
        IDESwiftSignatureModel(functionName: "move", parameters: [
            SwiftSignatureParameter(oldIndex: 0, label: "from", name: "start", type: "Int"),
            SwiftSignatureParameter(oldIndex: 1, label: "_", name: "end", type: "Int", defaultValue: "0"),
        ])
    }

    func testItStartsFromTheFunctionsOwnParametersAndIsUnchanged() {
        let model = model()
        XCTAssertFalse(model.isChanged)
        XCTAssertFalse(model.canCommit)
        XCTAssertEqual(model.preview, "move(from start: Int, _ end: Int = 0)")
        XCTAssertNil(model.problem)
    }

    func testMovingRemovingAndRenamingChangeThePreview() {
        let model = model()
        model.move(0, by: 1)
        XCTAssertEqual(model.preview, "move(_ end: Int = 0, from start: Int)")
        XCTAssertTrue(model.canCommit)
        XCTAssertFalse(model.canMove(1, by: 1))
        XCTAssertFalse(model.canMove(0, by: -1))
        model.move(1, by: -1)
        XCTAssertFalse(model.isChanged, "back where it was")

        model.remove(1)
        XCTAssertEqual(model.preview, "move(from start: Int)")
        model.rename(0, to: "begin")
        XCTAssertEqual(model.preview, "move(from begin: Int)", "the label stays when it differed from the name")
    }

    func testTheLabelFollowsTheNameWhileTheyAreTheSame() {
        let model = IDESwiftSignatureModel(functionName: "f", parameters: [SwiftSignatureParameter(oldIndex: 0, label: "x", name: "x", type: "Int")])
        model.rename(0, to: "y")
        XCTAssertEqual(model.parameters[0].label, "y")
        XCTAssertEqual(model.preview, "f(y: Int)")
    }

    func testANewParameterStartsAsAnEditableValueWithADefault() {
        let model = model()
        model.addParameter()
        model.addParameter()
        XCTAssertEqual(model.parameters.suffix(2).map(\.name), ["value", "value2"])
        XCTAssertNil(model.problem)
        XCTAssertTrue(model.canCommit)
        model.parameters[2].defaultValue = ""
        XCTAssertNotNil(model.problem, "no default and no value for the calls")
        XCTAssertFalse(model.canCommit)
        model.parameters[2].callSiteValue = "5"
        XCTAssertNil(model.problem)
        model.parameters[3].name = "value"
        XCTAssertNotNil(model.problem, "two names")
    }

    func testTheResultIsWhatTheProviderReads() throws {
        let model = model()
        model.move(0, by: 1)
        let json = try XCTUnwrap(model.result["parameters"])
        let change = try XCTUnwrap(SwiftSignatureChange(json: json))
        XCTAssertEqual(change.parameters.map(\.oldIndex), [1, 0])
    }

    func testItIsBuiltFromTheDescriptorTheProviderOffers() throws {
        let source = "func move(from start: Int, _ end: Int) {}\n"
        let subject = try XCTUnwrap(SwiftChangeSignature.subject(in: source, caret: 6))
        let descriptor = RefactoringDescriptor(
            id: .changeSignature, title: "Change Function Signature…", requiresSelection: false, parameterKeys: ["parameters"],
            suggestedParameters: ["parameters": SwiftSignatureChange(parameters: subject.parameters).json, "functionName": subject.name]
        )
        let built = try XCTUnwrap(IDESwiftSignatureModel(descriptor: descriptor))
        XCTAssertEqual(built.functionName, "move")
        XCTAssertEqual(built.parameters, subject.parameters)
        XCTAssertNil(IDESwiftSignatureModel(descriptor: RefactoringDescriptor(id: .changeSignature, title: "x")))
    }

    func testTheFormRendersTheListAndThePreview() throws {
        let host = NSHostingView(rootView: IDESwiftSignaturePromptView(model: model(), onFinish: { _ in }).preferredColorScheme(.dark))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 320)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var colours = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    colours.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
                }
            }
        }
        XCTAssertGreaterThan(colours.count, 4, "the form drew nothing")
    }
}
