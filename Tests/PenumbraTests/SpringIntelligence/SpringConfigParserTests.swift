import XCTest
@testable import SpringIntelligence

final class SpringConfigParserTests: XCTestCase {
    private func yaml(_ text: String, name: String = "application.yml") -> SpringConfigFile {
        SpringConfigParser.parse(url: URL(fileURLWithPath: "/p/\(name)"), text: text)!
    }
    private func pairs(_ f: SpringConfigFile) -> [String] { f.entries.map { "\($0.key)=\($0.value ?? "∅")" } }

    func testFileNames() {
        XCTAssertEqual(SpringConfigFileName.parse("application.properties")?.profile, nil)
        XCTAssertEqual(SpringConfigFileName.parse("application-dev.yml")?.profile, "dev")
        XCTAssertEqual(SpringConfigFileName.parse("application-prod-eu.yaml")?.profile, "prod-eu")
        XCTAssertEqual(SpringConfigFileName.parse("bootstrap.yml")?.format, .yaml)
        XCTAssertNil(SpringConfigFileName.parse("application.json"))
        XCTAssertNil(SpringConfigFileName.parse("applications.yml"))
        XCTAssertNil(SpringConfigFileName.parse("logback-spring.xml"))
    }

    func testPropertiesBasics() {
        let text = "# comment\nserver.port=8081\nspring.datasource.url : jdbc:h2:mem\n! other\nname = a \\\n   b\nflag\n"
        let f = SpringConfigParser.parse(url: URL(fileURLWithPath: "/p/application.properties"), text: text)!
        XCTAssertEqual(pairs(f), ["server.port=8081", "spring.datasource.url=jdbc:h2:mem", "name=a b", "flag="])
        let port = f.entries[0]
        XCTAssertEqual(String(text.utf8.dropFirst(port.keyRange.lowerBound).prefix(port.keyRange.count))!, "server.port")
        XCTAssertEqual(String(text.utf8.dropFirst(port.valueRange!.lowerBound).prefix(port.valueRange!.count))!, "8081")
        XCTAssertEqual(port.segments.map(\.name), ["server", "port"])
        XCTAssertEqual(port.line, 1)
    }

    func testYAMLNestingListsCommentsAndQuotes() {
        let f = yaml("""
        server:
          port: 8080   # the port
          servlet:
            context-path: "/api"
        spring:
          datasource:
            url: 'jdbc:h2:mem:test'
          profiles:
            active: dev,qa
        app:
          servers:
            - host: a.example
              port: 1
            - host: b.example
          tags:
            - one
            - two
        logging.level.root: INFO
        """)
        XCTAssertEqual(pairs(f), [
            "server.port=8080", "server.servlet.context-path=/api", "spring.datasource.url=jdbc:h2:mem:test",
            "spring.profiles.active=dev,qa", "app.servers[0].host=a.example", "app.servers[0].port=1",
            "app.servers[1].host=b.example", "app.tags[0]=one", "app.tags[1]=two", "logging.level.root=INFO"])
    }

    func testYAMLCompactListAndRanges() {
        let text = "app:\n  hosts:\n  - a\n  - b\nserver:\n  port: 80\n"
        let f = yaml(text)
        XCTAssertEqual(pairs(f), ["app.hosts[0]=a", "app.hosts[1]=b", "server.port=80"])
        let port = f.entries[2]
        XCTAssertEqual(String(text.utf8.dropFirst(port.valueRange!.lowerBound).prefix(port.valueRange!.count))!, "80")
        XCTAssertEqual(port.segments.map(\.name), ["server", "port"])
        XCTAssertEqual(port.line, 5)
    }

    func testMultiDocumentProfiles() {
        let f = yaml("""
        server.port: 1
        ---
        spring:
          config:
            activate:
              on-profile: prod
        server.port: 2
        ---
        spring.profiles: legacy
        server.port: 3
        """)
        XCTAssertEqual(f.entries.map(\.document), [0, 1, 1, 2, 2])
        XCTAssertEqual(f.documentProfiles, [1: "prod", 2: "legacy"])
        XCTAssertNil(f.profile(of: f.entries[0]))
        XCTAssertEqual(f.profile(of: f.entries[2]), "prod")
    }

    func testBlockScalarsAndFlowAreOpaque() {
        let f = yaml("""
        banner: |
          line one
          line: two
        inline: {a: 1}
        next: x
        """)
        XCTAssertEqual(pairs(f), ["banner=|", "inline={a: 1}", "next=x"])
        XCTAssertEqual(f.entries.map(\.isOpaqueValue), [true, true, false])
    }
}
