import Foundation

public enum ClaudeError: Error, CustomStringConvertible {
    case http(Int, String)
    case badResponse

    public var description: String {
        switch self {
        case let .http(code, body): return "Claude API HTTP \(code): \(body)"
        case .badResponse: return "Claude API returned no text"
        }
    }
}

/// Minimal Anthropic Messages API client.
public final class ClaudeClient: TextGenerator {
    let apiKey: String
    let model: String
    let timeout: TimeInterval
    /// How hard the model thinks ("low" … "max"). Current models think by default; "low" keeps dictation fast.
    let effort: String?
    /// Output cap for `complete`, thinking included.
    let maxTokens: Int

    public init(apiKey: String, model: String, timeout: TimeInterval = 12, effort: String? = nil, maxTokens: Int = 4096) {
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        self.effort = effort
        self.maxTokens = maxTokens
    }

    /// The dictation client: quick, low effort.
    public convenience init?(config: LLMConfig) {
        guard config.enabled, let key = config.resolvedKey else { return nil }
        self.init(apiKey: key, model: config.model, timeout: config.timeoutSeconds, effort: "low")
    }

    public func complete(system: String, user: String) async throws -> String {
        try await chat(system: system, messages: [(role: "user", text: user)], maxTokens: maxTokens)
    }

    /// Models that support server-side fallback when a safety classifier declines a request.
    var supportsFallbacks: Bool {
        ["claude-sonnet-5-5", "claude-opus-5-5", "claude-opus-5", "claude-fable-5-1"].contains(model)
    }

    /// A conversation: `messages` alternate "user" and "assistant", ending with the user's turn.
    public func chat(system: String, messages: [(role: String, text: String)], maxTokens: Int) async throws -> String {
        do {
            return try await send(system: system, messages: messages, maxTokens: maxTokens, fallbacks: supportsFallbacks)
        } catch ClaudeError.http(400, let body) where supportsFallbacks && body.contains("fallback") {
            // An account or model without server-side fallback: ask again without it.
            return try await send(system: system, messages: messages, maxTokens: maxTokens, fallbacks: false)
        }
    }

    private func send(system: String, messages: [(role: String, text: String)], maxTokens: Int,
                      fallbacks: Bool) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if fallbacks { request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages.map { ["role": $0.role, "content": $0.text] },
        ]
        if let effort { body["output_config"] = ["effort": effort] }
        // If a safety classifier declines, the API retries on a model chosen for that case.
        if fallbacks { body["fallbacks"] = "default" }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ClaudeError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { throw ClaudeError.badResponse }
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        guard !text.isEmpty else { throw ClaudeError.badResponse }
        return text
    }
}
