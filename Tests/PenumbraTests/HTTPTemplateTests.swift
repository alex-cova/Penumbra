import Foundation
import XCTest
@testable import Umbra

final class HTTPTemplateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testFileVariableIsTheNameUsedInBraces() throws {
        let text = """
        @jwt = headerValue
        GET https://example.com
        Authorization: Bearer {{jwt}}

        """
        let request = try parse(text)
        XCTAssertEqual(request.headers["Authorization"], "Bearer headerValue")
        XCTAssertThrowsError(try parse("GET https://example.com/{{headerValue}}\n")) { error in
            XCTAssertEqual(error as? HTTPRequestParserError, .unknownVariable("headerValue"))
        }
    }

    func testLaterFileVariableWinsAndOverridesAGlobal() throws {
        let text = """
        @jwt = first
        @jwt = second
        GET https://example.com
        Authorization: Bearer {{jwt}}

        """
        let request = try parse(text, globals: ["jwt": "from-global"])
        XCTAssertEqual(request.headers["Authorization"], "Bearer second")
    }

    func testQuotesStayInTheVariableValue() throws {
        let text = """
        @token = "abc"
        GET https://example.com
        Authorization: Bearer {{token}}

        """
        XCTAssertEqual(try parse(text).headers["Authorization"], "Bearer \"abc\"")
    }

    func testNestedVariablesAndEnvironmentNames() throws {
        let text = """
        @domain = example.com
        @host = https://{{domain}}
        @show_env = 1
        GET {{host}}/get?show_env={{show_env}}

        """
        XCTAssertEqual(try parse(text).url.absoluteString, "https://example.com/get?show_env=1")
    }

    func testGlobalFillsABearerToken() throws {
        let text = """
        GET https://example.com/headers
        Authorization: Bearer {{auth_token}}

        """
        let request = try parse(text, globals: ["auth_token": "my-secret-token"])
        XCTAssertEqual(request.headers["Authorization"], "Bearer my-secret-token")
    }

    func testCyclicVariableIsReported() {
        let text = """
        @a = {{b}}
        @b = {{a}}
        GET {{a}}

        """
        XCTAssertThrowsError(try parse(text)) { error in
            XCTAssertEqual(error as? HTTPRequestParserError, .cyclicVariable("a"))
        }
    }

    func testDynamicFunctionsSubstitutePerOccurrence() throws {
        let text = """
        POST https://example.com/echo
        Content-Type: application/json

        {
          "id": {{$random.uuid}},
          "price": {{$random.integer()}},
          "ts": {{$timestamp}},
          "value": "content"
        }
        """
        let random = ScriptedHTTPRandom(uuids: ["11111111-1111-1111-1111-111111111111"], integers: [7])
        let request = try parse(text, now: now, random: random)
        let body = """
        {
          "id": 11111111-1111-1111-1111-111111111111,
          "price": 7,
          "ts": 1700000000,
          "value": "content"
        }
        """
        XCTAssertEqual(String(data: try XCTUnwrap(request.body), encoding: .utf8), body)
        XCTAssertEqual(request.headers["Content-Length"], String(body.utf8.count))
        XCTAssertEqual(random.integerRanges.map { [$0.0, $0.1] }, [[0, 1000]])
        XCTAssertFalse(text.hasSuffix("\n"))
        XCTAssertEqual(HTTPRequestParser.requestLocations(in: text).map(\.startLine), [1])
    }

    func testTwoUUIDsDifferAndIntegerBoundsSwap() throws {
        let random = ScriptedHTTPRandom(uuids: ["aaa", "bbb"], integers: [4])
        let text = """
        GET https://example.com/?a={{$random.uuid}}&b={{$random.uuid}}&n={{$random.integer(8, 3)}}&m={{$randomInt}}

        """
        let request = try parse(text, random: random)
        XCTAssertEqual(request.url.absoluteString, "https://example.com/?a=aaa&b=bbb&n=4&m=4")
        XCTAssertEqual(random.integerRanges.map { [$0.0, $0.1] }, [[3, 8], [0, 1000]])
    }

    func testISOTimestampEmailAndAliases() throws {
        XCTAssertEqual(HTTPSyntax.isoTimestamp(from: now), "2023-11-14T22:13:20.000Z")
        let random = ScriptedHTTPRandom(letters: "abcdefghij")
        let text = """
        GET https://example.com/?t={{$isoTimestamp}}&e={{$random.email}}&u={{$uuid}}

        """
        let request = try parse(text, now: now, random: random)
        XCTAssertEqual(
            request.url.absoluteString,
            "https://example.com/?t=2023-11-14T22:13:20.000Z&e=abcdefgh@example.com&u=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
    }

    func testBasicAuthorizationIsEncodedAfterSubstitution() throws {
        let literal = """
        GET https://example.com/basic
        Authorization: Basic user passwd

        """
        let encoded = "Basic " + Data("user:passwd".utf8).base64EncodedString()
        XCTAssertEqual(try parse(literal).headers["Authorization"], encoded)

        let variables = """
        @username = user
        @password = hello world
        GET https://example.com/basic
        Authorization: Basic {{username}} {{password}}

        """
        let withSpace = "Basic " + Data("user:hello world".utf8).base64EncodedString()
        XCTAssertEqual(try parse(variables).headers["Authorization"], withSpace)

        let already = """
        GET https://example.com/basic
        Authorization: Basic dXNlcjpwYXNzd2Q=

        """
        XCTAssertEqual(try parse(already).headers["Authorization"], "Basic dXNlcjpwYXNzd2Q=")
    }

    func testDigestCredentialsAreRemovedUntilTheChallenge() throws {
        let text = """
        @username = Mufasa
        @password = Circle Of Life
        GET https://example.com/dir/index.html
        Authorization: Digest {{username}} {{password}}

        """
        let request = try parse(text)
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertEqual(request.digest, HTTPDigestLogin(username: "Mufasa", password: "Circle Of Life"))

        let precomputed = """
        GET https://example.com/dir/index.html
        Authorization: Digest username="Mufasa", realm="test"

        """
        let kept = try parse(precomputed)
        XCTAssertNil(kept.digest)
        XCTAssertEqual(kept.headers["Authorization"], #"Digest username="Mufasa", realm="test""#)
    }

    func testDigestResponseMatchesTheRFC2617Vector() throws {
        let challenge = try XCTUnwrap(HTTPDigest.parse(
            #"Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#
        ))
        let header = try XCTUnwrap(HTTPDigest.authorization(
            username: "Mufasa",
            password: "Circle Of Life",
            method: "GET",
            uri: "/dir/index.html",
            challenge: challenge,
            nc: "00000001",
            cnonce: "0a4f113b"
        ))
        XCTAssertTrue(header.contains(#"response="6629fae49393a05397450978507c4ef1""#), header)
        XCTAssertTrue(header.contains("qop=auth"), header)
        XCTAssertTrue(header.contains("algorithm=MD5"), header)
        XCTAssertTrue(header.contains(#"opaque="5ccc069c403ebaf9f0171e9517f40e41""#), header)
    }

    func testFlagsApplyToTheNextRequestOnly() throws {
        let text = """
        # @no-redirect
        # @no-cookie-jar
        GET https://example.com/a

        ###
        GET https://example.com/b

        """
        let locations = HTTPRequestParser.requestLocations(in: text)
        XCTAssertEqual(locations.map(\.startLine), [3, 6])
        let first = try parse(text, caret: locations[0].utf16Range.lowerBound)
        XCTAssertFalse(first.options.followRedirects)
        XCTAssertFalse(first.options.useCookieJar)
        XCTAssertTrue(first.options.autoEncodeURL)
        let second = try parse(text, caret: locations[1].utf16Range.lowerBound)
        XCTAssertEqual(second.options, HTTPRequestOptions())
    }

    func testQueryContinuationEncodesSpacesAndRawQueryStays() throws {
        let joined = """
        GET https://example.com/get
            ?generated-in=IntelliJ IDEA

        """
        XCTAssertEqual(
            try parse(joined).url.absoluteString,
            "https://example.com/get?generated-in=IntelliJ%20IDEA"
        )

        let raw = """
        # @no-auto-encoding
        GET https://example.com/anything?value=@+$!

        """
        let request = try parse(raw)
        XCTAssertFalse(request.options.autoEncodeURL)
        XCTAssertEqual(request.url.absoluteString, "https://example.com/anything?value=@+$!")
    }

    func testHTTPVersionIsNotPartOfTheURL() throws {
        let request = try parse("GET https://example.com/get HTTP/2\n")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "https://example.com/get")
    }

    func testCookieHeaderIsSentAsWritten() throws {
        let text = """
        GET https://example.com/cookies
        Cookie: theme=darcula; last_searched_location=IJburg

        """
        XCTAssertEqual(
            try parse(text).headers["Cookie"],
            "theme=darcula; last_searched_location=IJburg"
        )
    }

    func testResponseHandlerBindsTheNextRequestAndDoesNotLogTheValue() throws {
        let text = """
        POST https://example.com/body-echo
        Content-Type: application/json

        {
          "token": "my-secret-token"
        }

        > {% client.global.set("auth_token", response.body.token); %}

        ###
        GET https://example.com/headers
        Authorization: Bearer {{auth_token}}

        """
        let locations = HTTPRequestParser.requestLocations(in: text)
        XCTAssertEqual(locations.count, 2)
        let post = try parse(text, caret: locations[0].utf16Range.lowerBound)
        XCTAssertEqual(post.bindings, [HTTPResponseBinding(name: "auth_token", jsonPath: "token")])
        XCTAssertEqual(
            String(data: try XCTUnwrap(post.body), encoding: .utf8),
            "{\n  \"token\": \"my-secret-token\"\n}"
        )
        let get = try parse(text, caret: locations[1].utf16Range.lowerBound, globals: ["auth_token": "saved"])
        XCTAssertTrue(get.bindings.isEmpty)
        XCTAssertEqual(get.headers["Authorization"], "Bearer saved")

        let store = HTTPGlobalStore()
        let outcome = HTTPResponseCapture.apply(
            bindings: post.bindings,
            data: Data("{\"token\":\"my-secret-token\",\"ok\":true,\"n\":3}".utf8),
            store: store
        )
        XCTAssertEqual(outcome.notes, ["Saved auth_token"])
        XCTAssertFalse(outcome.notes.joined().contains("my-secret-token"))
        XCTAssertEqual(store.snapshot()["auth_token"], "my-secret-token")
        XCTAssertEqual(
            HTTPResponseValues.string(in: Data("{\"ok\":true,\"n\":3}".utf8), path: "ok"),
            "true"
        )
        XCTAssertEqual(
            HTTPResponseValues.string(in: Data("{\"ok\":true,\"n\":3}".utf8), path: "n"),
            "3"
        )
        XCTAssertNil(HTTPResponseValues.string(in: Data("{\"ok\":true}".utf8), path: "missing"))
    }

    func testResponseFileIsNotTheBodyAndCannotEscape() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = directory.appendingPathComponent("history", isDirectory: true)
        let requestFile = directory.appendingPathComponent("request.http")
        let saved = """
        GET https://example.com/get

        //TIP note
        >> {{$historyFolder}}/my-response.json

        """
        let request = try parse(saved, fileURL: requestFile, historyFolder: history)
        XCTAssertNil(request.body)
        XCTAssertEqual(request.output?.overwrite, false)
        XCTAssertEqual(
            request.output?.url.standardizedFileURL.path,
            history.appendingPathComponent("my-response.json").standardizedFileURL.path
        )

        let forced = """
        GET https://example.com/get

        >>! {{$historyFolder}}/my-forced-response.json

        """
        XCTAssertEqual(try parse(forced, fileURL: requestFile, historyFolder: history).output?.overwrite, true)

        XCTAssertThrowsError(try parse("GET https://example.com/get\n\n>> ../secret.txt\n", fileURL: requestFile, historyFolder: history)) { error in
            guard case HTTPRequestParserError.responsePathNotAllowed = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
        // One ".." from the history folder lands next to the request file, which is an allowed root.
        let beside = try parse(
            "GET https://example.com/get\n\n>> {{$historyFolder}}/../beside.json\n",
            fileURL: requestFile,
            historyFolder: history
        )
        XCTAssertEqual(
            beside.output?.url.path,
            directory.appendingPathComponent("beside.json").path
        )
        // Two ".." leaves both the request folder and the history folder.
        XCTAssertThrowsError(try parse(
            "GET https://example.com/get\n\n>> {{$historyFolder}}/../../secret.txt\n",
            fileURL: requestFile,
            historyFolder: history
        )) { error in
            guard case HTTPRequestParserError.responsePathNotAllowed = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
        // The history folder may not exist yet. ".." still has to collapse, or the
        // unstandardized path "/history/../secret" matches the history prefix.
        let missingHistory = directory.appendingPathComponent("missing-history", isDirectory: true)
        XCTAssertThrowsError(try parse(
            "GET https://example.com/proj/request.http\n\n>> {{$historyFolder}}/../../secret.txt\n",
            fileURL: directory.appendingPathComponent("proj").appendingPathComponent("request.http"),
            historyFolder: missingHistory
        )) { error in
            guard case HTTPRequestParserError.responsePathNotAllowed = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
        let nestedFile = directory.appendingPathComponent("proj").appendingPathComponent("request.http")
        XCTAssertThrowsError(try parse(
            "GET https://example.com/get\n\n>> {{$historyFolder}}-evil/secret.txt\n",
            fileURL: nestedFile,
            historyFolder: history
        )) { error in
            guard case HTTPRequestParserError.responsePathNotAllowed = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
        XCTAssertFalse(HTTPSyntax.contains(
            URL(fileURLWithPath: "/tmp/history-evil/secret.txt"),
            in: URL(fileURLWithPath: "/tmp/history")
        ))
    }

    func testRawBodyDropsFileCommentsAndGraphQLKeepsHashComments() throws {
        let raw = """
        POST https://example.com/echo
        Content-Type: text/plain

        note
        // skipped
        kept

        """
        XCTAssertEqual(String(data: try XCTUnwrap(try parse(raw).body), encoding: .utf8), "note\nkept")

        let graphql = """
        POST https://example.com/graphql

        query {
          # keep
          user
        }

        """
        let graphqlBody = try XCTUnwrap(try parse(graphql).body)
        XCTAssertTrue(String(decoding: graphqlBody, as: UTF8.self).contains("# keep"))
    }

    func testGraphQLRequestIsPostedWithGraphQLContentType() throws {
        let request = try parse("""
        GRAPHQL https://api.example.com/shop/v1
        Authorization: token
        Content-Length: 76
        X-Branch-id: 19838

        query {
          farmacopeaFractions(codes: ["7502224228565"]) {
            fraction
          }
        }

        """)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Content-Type"], "application/graphql")
        XCTAssertEqual(request.headers["X-Branch-id"], "19838")
        XCTAssertEqual(request.headers["Content-Length"], String(try XCTUnwrap(request.body).count))

        let typed = try parse("""
        GRAPHQL https://api.example.com/shop/v1
        content-type: application/json

        { me { id } }

        """)
        XCTAssertEqual(typed.method, "POST")
        XCTAssertEqual(typed.headers["content-type"], "application/json")
        XCTAssertNil(typed.headers["Content-Type"])
    }

    func testResponseFileSuffixAndOverwrite() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("my-response.json")
        try Data("old".utf8).write(to: url)
        let kept = HTTPResponseFiles.destination(for: HTTPResponseOutput(url: url, overwrite: false))
        XCTAssertEqual(kept.lastPathComponent, "my-response-1.json")
        let forced = HTTPResponseFiles.destination(for: HTTPResponseOutput(url: url, overwrite: true))
        XCTAssertEqual(forced, url)
        let written = try HTTPResponseFiles.write(Data("new".utf8), to: HTTPResponseOutput(url: url, overwrite: true))
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), "new")
    }

    func testNonTextResponsesAreSavedAsFiles() throws {
        let url = try XCTUnwrap(URL(string: "https://api.example.com/report/excel"))
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        let binary = Data([0x50, 0x4B, 0x03, 0x04, 0xFF, 0xFE])

        let sheet = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": xlsx,
            "Content-Disposition": "attachment; filename=\"reporte-2026-10-06T05:35:45.161.xlsx\"",
        ]))
        let output = try XCTUnwrap(HTTPResponseDownload.output(for: sheet, data: binary, requestURL: url, folder: folder))
        XCTAssertEqual(output.url.lastPathComponent, "reporte-2026-10-06T05-35-45.161.xlsx")
        XCTAssertEqual(output.url.deletingLastPathComponent().path, folder.path)
        XCTAssertFalse(output.overwrite)

        let json = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "application/problem+json; charset=utf-8",
        ]))
        XCTAssertNil(HTTPResponseDownload.output(for: json, data: Data("{}".utf8), requestURL: url, folder: folder))

        let untyped = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]))
        XCTAssertNil(HTTPResponseDownload.output(for: untyped, data: Data("plain".utf8), requestURL: url, folder: folder))
        XCTAssertNotNil(HTTPResponseDownload.output(for: untyped, data: binary, requestURL: url, folder: folder))
    }

    func testDownloadFileNames() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/files/"))
        XCTAssertEqual(
            HTTPResponseDownload.fileName(
                contentDisposition: "attachment; filename=\"a.pdf\"; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf",
                contentType: "application/pdf",
                requestURL: url
            ),
            "résumé.pdf"
        )
        XCTAssertEqual(
            HTTPResponseDownload.fileName(
                contentDisposition: "attachment; filename=\"../../etc/.passwd\"",
                contentType: nil,
                requestURL: url
            ),
            "passwd.bin"
        )
        XCTAssertEqual(
            HTTPResponseDownload.fileName(contentDisposition: nil, contentType: "image/png", requestURL: url),
            "files.png"
        )
        XCTAssertEqual(
            HTTPResponseDownload.fileName(contentDisposition: nil, contentType: "application/octet-stream", requestURL: URL(string: "https://example.com/")!),
            "response.bin"
        )
    }

    func testDirectivesAreNotRequestLines() {
        let text = """
        @jwt = headerValue

        # @no-redirect
        GET https://example.com/one

        > {% client.global.set("auth_token", response.body.token); %}

        ###
        POST https://example.com/two

        >> out.json
        """
        XCTAssertEqual(HTTPRequestParser.requestLocations(in: text).map(\.startLine), [4, 9])
    }

    private func parse(
        _ text: String,
        caret: Int = 0,
        fileURL: URL? = nil,
        globals: [String: String] = [:],
        now: Date? = nil,
        random: any HTTPRandomSource = ScriptedHTTPRandom(),
        historyFolder: URL? = nil
    ) throws -> HTTPPreparedRequest {
        try HTTPRequestParser.parse(
            text: text,
            caretUTF16Offset: caret,
            fileURL: fileURL,
            globals: globals,
            now: now ?? self.now,
            random: random,
            historyFolder: historyFolder
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class ScriptedHTTPRandom: HTTPRandomSource, @unchecked Sendable {
    var uuids: [String]
    var integers: [Int]
    var letters: String
    private var uuidIndex = 0
    private var integerIndex = 0
    private(set) var integerRanges: [(Int, Int)] = []
    private(set) var alphanumericCounts: [Int] = []

    init(
        uuids: [String] = ["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"],
        integers: [Int] = [7],
        letters: String = "abcdefghij"
    ) {
        self.uuids = uuids
        self.integers = integers
        self.letters = letters
    }

    func uuid() -> String {
        guard !uuids.isEmpty else { return "" }
        let value = uuids[min(uuidIndex, uuids.count - 1)]
        if uuidIndex + 1 < uuids.count { uuidIndex += 1 }
        return value
    }

    func integer(from lower: Int, to upper: Int) -> Int {
        integerRanges.append((lower, upper))
        guard !integers.isEmpty else { return 0 }
        let value = integers[min(integerIndex, integers.count - 1)]
        if integerIndex + 1 < integers.count { integerIndex += 1 }
        return value
    }

    func float(from lower: Double, to upper: Double) -> Double { min(lower, upper) }

    func alphabetic(count: Int) -> String { take(count) }
    func alphanumeric(count: Int) -> String {
        alphanumericCounts.append(count)
        return take(count)
    }
    func hexadecimal(count: Int) -> String { take(count) }

    private func take(_ count: Int) -> String {
        guard count > 0, !letters.isEmpty else { return "" }
        var result = ""
        while result.count < count { result += letters }
        return String(result.prefix(count))
    }
}
