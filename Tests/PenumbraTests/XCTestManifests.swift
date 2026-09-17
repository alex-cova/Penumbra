import Foundation
import XCTest

#if !canImport(ObjectiveC)
public func allTests() -> [XCTestCaseEntry] {
    [
        testCase(PenumbraTests.allTests)
    ]
}
#endif
