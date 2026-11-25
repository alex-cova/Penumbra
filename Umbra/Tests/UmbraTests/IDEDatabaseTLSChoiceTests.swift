import DatabaseKit
import XCTest

@testable import Umbra

@MainActor
final class IDEDatabaseTLSChoiceTests: XCTestCase {
    func testTheThreeChoicesMapOntoTheStoredFlags() {
        let editor = IDEDatabaseConnectionEditor.makeNew()
        editor.engine = .postgres
        editor.host = "db.example.com"

        editor.tlsChoice = .off
        XCTAssertFalse(editor.connection().useTLS)
        XCTAssertNil(editor.connection().tlsRequired)

        editor.tlsChoice = .prefer
        XCTAssertTrue(editor.connection().useTLS)
        XCTAssertNil(editor.connection().tlsRequired, "prefer must not be saved as strict")

        editor.tlsChoice = .require
        XCTAssertTrue(editor.connection().useTLS)
        XCTAssertEqual(editor.connection().tlsRequired, true)
    }

    func testEditingAnExistingConnectionShowsItsCurrentChoice() {
        let prefer = DatabaseConnection(name: "a", engine: .postgres, useTLS: true)
        XCTAssertEqual(IDEDatabaseConnectionEditor.editing(prefer, password: "").tlsChoice, .prefer)
        let strict = DatabaseConnection(name: "b", engine: .postgres, useTLS: true, tlsRequired: true)
        XCTAssertEqual(IDEDatabaseConnectionEditor.editing(strict, password: "").tlsChoice, .require)
        let off = DatabaseConnection(name: "c", engine: .postgres)
        XCTAssertEqual(IDEDatabaseConnectionEditor.editing(off, password: "").tlsChoice, .off)
    }

    func testImportingAURLWithSslmodeRequireSelectsRequire() {
        let editor = IDEDatabaseConnectionEditor.makeNew()
        editor.urlText = "postgresql://app:pw@db.example.com/shop?sslmode=require"
        editor.applyURL()
        XCTAssertEqual(editor.tlsChoice, .require)
        editor.urlText = "postgresql://app:pw@db.example.com/shop"
        editor.applyURL()
        XCTAssertEqual(editor.tlsChoice, .prefer)
    }
}
