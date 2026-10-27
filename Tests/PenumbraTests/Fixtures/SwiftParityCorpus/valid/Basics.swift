import Foundation

struct Inventory {
    private var items: [String] = []

    var count: Int {
        return items.count
    }

    func joined(separator: String) -> String {
        var result = ""
        for item in items {
            result = result + separator + item
        }
        return result
    }

    mutating func addAll(_ more: [String]) {
        items.append(contentsOf: more)
    }

    func repeated(_ text: String, times: Int) -> String {
        var result = ""
        for _ in 0..<times {
            result = result + text
        }
        return result
    }

    func twice(_ text: String) -> String {
        return repeated(text, times: 2)
    }

    func parseOrDefault(_ text: String, fallback: Int) -> Int {
        if let value = Int(text) {
            return value
        }
        return fallback
    }

    func save(to url: URL) throws {
        try joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func trimmedFirst() -> String {
        return (items.first ?? "").trimmingCharacters(in: .whitespaces)
    }
}

func load() async -> Int {
    return 1
}

func useLoaded() async -> Int {
    return await load()
}
