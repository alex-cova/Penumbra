import Foundation

/// Reads schema definition language (`type User { id: ID! }`) into a `GraphQLSchema`. Lenient: a
/// definition it cannot read is skipped up to the next one, so a schema with an odd directive still
/// completes. `extend` definitions are merged into the type they extend, whichever comes first.
enum GraphQLSDLParser {
    static func parse(_ text: String) -> GraphQLSchema {
        var parser = Parser(text: text)
        return parser.parseDocument()
    }

    private struct Parser {
        let units: [UInt16]
        let tokens: [GraphQLToken]
        var position = 0
        var schema = GraphQLSchema()

        init(text: String) {
            units = Array(text.utf16)
            tokens = GraphQLLexer.lex(text).tokens
        }

        static let definitionKeywords: Set<String> = [
            "schema", "scalar", "type", "interface", "union", "enum", "input", "directive", "extend"
        ]

        var current: GraphQLToken? {
            position < tokens.count ? tokens[position] : nil
        }

        mutating func parseDocument() -> GraphQLSchema {
            while let token = current {
                var description: String?
                var head = token
                if token.kind == .string || token.kind == .blockString {
                    description = token.text
                    position += 1
                    guard let next = current else {
                        break
                    }
                    head = next
                }
                guard head.kind == .name, Self.definitionKeywords.contains(head.text) else {
                    skipToNextDefinition()
                    continue
                }
                position += 1
                var keyword = head.text
                if keyword == "extend" {
                    guard let next = current, next.kind == .name else {
                        continue
                    }
                    keyword = next.text
                    position += 1
                }
                parseDefinition(keyword: keyword, description: description)
            }
            schema.finish()
            return schema
        }

        /// A new definition starts at a keyword (or a description) outside braces. Parentheses and
        /// brackets are not counted: an unclosed one in the unreadable part must not hide what follows.
        mutating func skipToNextDefinition() {
            var depth = 0
            // Always moves: the token it was called at is the one that could not be read.
            position += 1
            while let token = current {
                if token.kind == .punctuator {
                    if token.text == "{" {
                        depth += 1
                    } else if token.text == "}" {
                        depth = max(0, depth - 1)
                    }
                } else if depth == 0, token.kind == .string || token.kind == .blockString {
                    return
                } else if depth == 0, token.kind == .name, Self.definitionKeywords.contains(token.text) {
                    return
                }
                position += 1
            }
        }

        mutating func parseDefinition(keyword: String, description: String?) {
            switch keyword {
            case "schema":
                skipDirectives()
                parseSchemaBody()
            case "scalar":
                guard let name = takeName() else { return }
                skipDirectives()
                merge(GraphQLNamedType(name: name, kind: .scalar, description: description))
            case "type", "interface":
                guard let name = takeName() else { return }
                var type = GraphQLNamedType(name: name, kind: keyword == "type" ? .object : .interface, description: description)
                type.interfaces = parseImplements()
                skipDirectives()
                type.fields = parseFields()
                merge(type)
            case "union":
                guard let name = takeName() else { return }
                skipDirectives()
                var type = GraphQLNamedType(name: name, kind: .union, description: description)
                if current?.isPunctuator("=") == true {
                    position += 1
                    if current?.isPunctuator("|") == true {
                        position += 1
                    }
                    while let member = takeName() {
                        type.possibleTypes.append(member)
                        guard current?.isPunctuator("|") == true else { break }
                        position += 1
                    }
                }
                merge(type)
            case "enum":
                guard let name = takeName() else { return }
                skipDirectives()
                var type = GraphQLNamedType(name: name, kind: .enumeration, description: description)
                type.enumValues = parseEnumValues()
                merge(type)
            case "input":
                guard let name = takeName() else { return }
                skipDirectives()
                var type = GraphQLNamedType(name: name, kind: .inputObject, description: description)
                if current?.isPunctuator("{") == true {
                    position += 1
                    type.inputFields = parseInputValues(closing: "}")
                }
                merge(type)
            case "directive":
                parseDirectiveDefinition(description: description)
            default:
                skipToNextDefinition()
            }
        }

        mutating func parseSchemaBody() {
            guard current?.isPunctuator("{") == true else { return }
            position += 1
            while let token = current, !token.isPunctuator("}") {
                guard token.kind == .name else {
                    position += 1
                    continue
                }
                let operation = token.text
                position += 1
                guard current?.isPunctuator(":") == true else { continue }
                position += 1
                guard let name = takeName() else { continue }
                switch operation {
                case "query": schema.queryType = name
                case "mutation": schema.mutationType = name
                case "subscription": schema.subscriptionType = name
                default: break
                }
            }
            if current?.isPunctuator("}") == true {
                position += 1
            }
        }

        mutating func parseImplements() -> [String] {
            guard current?.isName("implements") == true else { return [] }
            position += 1
            if current?.isPunctuator("&") == true {
                position += 1
            }
            var names: [String] = []
            while let name = takeName() {
                names.append(name)
                guard current?.isPunctuator("&") == true else { break }
                position += 1
            }
            return names
        }

        mutating func parseFields() -> [GraphQLField] {
            guard current?.isPunctuator("{") == true else { return [] }
            position += 1
            var fields: [GraphQLField] = []
            while let token = current, !token.isPunctuator("}") {
                var description: String?
                if token.kind == .string || token.kind == .blockString {
                    description = token.text
                    position += 1
                }
                guard let name = takeName() else {
                    position += 1
                    continue
                }
                var arguments: [GraphQLArgument] = []
                if current?.isPunctuator("(") == true {
                    position += 1
                    arguments = parseInputValues(closing: ")")
                }
                guard current?.isPunctuator(":") == true else {
                    continue
                }
                position += 1
                guard let type = parseType() else { continue }
                let deprecation = parseDirectivesReadingDeprecation()
                fields.append(GraphQLField(
                    name: name, arguments: arguments, type: type, description: description, deprecationReason: deprecation
                ))
            }
            if current?.isPunctuator("}") == true {
                position += 1
            }
            return fields
        }

        mutating func parseInputValues(closing: Character) -> [GraphQLArgument] {
            var values: [GraphQLArgument] = []
            while let token = current, !token.isPunctuator(closing) {
                var description: String?
                if token.kind == .string || token.kind == .blockString {
                    description = token.text
                    position += 1
                }
                guard let name = takeName() else {
                    position += 1
                    continue
                }
                guard current?.isPunctuator(":") == true else { continue }
                position += 1
                guard let type = parseType() else { continue }
                var defaultValue: String?
                if current?.isPunctuator("=") == true {
                    position += 1
                    defaultValue = parseValueText()
                }
                skipDirectives()
                values.append(GraphQLArgument(name: name, type: type, description: description, defaultValue: defaultValue))
            }
            if current?.isPunctuator(closing) == true {
                position += 1
            }
            return values
        }

        mutating func parseEnumValues() -> [GraphQLEnumValue] {
            guard current?.isPunctuator("{") == true else { return [] }
            position += 1
            var values: [GraphQLEnumValue] = []
            while let token = current, !token.isPunctuator("}") {
                var description: String?
                if token.kind == .string || token.kind == .blockString {
                    description = token.text
                    position += 1
                }
                guard let name = takeName() else {
                    position += 1
                    continue
                }
                let deprecation = parseDirectivesReadingDeprecation()
                values.append(GraphQLEnumValue(name: name, description: description, deprecationReason: deprecation))
            }
            if current?.isPunctuator("}") == true {
                position += 1
            }
            return values
        }

        mutating func parseDirectiveDefinition(description: String?) {
            guard current?.isPunctuator("@") == true else {
                skipToNextDefinition()
                return
            }
            position += 1
            guard let name = takeName() else { return }
            var arguments: [GraphQLArgument] = []
            if current?.isPunctuator("(") == true {
                position += 1
                arguments = parseInputValues(closing: ")")
            }
            if current?.isName("repeatable") == true {
                position += 1
            }
            var locations: [String] = []
            if current?.isName("on") == true {
                position += 1
                if current?.isPunctuator("|") == true {
                    position += 1
                }
                while let location = takeName() {
                    locations.append(location)
                    guard current?.isPunctuator("|") == true else { break }
                    position += 1
                }
            }
            schema.directives.removeAll { $0.name == name }
            schema.directives.append(GraphQLDirectiveDefinition(
                name: name, description: description, arguments: arguments, locations: locations
            ))
        }

        /// `Name`, `[Type]`, either followed by `!`.
        mutating func parseType() -> GraphQLTypeRef? {
            guard let token = current else { return nil }
            var display: String
            var named: String
            if token.isPunctuator("[") {
                position += 1
                guard let inner = parseType() else { return nil }
                if current?.isPunctuator("]") == true {
                    position += 1
                }
                display = "[" + inner.display + "]"
                named = inner.name
            } else if token.kind == .name {
                position += 1
                display = token.text
                named = token.text
            } else {
                return nil
            }
            var required = false
            if current?.isPunctuator("!") == true {
                position += 1
                display += "!"
                required = true
            }
            return GraphQLTypeRef(name: named, display: display, isRequired: required)
        }

        /// The source text of one value: a scalar, a name, a list or an object.
        mutating func parseValueText() -> String? {
            guard let first = current else { return nil }
            var depth = 0
            var last = first
            repeat {
                guard let token = current else { break }
                last = token
                position += 1
                if token.kind == .punctuator, token.text == "[" || token.text == "{" {
                    depth += 1
                } else if token.kind == .punctuator, token.text == "]" || token.text == "}" {
                    depth -= 1
                }
            } while depth > 0
            let range = first.range.lowerBound..<last.range.upperBound
            return String(decoding: units[range], as: UTF16.self)
        }

        mutating func skipDirectives() {
            _ = parseDirectivesReadingDeprecation()
        }

        /// `@deprecated(reason: "x")` gives its reason (`""` when it has none); other directives are skipped.
        mutating func parseDirectivesReadingDeprecation() -> String? {
            var deprecation: String?
            while current?.isPunctuator("@") == true {
                position += 1
                guard let name = takeName() else { break }
                var reason = ""
                if current?.isPunctuator("(") == true {
                    var depth = 0
                    repeat {
                        guard let token = current else { break }
                        position += 1
                        if token.isPunctuator("(") {
                            depth += 1
                        } else if token.isPunctuator(")") {
                            depth -= 1
                        } else if name == "deprecated", token.kind == .string || token.kind == .blockString {
                            reason = token.text
                        }
                    } while depth > 0
                }
                if name == "deprecated" {
                    deprecation = reason
                }
            }
            return deprecation
        }

        mutating func takeName() -> String? {
            guard let token = current, token.kind == .name else { return nil }
            position += 1
            return token.text
        }

        mutating func merge(_ type: GraphQLNamedType) {
            guard var existing = schema.types[type.name] else {
                schema.types[type.name] = type
                return
            }
            if existing.description == nil {
                existing.description = type.description
            }
            for field in type.fields where !existing.fields.contains(where: { $0.name == field.name }) {
                existing.fields.append(field)
            }
            for field in type.inputFields where !existing.inputFields.contains(where: { $0.name == field.name }) {
                existing.inputFields.append(field)
            }
            for value in type.enumValues where !existing.enumValues.contains(where: { $0.name == value.name }) {
                existing.enumValues.append(value)
            }
            for member in type.possibleTypes where !existing.possibleTypes.contains(member) {
                existing.possibleTypes.append(member)
            }
            for interface in type.interfaces where !existing.interfaces.contains(interface) {
                existing.interfaces.append(interface)
            }
            schema.types[type.name] = existing
        }
    }
}
