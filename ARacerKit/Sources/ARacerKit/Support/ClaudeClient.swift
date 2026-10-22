import Foundation

/// Thin Messages-API client (raw HTTP — no Swift SDK exists). Key comes from the Keychain, never hardcoded.
/// Runs over cellular while Wi-Fi is on the ECU bridge: URLSession picks the route with internet.
public struct ClaudeClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2026-10-21"
    public var model = "claude-haiku-5-5"
    public var effort = "high"
    let apiKey: String

    public init(apiKey: String) { self.apiKey = apiKey }

    public enum Error: Swift.Error, LocalizedError {
        case noKey, http(Int, String), refusal(String), truncated, noJSON
        public var errorDescription: String? {
            switch self {
            case .noKey: "No Claude API key — add one in Settings"
            case .http(let c, let m): "Claude API HTTP \(c): \(m)"
            case .refusal(let why): "Claude declined: \(why)"
            case .truncated: "Reply cut off (max_tokens) — try again"
            case .noJSON: "Reply had no JSON content"
            }
        }
    }

    public struct Reply: Sendable { public let json: Data; public let inputTokens: Int; public let outputTokens: Int; public let model: String }

    /// One structured call: system + user text, reply constrained to `schema` (JSON Schema object).
    public func structured(system: String, user: String, schema: [String: Any], maxTokens: Int = 16000) async throws -> Reply {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "fallbacks": "default",
            "system": system,
            "messages": [["role": "user", "content": user]],
            "output_config": ["effort": effort, "format": ["type": "json_schema", "schema": schema]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Error.http(code, String(decoding: data.prefix(300), as: UTF8.self)) }
        if code != 200 {
            let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw Error.http(code, msg)
        }
        let stop = obj["stop_reason"] as? String ?? ""
        if stop == "refusal" {
            let why = ((obj["stop_details"] as? [String: Any])?["explanation"] as? String) ?? "safety classifier"
            throw Error.refusal(why)
        }
        if stop == "max_tokens" { throw Error.truncated }
        let blocks = obj["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw Error.noJSON }
        let usage = obj["usage"] as? [String: Any] ?? [:]
        return Reply(json: Data(text.utf8), inputTokens: usage["input_tokens"] as? Int ?? 0,
                     outputTokens: usage["output_tokens"] as? Int ?? 0, model: obj["model"] as? String ?? model)
    }

    /// Cheap connectivity/key check: a tiny request, returns the model string that answered.
    public func ping() async throws -> String {
        let schema: [String: Any] = ["type": "object", "properties": ["ok": ["type": "boolean"]], "required": ["ok"], "additionalProperties": false]
        var c = self; c.effort = "low"
        return try await c.structured(system: "Reply with ok=true.", user: "ping", schema: schema, maxTokens: 256).model
    }
}
