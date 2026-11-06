import Foundation

/// OpenRouter over plain HTTPS (M8): the model list and chat completions with an audio part.
/// The transport is a parameter, so tests answer as a fake server.
public struct OpenRouterClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let baseURL = URL(string: "https://openrouter.ai/api/v1/")!
    let key: String
    let base: URL
    let transport: Transport

    public init(key: String, base: URL = baseURL, transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.key = key
        self.base = base
        self.transport = transport
    }

    /// `GET /models`: OpenRouter's live list. It is public, so it loads before a key is saved.
    public func models() async throws -> [OpenRouterModel] {
        var request = URLRequest(url: base.appending(path: "models"))
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let data = try await send(request)
        struct List: Decodable { var data: [OpenRouterModel] }
        do { return try JSONDecoder().decode(List.self, from: data).data } catch { throw MeetingsError.badAnswer("model list: \(error)") }
    }

    /// `GET /key`: whether OpenRouter accepts the key (401 when it does not).
    public func checkKey() async throws {
        var request = URLRequest(url: base.appending(path: "key"), timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        _ = try await send(request)
    }

    /// `POST /chat/completions`: one user message of text parts and at most one audio part. The
    /// answer is asked as a JSON object.
    public func complete(model: String, system: String, text: String, audio: (data: Data, format: String)? = nil, timeout: TimeInterval = 600) async throws -> Completion {
        var parts: [[String: Any]] = [["type": "text", "text": text]]
        if let audio {
            parts.append(["type": "input_audio", "input_audio": ["data": audio.data.base64EncodedString(), "format": audio.format]])
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": parts]],
            "response_format": ["type": "json_object"],
            "temperature": 0,
            "usage": ["include": true],
        ]
        var request = URLRequest(url: base.appending(path: "chat/completions"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/ussov/akit", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Meetings", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        return try Completion.parse(data)
    }

    func send(_ request: URLRequest) async throws -> Data {
        let started = Date()
        let what = "\(request.httpMethod ?? "GET") /\(request.url?.path(percentEncoded: false).split(separator: "/").suffix(2).joined(separator: "/") ?? "?")"
        let auth = request.value(forHTTPHeaderField: "Authorization").map { "auth header, key \($0.dropFirst(7).count) chars" } ?? "no auth header"
        MeetingsLog.info(.openrouter, "\(what): sending \(request.httpBody?.count ?? 0) bytes, \(auth)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            MeetingsLog.error(.openrouter, "\(what): no answer after \(Int(Date().timeIntervalSince(started))) s: \(error.localizedDescription)")
            throw error
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        guard (200..<300).contains(code) else {
            MeetingsLog.error(.openrouter, "\(what): \(code) after \(ms) ms: \(Self.errorMessage(data))")
            throw MeetingsError.http(code, Self.errorMessage(data))
        }
        MeetingsLog.info(.openrouter, "\(what): \(code) after \(ms) ms, \(data.count) bytes")
        return data
    }

    /// `{"error": {"message": …}}`, else the start of the body. Never the request.
    static func errorMessage(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}

/// A chat answer: the text and what it cost.
public struct Completion: Equatable, Sendable {
    public var text: String
    public var promptTokens: Int
    public var completionTokens: Int
    /// USD as OpenRouter reported it; 0 when the answer had no cost.
    public var cost: Double

    static func parse(_ data: Data) throws -> Completion {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeetingsError.badAnswer("not JSON")
        }
        // OpenRouter can answer 200 with an error object (a provider failed mid-way).
        if let error = object["error"] as? [String: Any] {
            throw MeetingsError.http((error["code"] as? Int) ?? 200, (error["message"] as? String) ?? "error")
        }
        guard let choices = object["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw MeetingsError.badAnswer("no message in the answer")
        }
        let usage = object["usage"] as? [String: Any] ?? [:]
        func number(_ key: String) -> Double { (usage[key] as? NSNumber)?.doubleValue ?? 0 }
        return Completion(text: text, promptTokens: Int(number("prompt_tokens")), completionTokens: Int(number("completion_tokens")), cost: number("cost"))
    }
}

/// One entry of `GET /models`, only the fields Meetings reads.
public struct OpenRouterModel: Decodable, Equatable, Sendable, Identifiable {
    public struct Architecture: Decodable, Equatable, Sendable {
        public var input_modalities: [String]?
        public var output_modalities: [String]?
    }

    public struct Pricing: Decodable, Equatable, Sendable {
        public var prompt: String?
        public var completion: String?
        public var audio: String?
    }

    public var id: String
    public var name: String?
    public var architecture: Architecture?
    public var pricing: Pricing?
    public var context_length: Int?

    public init(id: String, name: String? = nil, input: [String], output: [String] = ["text"], prompt: String?, completion: String?, audio: String? = nil) {
        self.id = id
        self.name = name
        architecture = Architecture(input_modalities: input, output_modalities: output)
        pricing = Pricing(prompt: prompt, completion: completion, audio: audio)
    }
}
