import Foundation
import Testing
@testable import AgentKit

// MARK: - Helpers

private struct FakeFetch: WebFetchClient {
    var response: WebFetchResponse
    var error: WebFetchError?

    func fetch(_ url: URL, timeout: TimeInterval) async throws -> WebFetchResponse {
        if let error { throw error }
        return response
    }
}

private func html(_ body: String, title: String = "Doc") -> Data {
    Data("<html><head><title>\(title)</title><style>p{}</style></head><body>\(body)</body></html>".utf8)
}

private func page(
    _ data: Data, type: String? = "text/html; charset=utf-8", status: Int = 200, truncated: Bool = false,
    redirectedTo: URL? = nil
) -> WebFetchResponse {
    WebFetchResponse(
        url: URL(string: "https://docs.example.com/guide")!, status: status, contentType: type, body: data,
        truncated: truncated, redirectedTo: redirectedTo)
}

private func run(_ tool: WebFetchTool, _ json: String) async throws -> String {
    let project = try TempProject()
    let context = ToolContext(workspace: project.workspace, ledger: ReadLedger(), callID: "f1")
    return try await tool.run(try ToolArguments(json: json), context: context)
}

private func fail(_ tool: WebFetchTool, _ json: String) async -> String {
    do {
        _ = try await run(tool, json)
        return "no error"
    } catch {
        return (error as? ToolError)?.message ?? "\(error)"
    }
}

// MARK: - Addresses

@Suite struct WebAddressPolicyTests {
    @Test func onlyPublicAddressesPass() {
        let allowed = ["8.8.8.8", "1.1.1.1", "172.32.0.1", "172.15.255.255", "2606:4700:4700::1111", "::ffff:8.8.8.8", "100.63.255.255"]
        let refused = [
            "127.0.0.1", "127.9.9.9", "10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254",
            "100.64.0.1", "100.127.255.255", "0.0.0.0", "224.0.0.1", "255.255.255.255", "198.18.0.1", "192.0.0.8",
            "::1", "::", "fe80::1", "fc00::1", "fd12:3456::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:10.1.2.3",
            "64:ff9b::7f00:1", "2001:db8::1", "not an address",
        ]
        for address in allowed { #expect(WebAddressPolicy.isPublic(address), "\(address) should be public") }
        for address in refused { #expect(!WebAddressPolicy.isPublic(address), "\(address) should be refused") }
    }

    private func check(_ text: String, resolves: [String] = ["93.184.216.34"]) async -> WebFetchError? {
        do {
            try await WebAddressPolicy.validate(URL(string: text)!, resolver: { _ in resolves })
            return nil
        } catch {
            return error as? WebFetchError
        }
    }

    @Test func namesAndSchemesThatCannotBePublicAreRefusedBeforeAnyLookup() async {
        for text in ["http://localhost/x", "https://app.localhost/", "https://printer.local/", "https://db.internal/", "https://nas.lan/", "https://host.home.arpa/"] {
            guard case .refused? = await check(text) else { Issue.record("\(text) should be refused"); continue }
        }
        guard case .refused? = await check("ftp://example.com/file") else { Issue.record("ftp should be refused"); return }
        guard case .refused? = await check("https://user:pass@example.com/") else { Issue.record("credentials should be refused"); return }
    }

    @Test func aNameIsCheckedByWhatItResolvesTo() async {
        #expect(await check("https://example.com/") == nil)
        guard case .refused(let reason)? = await check("https://sneaky.example.com/", resolves: ["93.184.216.34", "10.0.0.5"]) else {
            Issue.record("a name with one private address should be refused")
            return
        }
        #expect(reason.contains("10.0.0.5"))
        #expect(await check("http://[::1]:8080/", resolves: ["::1"]) != nil)
        #expect(await check("http://2130706433/", resolves: ["127.0.0.1"]) != nil)
        #expect(await check("https://nowhere.example.com/", resolves: []) == .unreachable("nowhere.example.com"))
    }
}

// MARK: - Tool

@Suite struct WebFetchToolTests {
    @Test func addressesAreNormalizedAndOddOnesRefused() throws {
        #expect(try WebFetchTool.normalize("docs.swift.org/documentation#top").absoluteString == "https://docs.swift.org/documentation")
        #expect(try WebFetchTool.normalize("  HTTP://Example.COM  ").absoluteString == "http://example.com/")
        #expect(try WebFetchTool.normalize("https://example.com:8443/a?b=1").absoluteString == "https://example.com:8443/a?b=1")
        for bad in ["", "ftp://example.com", "https://u:p@example.com", "file:///etc/passwd", "https://exa mple.com", String(repeating: "a", count: 3_000)] {
            #expect(throws: ToolError.self) { try WebFetchTool.normalize(bad) }
        }
    }

    @Test func aPageComesBackAsUntrustedMarkdownWithItsTitle() async throws {
        let tool = WebFetchTool(client: FakeFetch(response: page(html("<h1>Guide</h1><p>Read <a href=\"/more\">more</a>.</p>"))))
        let text = try await run(tool, #"{"url":"https://docs.example.com/guide"}"#)
        #expect(text.hasPrefix("<untrusted source=\"web-fetch\">"))
        #expect(text.contains("Title: Doc"))
        #expect(text.contains("# Guide"))
        #expect(text.contains("[more](https://docs.example.com/more)"))
        #expect(text.contains("HTTP 200"))
        #expect(!text.contains("p{}"), "style content is dropped")
    }

    @Test func textFormatDropsMarkup() async throws {
        let tool = WebFetchTool(client: FakeFetch(response: page(html("<h1>Guide</h1><p>Read <a href=\"/more\">more</a>.</p>"))))
        let text = try await run(tool, #"{"url":"https://docs.example.com/guide","format":"text"}"#)
        #expect(text.contains("Guide"))
        #expect(!text.contains("#"))
        #expect(!text.contains("]("))
    }

    @Test func jsonAndPlainTextPassThroughAndBinaryIsRefused() async throws {
        let json = WebFetchTool(client: FakeFetch(response: page(Data(#"{"a":1}"#.utf8), type: "application/json")))
        #expect(try await run(json, #"{"url":"https://docs.example.com/x"}"#).contains(#"{"a":1}"#))
        let image = WebFetchTool(client: FakeFetch(response: page(Data([1, 2, 3]), type: "image/png")))
        let message = await fail(image, #"{"url":"https://docs.example.com/x.png"}"#)
        #expect(message.contains("image/png"))
        let archive = WebFetchTool(client: FakeFetch(response: page(Data([1]), type: "application/zip")))
        #expect(await fail(archive, #"{"url":"https://docs.example.com/x.zip"}"#).contains("application/zip"))
    }

    @Test func errorStatusesAndClientFailuresBecomeErrorsTheModelCanActOn() async {
        let missing = WebFetchTool(client: FakeFetch(response: page(Data(), status: 404)))
        #expect(await fail(missing, #"{"url":"https://docs.example.com/x"}"#).contains("HTTP 404 (not found)"))
        let down = WebFetchTool(client: FakeFetch(response: page(Data()), error: .unreachable("docs.example.com")))
        #expect(await fail(down, #"{"url":"https://docs.example.com/x"}"#) == "Could not connect to docs.example.com.")
        let blocked = WebFetchTool(client: FakeFetch(response: page(Data()), error: .refused("localhost is a name for this machine")))
        #expect(await fail(blocked, #"{"url":"http://localhost/"}"#).contains("this machine"))
        #expect(await fail(missing, #"{"url":"ftp://x"}"#).contains("Only http and https"))
    }

    @Test func aRedirectToAnotherSiteIsReportedNotFollowed() async throws {
        let target = URL(string: "https://other.example.org/page")!
        let tool = WebFetchTool(client: FakeFetch(response: page(Data(), status: 302, redirectedTo: target)))
        let text = try await run(tool, #"{"url":"https://docs.example.com/guide"}"#)
        #expect(text.contains("redirects to https://other.example.org/page"))
        #expect(text.contains("does not follow"))
    }

    @Test func aLongPageIsCutAndSaysWhenTheBodyWasTruncated() async throws {
        let paragraphs = (0..<4_000).map { "<p>Paragraph number \($0) with some words in it.</p>" }.joined()
        let tool = WebFetchTool(client: FakeFetch(response: page(html(paragraphs), truncated: true)))
        let text = try await run(tool, #"{"url":"https://docs.example.com/long"}"#)
        #expect(text.count < WebFetchTool.maxOutputCharacters + 2_000)
        #expect(text.contains("characters omitted"))
        #expect(text.contains("Paragraph number 0 "), "the start of the page is kept")
        #expect(text.contains("cut at 2.0 MB"))
    }

    @Test func aPageWithNoTextSaysSo() async throws {
        let tool = WebFetchTool(client: FakeFetch(response: page(html("<script>app()</script>"))))
        #expect(try await run(tool, #"{"url":"https://docs.example.com/app"}"#).contains("no readable text"))
        #expect(try await run(tool, #"{"url":"https://docs.example.com/app"}"#).contains("JavaScript"))
    }

    @Test func theLegacyCharsetIsDecoded() {
        let latin = Data([0x63, 0x61, 0x66, 0xE9]) // "café" in ISO-8859-1
        #expect(WebFetchTool.decode(latin, contentType: "text/html; charset=iso-8859-1") == "café")
        #expect(WebFetchTool.decode(latin, contentType: "text/html") == "café", "invalid UTF-8 falls back to Windows-1252")
        #expect(WebFetchTool.decode(Data("é".utf8), contentType: "text/plain; charset=UTF-8") == "é")
    }
}

// MARK: - Permissions

@Suite struct WebFetchPermissionTests {
    private func call(_ url: String) -> ToolCallInfo {
        ToolCallInfo(name: "web_fetch", risk: .read, subject: .text(url), honorsDenyRules: true, asksUnlessAllowed: true)
    }

    @Test func itAsksInEveryModeUnlessARuleAllowsIt() async {
        for mode in PermissionMode.allCases {
            let verdict = await PermissionPolicy.evaluate(call("https://docs.swift.org/a"), mode: mode, rules: PermissionRules())
            #expect(verdict == .ask(notes: []), "\(mode)")
        }
        let allow = PermissionRules(allow: [PermissionRule(tool: "web_fetch", pattern: "https://docs.swift.org/*")])
        #expect(await PermissionPolicy.evaluate(call("https://docs.swift.org/a/b?c=1"), mode: .acceptEdits, rules: allow) == .allow)
        #expect(await PermissionPolicy.evaluate(call("https://evil.example.com/"), mode: .acceptEdits, rules: allow) == .ask(notes: []))
        #expect(await PermissionPolicy.evaluate(call("https://docs.swift.org.evil.com/"), mode: .acceptEdits, rules: allow) == .ask(notes: []),
                "a lookalike host does not match the rule")
    }

    @Test func denyAndAskRulesStillWin() async {
        let deny = PermissionRules(allow: [PermissionRule(tool: "web_fetch", pattern: "https://*")], deny: [PermissionRule(tool: "web_fetch", pattern: "https://bad.example.com/*")])
        if case .deny = await PermissionPolicy.evaluate(call("https://bad.example.com/x"), mode: .acceptEdits, rules: deny) {} else { Issue.record("deny should win") }
        let ask = PermissionRules(allow: [PermissionRule(tool: "web_fetch", pattern: "https://*")], ask: [PermissionRule(tool: "web_fetch", pattern: "https://docs.swift.org/*")])
        #expect(await PermissionPolicy.evaluate(call("https://docs.swift.org/x"), mode: .acceptEdits, rules: ask) == .ask(notes: []))
        #expect(await PermissionPolicy.evaluate(call("https://other.dev/x"), mode: .acceptEdits, rules: ask) == .allow)
    }

    @Test func otherReadsAreUntouched() async {
        let read = ToolCallInfo(name: "read_file", risk: .read, subject: .paths(["a"]))
        #expect(await PermissionPolicy.evaluate(read, mode: .manual, rules: PermissionRules()) == .allow)
    }

    private func session(approval: ApprovalPolicy = .askForCommands, rules: PermissionRules = PermissionRules()) throws -> (AgentSession, MockLLMClient) {
        let project = try TempProject()
        let client = MockLLMClient(turns: [
            .toolCalls((id: "f1", name: "web_fetch", arguments: #"{"url":"https://docs.example.com/guide"}"#)), .text("done"),
        ])
        let tool = WebFetchTool(client: FakeFetch(response: page(html("<p>hello page</p>"))))
        return (AgentSession(
            client: client, tools: [tool], workspace: project.workspace,
            configuration: AgentConfiguration(model: "m", approval: approval, permissions: rules)), client)
    }

    private func drive(_ session: AgentSession, decide: ((ApprovalRequest) -> ApprovalDecision)?) async -> (requests: [ApprovalRequest], output: String?) {
        var requests: [ApprovalRequest] = []
        var output: String?
        for await event in await session.send("go") {
            if case .approvalRequested(let request) = event {
                requests.append(request)
                if let decide { await session.resolveApproval(callID: request.callID, decision: decide(request)) }
            }
            if case .toolCallFinished(_, _, let result) = event { output = result.text }
        }
        return (requests, output)
    }

    @Test func theCardNamesTheAddressAndOffersAHostRule() async throws {
        let (session, _) = try session()
        let result = await drive(session) { _ in .approve }
        let request = try #require(result.requests.first)
        #expect(request.command == "https://docs.example.com/guide")
        #expect(request.suggestedRule == "web_fetch(https://docs.example.com/*)")
        #expect(request.editableArgument == "url")
        #expect(request.notes.joined().contains("docs.example.com"))
        #expect(result.output?.contains("hello page") == true)
    }

    @Test func aDenialIsReportedAsARequestNotACommand() async throws {
        let (session, _) = try session()
        let result = await drive(session) { _ in .deny(note: "not that site") }
        #expect(result.output?.contains("denied this request") == true)
        #expect(result.output?.contains("not that site") == true)
        #expect(result.output?.contains("hello page") != true)
    }

    @Test func anAllowRuleRunsItWithoutAskingAndAnEditedAddressIsUsed() async throws {
        let allow = PermissionRules(allow: [PermissionRule(tool: "web_fetch", pattern: "https://docs.example.com/*")])
        let (session, _) = try session(rules: allow)
        let result = await drive(session, decide: nil)
        #expect(result.requests.isEmpty)
        #expect(result.output?.contains("hello page") == true)

        let (edited, _) = try self.session()
        let second = await drive(edited) { _ in .approveEditing("https://docs.example.com/other") }
        #expect(second.output?.contains("hello page") == true)
    }
}

// MARK: - HTML

@Suite struct HTMLTextTests {
    private func markdown(_ body: String) -> String {
        HTMLText.convert("<html><body>\(body)</body></html>", base: URL(string: "https://site.test/docs/page"), markdown: true).text
    }

    @Test func headingsListsAndLinks() {
        let text = markdown("""
        <h1>Title</h1><p>Intro with <b>bold</b> and <em>soft</em> and <code>code()</code>.</p>
        <ul><li>one</li><li>two <a href="../other">link</a><ul><li>nested</li></ul></li></ul>
        <ol><li>first</li><li>second</li></ol><h3>Sub</h3>
        """)
        #expect(text.contains("# Title"))
        #expect(text.contains("Intro with **bold** and *soft* and `code()`."))
        #expect(text.contains("- one\n- two [link](https://site.test/other)\n  - nested"))
        #expect(text.contains("1. first\n2. second"))
        #expect(text.contains("### Sub"))
    }

    @Test func codeBlocksKeepTheirWhitespaceAndLanguage() {
        let text = markdown("<p>Run:</p><pre><code class=\"language-swift\">let a = 1\n    let b = 2\n</code></pre><p>after</p>")
        #expect(text.contains("```swift\nlet a = 1\n    let b = 2\n```"))
        #expect(text.contains("Run:"))
        #expect(text.hasSuffix("after"))
    }

    @Test func chromeAndScriptsAreDropped() {
        let text = markdown("<nav><a href=\"/x\">Menu</a></nav><script>var x = '<p>no</p>'</script><style>.a{}</style><p>Body</p><footer>Copyright</footer><!-- hidden -->")
        #expect(text == "Body")
    }

    @Test func entitiesAreDecodedAndWhitespaceCollapsed() {
        let text = markdown("<p>  Tom &amp; Jerry\n   &lt;3 &#39;quotes&#39; &#x41; &nbsp;done &unknown; </p>")
        #expect(text == "Tom & Jerry <3 'quotes' A done &unknown;")
    }

    @Test func tablesBecomeRowsAndFragmentLinksAreText() {
        let text = markdown("<table><tr><th>Name</th><th>Type</th></tr><tr><td>a</td><td>Int</td></tr></table><a href=\"#top\">top</a> <a href=\"javascript:x()\">js</a>")
        #expect(text.contains("Name | Type\na | Int"))
        #expect(text.contains("top js"))
        #expect(!text.contains("]("))
    }

    @Test func theTitleIsReadAndPlainTextHasNoMarkup() {
        let result = HTMLText.convert("<html><head><title> My  Page </title></head><body><h2>Head</h2><p>x <a href=\"/y\">y</a></p></body></html>", base: nil, markdown: false)
        #expect(result.title == "My Page")
        #expect(result.text == "Head\n\nx y")
    }

    @Test func brokenMarkupDoesNotCrashOrLoop() {
        for source in ["<", "<<>>", "<a href=\"x", "<p", "</", "<!--", "<div><span></div></span>", "<script>never closed", "<pre>open", String(repeating: "<b>", count: 10_000)] {
            _ = HTMLText.convert(source, base: nil, markdown: true)
        }
    }
}

@Suite struct WebFetchRuleTests {
    @Test func theSuggestedRuleParsesBackAndMatchesTheSiteOnly() async throws {
        let text = "web_fetch(https://docs.swift.org/*)"
        let rule = try #require(PermissionRule(parsing: text))
        #expect(rule.tool == "web_fetch")
        #expect(rule.pattern == "https://docs.swift.org/*")
        #expect(rule.description == text)

        let allow = PermissionRules(allow: [rule])
        func info(_ url: String) -> ToolCallInfo {
            ToolCallInfo(name: "web_fetch", risk: .read, subject: .text(url), honorsDenyRules: true, asksUnlessAllowed: true)
        }
        #expect(await PermissionPolicy.evaluate(info("https://docs.swift.org/documentation/swift"), mode: .manual, rules: allow) == .allow)
        #expect(await PermissionPolicy.evaluate(info("http://docs.swift.org/x"), mode: .manual, rules: allow) == .ask(notes: []))
        #expect(await PermissionPolicy.evaluate(info("https://docs.swift.org@evil.com/"), mode: .manual, rules: allow) == .ask(notes: []))
    }

    @Test func aRuleWithAPortKeepsIt() async throws {
        let rule = try #require(PermissionRule(parsing: "web_fetch(https://example.com:8443/*)"))
        let call = ToolCallInfo(name: "web_fetch", risk: .read, subject: .text("https://example.com:8443/a"), honorsDenyRules: true, asksUnlessAllowed: true)
        #expect(await PermissionPolicy.evaluate(call, mode: .manual, rules: PermissionRules(allow: [rule])) == .allow)
        let other = ToolCallInfo(name: "web_fetch", risk: .read, subject: .text("https://example.com/a"), honorsDenyRules: true, asksUnlessAllowed: true)
        #expect(await PermissionPolicy.evaluate(other, mode: .manual, rules: PermissionRules(allow: [rule])) == .ask(notes: []))
    }
}
