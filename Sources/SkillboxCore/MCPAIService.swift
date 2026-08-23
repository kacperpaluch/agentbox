import Foundation

extension SkillboxService {
    public func saveMCPAISettings(_ settings: MCPAISettings, apiKey: String?) async throws {
        var config = try await store.mcpConfiguration()
        config.aiSettings = settings
        try await store.save(config)
        if let apiKey, !apiKey.isEmpty { try await store.saveSecrets([Self.aiAccount(settings.provider): apiKey]) }
    }

    public func saveMCPAIProvider(_ provider: MCPAIProvider, model: String, apiKey: String?) async throws {
        var config = try await store.mcpConfiguration()
        var settings = config.aiSettings ?? MCPAISettings()
        if provider == .openAI { settings.openAIModel = model } else { settings.claudeModel = model }
        config.aiSettings = settings
        try await store.save(config)
        if let apiKey, !apiKey.isEmpty { try await store.saveSecrets([Self.aiAccount(provider): apiKey]) }
    }

    public func hasMCPAIKey(_ provider: MCPAIProvider) async throws -> Bool {
        try await store.secrets()[Self.aiAccount(provider)]?.isEmpty == false
    }

    public func generateMCPConfiguration(instructions: String, settings: MCPAISettings, apiKey: String? = nil) async throws -> String {
        if let apiKey, !apiKey.isEmpty { try await store.saveSecrets([Self.aiAccount(settings.provider): apiKey]) }
        guard let key = try await store.secrets()[Self.aiAccount(settings.provider)], !key.isEmpty else {
            throw SkillboxError.commandFailed("Wklej klucz API dla wybranego dostawcy")
        }
        let prompt = """
        Zamień poniższą instrukcję instalacji serwera lub serwerów MCP na sam poprawny JSON, bez markdownu i komentarzy.
        Zwróć obiekt, którego klucze są krótkimi nazwami serwerów, a wartości używają formatu Claude MCP:
        stdio: {"type":"stdio","command":"...","args":["..."],"env":{"NAZWA":"wartość"}}
        HTTP: {"type":"http","url":"https://...","headers":{"Authorization":"Bearer wartość"}}
        Nie wymyślaj brakujących tokenów. Zamiast nich wpisz odwołanie ${NAZWA_ZMIENNEJ}, np. ${GITHUB_TOKEN}. Nie uruchamiaj żadnych poleceń.

        INSTRUKCJA:
        \(instructions)
        """
        switch settings.provider {
        case .openAI: return try await callOpenAI(prompt: prompt, key: key, model: settings.openAIModel)
        case .claude: return try await callClaude(prompt: prompt, key: key, model: settings.claudeModel)
        }
    }

    private static func aiAccount(_ provider: MCPAIProvider) -> String { "ai/\(provider.rawValue)/api-key" }

    private func callOpenAI(prompt: String, key: String, model: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": prompt, "store": false, "text": ["format": ["type": "json_object"]]])
        let object = try await perform(request)
        if (object["status"] as? String) == "incomplete" { throw SkillboxError.commandFailed("OpenAI ucięło odpowiedź; skróć instrukcję lub spróbuj ponownie") }
        if let direct = object["output_text"] as? String { return direct }
        let output = object["output"] as? [[String: Any]] ?? []
        for item in output { for content in item["content"] as? [[String: Any]] ?? [] { if let text = content["text"] as? String { return text } } }
        throw SkillboxError.commandFailed("OpenAI nie zwróciło konfiguracji tekstowej")
    }

    private func callClaude(prompt: String, key: String, model: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "max_tokens": 8000, "messages": [["role": "user", "content": prompt]]])
        let object = try await perform(request)
        if (object["stop_reason"] as? String) == "max_tokens" { throw SkillboxError.commandFailed("Claude uciął odpowiedź po osiągnięciu limitu; skróć instrukcję") }
        for content in object["content"] as? [[String: Any]] ?? [] { if let text = content["text"] as? String { return Self.extractJSON(text) } }
        throw SkillboxError.commandFailed("Claude nie zwrócił konfiguracji tekstowej")
    }

    private func perform(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { $0["error"] }.map(String.init(describing:)) ?? String(decoding: data, as: UTF8.self)
            throw SkillboxError.commandFailed("API zwróciło HTTP \(status): \(detail.prefix(300))")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SkillboxError.commandFailed("Nieprawidłowa odpowiedź API") }
        return object
    }

    private static func extractJSON(_ text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return text }
        return String(text[start...end])
    }
}
