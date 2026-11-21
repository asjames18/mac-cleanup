import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MacSweepCore

// The only file in MacSweep that talks to the network. It is used only when AI suggestions are on,
// the OpenAI-compatible provider is picked, and the user presses Ask AI, Test Connection or Load Models.
// The key is read from the named environment variable at call time and never stored, logged or shown.

/// Sends one request. Tests swap in a stub, so unit tests never reach the network.
protocol AITransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

struct LiveAITransport: AITransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

enum AIError: Error, Equatable, LocalizedError {
    case notConfigured(String)
    case http(Int, String)
    case timedOut(Int)
    case invalidResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let why): why
        case .http(let code, let detail): "The endpoint answered HTTP \(code)\(detail.isEmpty ? "" : ": \(detail)")."
        case .timedOut(let seconds): "No answer within \(seconds) seconds."
        case .invalidResponse: "The endpoint's answer could not be read."
        case .network(let detail): "Could not reach the endpoint: \(detail)"
        }
    }
}

struct AIRunResult: Equatable, Sendable {
    var proposals: [SuggestionProposal]
    var model: String
    var seconds: Double
    var jsonMode: Bool
}

struct AIConnectionReport: Equatable, Sendable {
    var ok: Bool
    var seconds: Double
    var modelCount: Int
    var modelFound: Bool?
    var keyFound: Bool
    var message: String
}

struct AIClient: Sendable {
    let settings: AISettings
    var transport: any AITransport = LiveAITransport()
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var clock: @Sendable () -> Date = { Date() }

    static let systemPrompt = """
    You are MacSweep's cleanup advisor on a Mac. You get a summary of the latest scan: sizes and counts only, no file names.
    Choose up to 8 helpful suggestions, using ONLY actions from allowed_actions, copied exactly. Never invent actions, paths, \
    commands or numbers. You cannot empty the Trash, delete permanently, or pick individual files. Put larger, low-risk cleanups \
    first. Use review actions for personal files and anything you are unsure about.
    Reply with JSON only, in this shape:
    {"recommendations":[{"title":"short imperative title","reason":"one plain sentence","action":{"type":"trash_category","category":"caches"}}]}
    """

    var keyFound: Bool { key != nil }

    private var key: String? {
        let name = settings.keyEnv.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private var timeout: Int { min(max(settings.timeoutSeconds, AISettings.timeoutRange.lowerBound), AISettings.timeoutRange.upperBound) }

    private func endpoint(_ path: String) throws -> URL {
        let base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, AISettings.isEndpoint(base), var url = URL(string: base) else {
            throw AIError.notConfigured("Enter the endpoint's base URL, for example http://127.0.0.1:1234/v1.")
        }
        while url.path.hasSuffix("/") && url.path.count > 1 { url = url.deletingLastPathComponent() }
        return url.appendingPathComponent(path)
    }

    private func request(_ url: URL, method: String, body: Data? = nil, seconds: Double) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: max(1, seconds))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if url.host?.lowercased().hasSuffix("openrouter.ai") == true { request.setValue("MacSweep", forHTTPHeaderField: "X-Title") }
        request.httpBody = body
        return request
    }

    /// Removes the key from any text that might be shown, in case an endpoint echoes it back.
    func scrub(_ text: String) -> String {
        var result = String(text.prefix(300))
        if let key, !key.isEmpty { result = result.replacingOccurrences(of: key, with: "•••") }
        return result.replacingOccurrences(of: "\n", with: " ")
    }

    /// Runs `work` with a hard deadline. Whatever is still running at the deadline is cancelled.
    func withDeadline<T: Sendable>(_ seconds: Int, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                throw AIError.timedOut(seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AIError.invalidResponse }
            return first
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do { return try await transport.send(request) }
        catch let error as AIError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw AIError.network(scrub(error.localizedDescription)) }
    }

    // MARK: Suggestions

    func suggestions(snapshot: Data) async throws -> AIRunResult {
        guard settings.provider == .openai else { throw AIError.notConfigured("Pick the OpenAI-compatible provider to ask an AI.") }
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AIError.notConfigured("Enter a model name, or use Load Models.") }
        let url = try endpoint("chat/completions")
        let limit = timeout
        let started = clock()
        let snapshotText = String(decoding: snapshot.prefix(20_000), as: UTF8.self)
        return try await withDeadline(limit) { [self] in
            var body: [String: Any] = [
                "model": model, "temperature": 0.1, "max_tokens": 4_000,
                "messages": [["role": "system", "content": Self.systemPrompt], ["role": "user", "content": snapshotText]],
                "response_format": ["type": "json_object"],
            ]
            if url.host?.lowercased().hasSuffix("openrouter.ai") == true { body["reasoning"] = ["effort": "low", "exclude": true] }
            var jsonMode = true
            var (data, status) = try await send(request(url, method: "POST", body: try JSONSerialization.data(withJSONObject: body),
                                                        seconds: Double(limit) - clock().timeIntervalSince(started)))
            if [400, 404, 415, 422].contains(status) {
                // The endpoint or model has no JSON mode: ask again without it.
                body.removeValue(forKey: "response_format")
                body.removeValue(forKey: "reasoning")
                jsonMode = false
                (data, status) = try await send(request(url, method: "POST", body: try JSONSerialization.data(withJSONObject: body),
                                                        seconds: Double(limit) - clock().timeIntervalSince(started)))
            }
            guard (200..<300).contains(status) else { throw AIError.http(status, scrub(Self.errorDetail(data))) }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.invalidResponse }
            let choice = (object["choices"] as? [[String: Any]])?.first
            let message = choice?["message"] as? [String: Any]
            var content = (message?["content"] as? String) ?? ""
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let reasoning = message?["reasoning"] as? String {
                // Some models put the final JSON in the reasoning field.
                content = String(reasoning.suffix(6_000))
            }
            let used = (object["model"] as? String).map { String($0.prefix(80)) } ?? model
            return AIRunResult(proposals: SuggestionResponseParser.parse(content), model: used,
                               seconds: (clock().timeIntervalSince(started) * 10).rounded() / 10, jsonMode: jsonMode)
        }
    }

    static func errorDetail(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = object["error"] as? String { return message }
            if let message = object["message"] as? String { return message }
        }
        return ""
    }

    // MARK: Connection test and model list (GET /models: no tokens used)

    func models() async throws -> [String] {
        let url = try endpoint("models")
        let limit = timeout
        return try await withDeadline(limit) { [self] in
            let (data, status) = try await send(request(url, method: "GET", seconds: Double(limit)))
            guard (200..<300).contains(status) else { throw AIError.http(status, scrub(Self.errorDetail(data))) }
            guard let object = try? JSONSerialization.jsonObject(with: data) else { throw AIError.invalidResponse }
            let list = ((object as? [String: Any])?["data"] as? [[String: Any]]) ?? ((object as? [String: Any])?["models"] as? [[String: Any]]) ?? []
            let ids = list.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }.map { String($0.prefix(120)) }
            return Array(Set(ids)).sorted().prefix(500).map { $0 }
        }
    }

    func testConnection() async -> AIConnectionReport {
        let started = clock()
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let ids = try await models()
            let seconds = (clock().timeIntervalSince(started) * 100).rounded() / 100
            let found: Bool? = model.isEmpty ? nil : ids.contains(model)
            var message = "Connected in \(String(format: "%.2f", seconds)) s · \(ids.count) models available"
            if let found { message += found ? " · \(model) is available" : " · \(model) was not in the list" }
            if !settings.keyEnv.isEmpty { message += keyFound ? " · key variable found" : " · key variable \(settings.keyEnv) is not set for MacSweep" }
            return AIConnectionReport(ok: true, seconds: seconds, modelCount: ids.count, modelFound: found, keyFound: keyFound, message: message + ".")
        } catch {
            let seconds = (clock().timeIntervalSince(started) * 100).rounded() / 100
            var message = "Test failed after \(String(format: "%.2f", seconds)) s: \(scrub(error.localizedDescription))"
            if !settings.keyEnv.isEmpty && !keyFound { message += " The key variable \(settings.keyEnv) is not set for MacSweep." }
            return AIConnectionReport(ok: false, seconds: seconds, modelCount: 0, modelFound: nil, keyFound: keyFound, message: message)
        }
    }
}
