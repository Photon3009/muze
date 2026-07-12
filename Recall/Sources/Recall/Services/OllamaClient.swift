import Foundation

/// Ollama client: JSON-mode completions for enrichment, streamed chat for answers.
struct OllamaClient {
    var baseURL: URL
    var model: String

    func isUp() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = 3
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// One-shot completion forced to emit JSON (format: "json").
    func completeJSON(system: String, user: String, timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "format": "json",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if model.hasPrefix("qwen3") { body["think"] = false }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        struct Resp: Decodable {
            struct Msg: Decodable { let content: String }
            let message: Msg
        }
        let content = try JSONDecoder().decode(Resp.self, from: data).message.content
        return Data(content.utf8)
    }

    /// Streamed chat; yields tokens as they arrive.
    func streamChat(messages: [[String: String]]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.timeoutInterval = 300
                    var body: [String: Any] = ["model": model, "stream": true, "messages": messages]
                    if model.hasPrefix("qwen3") { body["think"] = false }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let msg = obj["message"] as? [String: Any], let token = msg["content"] as? String, !token.isEmpty {
                            continuation.yield(token)
                        }
                        if (obj["done"] as? Bool) == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
