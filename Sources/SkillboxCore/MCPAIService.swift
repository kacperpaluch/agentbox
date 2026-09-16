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

/// The OpenAI key for the MCP AI assistant, kept in the login keychain so it survives app restarts
/// without ever landing in plaintext preferences.
///
/// `account` exists for tests only: a test that round-tripped the production entry once printed
/// the user's real key in a failed assertion. Every status is checked — a save that deleted the old
/// entry and then failed to add the new one used to lose the key without a word.
public enum OpenAIKeyStore {
    public static let productionAccount = "openai-api-key"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Agentbox",
            kSecAttrAccount as String: account
        ]
    }

    public static func load(account: String = productionAccount) -> String {
        var item: CFTypeRef?
        var read = query(account)
        read[kSecReturnData as String] = true
        guard SecItemCopyMatching(read as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Stores the trimmed key. An empty key is not a way to delete — that is `delete`.
    public static func save(_ key: String, account: String = productionAccount) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let data = Data(trimmed.utf8)
        let updated = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw failure("zapisać", updated) }
        var add = query(account)
        add[kSecValueData as String] = data
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw failure("zapisać", added) }
    }

    public static func delete(account: String = productionAccount) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure("usunąć", status) }
    }

    private static func failure(_ verb: String, _ status: OSStatus) -> Error {
        let reason = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        return SkillboxError.commandFailed("nie udało się \(verb) klucza OpenAI w pęku kluczy: \(reason)")
    }
}
