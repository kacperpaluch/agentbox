import Foundation

extension SkillboxService {
    /// Turns documentation or a plain-language description into a candidate configuration. The
    /// result is deliberately not saved here: it must still pass the normal import analysis and the
    /// user's secret classification choices.
    public func generateMCPConfiguration(instructions: String, apiKey: String, model: String = "gpt-5-mini") async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SkillboxError.commandFailed("Wklej klucz API OpenAI") }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "store": false,
            "input": Self.mcpAIPrompt(instructions),
            "text": ["format": ["type": "json_object"]]
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = String(decoding: data, as: UTF8.self).prefix(300)
            throw SkillboxError.commandFailed("OpenAI zwróciło HTTP \(status): \(detail)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SkillboxError.commandFailed("OpenAI zwróciło nieprawidłową odpowiedź") }
        let text = object["output_text"] as? String ?? Self.responseText(object)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SkillboxError.commandFailed("OpenAI nie zwróciło konfiguracji MCP") }
        // Validate now so the user sees an AI-specific, actionable error before the regular import
        // sheet replaces their source text.
        guard let output = text.data(using: .utf8), (try? JSONSerialization.jsonObject(with: output)) != nil else { throw SkillboxError.commandFailed("OpenAI nie zwróciło poprawnego JSON-a MCP") }
        return text
    }

    static func mcpAIPrompt(_ instructions: String) -> String {
        """
        Jesteś konwerterem instrukcji instalacji MCP do konfiguracji. Zwróć WYŁĄCZNIE poprawny JSON,
        bez Markdownu, komentarzy ani wyjaśnień. Zwróć dokładnie obiekt {"mcpServers": {...}}.
        Każdy klucz wewnątrz mcpServers ma być krótką nazwą z liter, cyfr, _ lub -.
        Serwer lokalny: {"command":"...","args":["..."],"env":{"NAZWA":"wartość"}}.
        Serwer HTTP: {"type":"http","url":"https://...","headers":{"Nazwa":"wartość"}}.
        Zachowaj dosłownie command, args, URL i znane wartości z instrukcji. Nigdy nie wymyślaj
        wartości, poleceń, URL-i, tokenów ani kluczy. Gdy instrukcja wymaga sekretu, użyj ${NAZWA_ZMIENNEJ}
        (np. ${GITHUB_TOKEN}) zamiast przykładowego sekretu. Nie uruchamiaj poleceń i nie dodawaj
        serwerów niewymienionych w instrukcji.

        INSTRUKCJA:
        \(instructions)
        """
    }

    private static func responseText(_ object: [String: Any]) -> String {
        for item in object["output"] as? [[String: Any]] ?? [] {
            for content in item["content"] as? [[String: Any]] ?? [] {
                if let text = content["text"] as? String { return text }
            }
        }
        return ""
    }
}
