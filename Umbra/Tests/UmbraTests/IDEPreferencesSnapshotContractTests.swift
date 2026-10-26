import XCTest
@testable import Umbra

/// The preferences snapshot is stored in `app.json` and read back by every later version. These tests
/// pin what an older file must still decode to, so an added setting cannot silently drop users' choices.
@MainActor
final class IDEPreferencesSnapshotContractTests: XCTestCase {
    /// Keys a stored snapshot must have to decode at all. Settings added later decode with
    /// `decodeIfPresent`, so a file written before them still loads. Never add to this list: make the
    /// new key optional in `IDEPreferencesSnapshot.init(from:)` with a default instead.
    private static let requiredKeys: Set<String> = [
        "fontSize", "tabWidth", "useSpacesForTab", "wrapLines", "showLineNumbers",
        "isLineFoldingEnabled", "showMinimap", "isMetalRenderingEnabled", "keymapPreset",
    ]

    private func encodedObject() throws -> [String: Any] {
        let data = try JSONEncoder().encode(IDEPreferences.shared.snapshot())
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decodes(_ object: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        return (try? JSONDecoder().decode(IDEPreferencesSnapshot.self, from: data)) != nil
    }

    func testASnapshotSurvivesEncodingAndDecoding() throws {
        let snapshot = IDEPreferences.shared.snapshot()
        let decoded = try JSONDecoder().decode(IDEPreferencesSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
    }

    func testOnlyTheOriginalSettingsAreRequiredToDecode() throws {
        let object = try encodedObject()
        let required = Set(object.keys.filter { key in
            var without = object
            without.removeValue(forKey: key)
            return !decodes(without)
        })
        XCTAssertEqual(
            required, Self.requiredKeys,
            "a newly required key makes every older app.json fail to decode; use decodeIfPresent with a default")
    }

    func testAFileWithOnlyTheRequiredSettingsStillDecodes() throws {
        let object = try encodedObject()
        let minimal = object.filter { Self.requiredKeys.contains($0.key) }
        XCTAssertTrue(decodes(minimal), "every setting added since must be optional")
    }
}
