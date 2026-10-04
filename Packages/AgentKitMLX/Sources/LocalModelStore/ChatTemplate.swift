import Foundation

/// Reads a model's chat template from the files a repository ships, and judges whether it takes
/// tools. The agent offers only models that do: a template that ignores `tools` cannot be asked to
/// call a function, whatever the weights could learn.
public enum ChatTemplate {
    /// The template text from `tokenizer_config.json` (a string, or a list of named templates) or,
    /// failing that, the standalone `chat_template.jinja` / `chat_template.json`.
    public static func extract(tokenizerConfig: Data?, jinja: String?, templateJSON: Data? = nil) -> String? {
        if let jinja, !jinja.isEmpty { return jinja }
        for data in [templateJSON, tokenizerConfig].compactMap({ $0 }) {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let text = object["chat_template"] as? String, !text.isEmpty { return text }
            // Some repositories keep several templates: the one named "default" is the plain chat one,
            // and "tool_use" (Command-R style) is the one that takes tools.
            if let list = object["chat_template"] as? [[String: Any]] {
                let named = Dictionary(list.compactMap { entry -> (String, String)? in
                    guard let name = entry["name"] as? String, let template = entry["template"] as? String else { return nil }
                    return (name, template)
                }, uniquingKeysWith: { first, _ in first })
                if let template = named["default"] ?? named.values.first { return template }
            }
        }
        return nil
    }

    /// Whether the template references `tools` as a variable (`{% if tools %}`, `tools | tojson`, …).
    public static func supportsTools(_ template: String) -> Bool {
        template.range(of: #"\btools\b"#, options: .regularExpression) != nil
    }

    /// Fetches the small files that carry the template. `nil` when the repository has none, or the
    /// Hub could not be reached; callers treat that as "unknown", not "no".
    public static func fetch(
        id: String, revision: String = "main", token: String? = nil,
        endpoint: URL = HuggingFaceSearchEngine.endpoint, session: URLSession = .shared
    ) async -> String? {
        guard LocalModelPaths.isValidRepositoryID(id) else { return nil }
        func get(_ file: String) async -> Data? {
            var request = URLRequest(url: LocalModelDownloader.resolveURL(endpoint: endpoint, id: id, revision: revision, path: file), timeoutInterval: 20)
            if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200
            else { return nil }
            return data
        }
        async let config = get("tokenizer_config.json")
        async let jinja = get("chat_template.jinja")
        async let json = get("chat_template.json")
        return extract(
            tokenizerConfig: await config, jinja: await jinja.flatMap { String(data: $0, encoding: .utf8) }, templateJSON: await json)
    }
}
