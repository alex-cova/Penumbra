import Foundation
import Testing
@testable import LocalModelStore

@Suite struct ChatTemplateTests {
    @Test func readsTheTemplateFromTokenizerConfig() {
        let config = Data(#"{"chat_template":"{% if tools %}x{% endif %}"}"#.utf8)
        #expect(ChatTemplate.extract(tokenizerConfig: config, jinja: nil) == "{% if tools %}x{% endif %}")
    }

    @Test func aStandaloneJinjaFileWinsOverTheConfig() {
        let config = Data(#"{"chat_template":"old"}"#.utf8)
        #expect(ChatTemplate.extract(tokenizerConfig: config, jinja: "new {{ tools }}") == "new {{ tools }}")
        #expect(ChatTemplate.extract(tokenizerConfig: nil, jinja: nil, templateJSON: Data(#"{"chat_template":"from json"}"#.utf8)) == "from json")
    }

    @Test func aListOfNamedTemplatesPrefersTheDefaultOne() {
        let config = Data(#"{"chat_template":[{"name":"tool_use","template":"T {{ tools }}"},{"name":"default","template":"D"}]}"#.utf8)
        #expect(ChatTemplate.extract(tokenizerConfig: config, jinja: nil) == "D")
    }

    @Test func missingOrBrokenFilesGiveNoTemplate() {
        #expect(ChatTemplate.extract(tokenizerConfig: nil, jinja: nil) == nil)
        #expect(ChatTemplate.extract(tokenizerConfig: Data("not json".utf8), jinja: "") == nil)
        #expect(ChatTemplate.extract(tokenizerConfig: Data(#"{"model_max_length":1}"#.utf8), jinja: nil) == nil)
    }

    @Test func detectsTemplatesThatTakeTools() {
        #expect(ChatTemplate.supportsTools("{%- if tools %}\n# Tools\n{% endif %}"))
        #expect(ChatTemplate.supportsTools("{{ tools | tojson }}"))
        #expect(ChatTemplate.supportsTools("{% for tool in tools %}{{ tool }}{% endfor %}"))
        #expect(!ChatTemplate.supportsTools("{% for m in messages %}{{ m.content }}{% endfor %}"))
        #expect(!ChatTemplate.supportsTools("{% set toolset = 1 %}{{ stools }}"), "a word that merely contains the letters is not the variable")
    }
}
