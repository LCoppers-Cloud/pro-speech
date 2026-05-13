import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Darwin)

/// Streaming client for the Claude Messages API.
///
/// Apple-only: this implementation uses `URLSessionConfiguration.waitsForConnectivity`
/// and `URLSession.bytes(for:)`, neither of which is available in the Linux
/// `swift-corelibs-foundation` `URLSession`. The brain logic (RateTracker, Aligner,
/// BufferPolicy, PromptBuffer, SyllableCounter) does not depend on `ClaudeStream`,
/// so the brain still compiles and tests on Linux for CI; the iOS / macOS app is
/// the only consumer of streaming.
///
/// Design notes:
/// - Uses a long-lived `URLSession` so HTTP/2 + TLS are reused across requests.
/// - The system prompt (persona + notes) is cached with `cache_control: ephemeral`
///   so the first request pays the write cost (~25% premium) and every
///   subsequent request reads the cache (~10% cost, ~50-100ms TTFT saving).
/// - `keepCacheAlive()` should be invoked every ~2 minutes during a long
///   session; the cache TTL is 5 min but in practice expires near 3 min.
/// - `stream(...)` parses SSE incrementally and yields tokens word-at-a-time
///   so the consumer can append to the prompt buffer without waiting for the
///   model to finish.
public final class ClaudeStream: Sendable {
    public struct Config: Sendable {
        public var apiKey: String
        public var model: String
        public var maxTokens: Int
        public var stopSequences: [String]
        public var anthropicVersion: String

        public init(
            apiKey: String,
            model: String = "claude-haiku-4-5",
            maxTokens: Int = 24,
            stopSequences: [String] = ["\n\n"],
            anthropicVersion: String = "2023-06-01"
        ) {
            self.apiKey = apiKey
            self.model = model
            self.maxTokens = maxTokens
            self.stopSequences = stopSequences
            self.anthropicVersion = anthropicVersion
        }
    }

    public enum StreamError: Error, LocalizedError, Sendable {
        case invalidResponse(Int, body: String?)
        case decode(String)

        public var errorDescription: String? {
            switch self {
            case .invalidResponse(let code, let body):
                let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let hint: String
                switch code {
                case 401: hint = "Invalid API key — check it in Settings."
                case 403: hint = "API key rejected — likely wrong organization or revoked."
                case 404: hint = "Model name not found."
                case 429: hint = "Rate limited — slow down or check Anthropic account credits."
                case 400: hint = "Bad request to Claude — possibly model name or request shape."
                case 500..<600: hint = "Anthropic server error — try again in a moment."
                default: hint = ""
                }
                let bodyPart = trimmed.isEmpty ? "" : "\n\(trimmed.prefix(400))"
                return "Claude HTTP \(code)\(hint.isEmpty ? "" : ": \(hint)")\(bodyPart)"
            case .decode(let m):
                return "Claude decode error: \(m)"
            }
        }
    }

    /// Outcome of a `testConnection()` call.
    public struct ConnectionStatus: Sendable {
        public let ok: Bool
        public let message: String
        public let httpStatus: Int?
        public let tokensRemaining: Int?
        public let requestsRemaining: Int?
        public let model: String

        public init(
            ok: Bool,
            message: String,
            httpStatus: Int?,
            tokensRemaining: Int?,
            requestsRemaining: Int?,
            model: String
        ) {
            self.ok = ok
            self.message = message
            self.httpStatus = httpStatus
            self.tokensRemaining = tokensRemaining
            self.requestsRemaining = requestsRemaining
            self.model = model
        }
    }

    private let config: Config
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(config: Config, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.httpMaximumConnectionsPerHost = 4
            cfg.waitsForConnectivity = true
            cfg.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - Public API

    /// Stream the next words of suggested continuation.
    /// - Parameters:
    ///   - systemPrompt: persona + notes, will be cached.
    ///   - recentTranscript: rolling window of what the speaker has actually said.
    ///   - alreadyBuffered: the unspoken tail already in the buffer; new tokens must continue from here.
    ///   - chunkWords: target number of words to generate.
    /// - Returns: AsyncThrowingStream of individual token fragments.
    public func stream(
        systemPrompt: String,
        recentTranscript: String,
        alreadyBuffered: String,
        chunkWords: Int
    ) -> AsyncThrowingStream<String, Error> {
        let request = makeRequest(
            systemPrompt: systemPrompt,
            recentTranscript: recentTranscript,
            alreadyBuffered: alreadyBuffered,
            chunkWords: chunkWords,
            maxTokens: max(config.maxTokens, chunkWords * 4)
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: StreamError.invalidResponse(-1, body: "no HTTP response"))
                        return
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // Read body for the error message — Anthropic returns JSON
                        // with the failure reason in there.
                        var body = ""
                        do {
                            for try await line in bytes.lines {
                                body += line + "\n"
                                if body.count > 2000 { break }
                            }
                        } catch {
                            body += "\n(body read error: \(error.localizedDescription))"
                        }
                        continuation.finish(throwing: StreamError.invalidResponse(http.statusCode, body: body))
                        return
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8) else { continue }
                        if let fragment = ClaudeStream.extractDelta(data: data) {
                            continuation.yield(fragment)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Fire-and-forget cache keepalive. Sends a 1-token request that re-writes
    /// the system cache. Call every ~120s during long sessions.
    public func keepCacheAlive(systemPrompt: String) async throws {
        let request = makeRequest(
            systemPrompt: systemPrompt,
            recentTranscript: "",
            alreadyBuffered: "",
            chunkWords: 1,
            maxTokens: 1
        )
        _ = try await session.data(for: request)
    }

    /// Fires a 1-token request to validate api key + model + network and
    /// reads Anthropic's rate-limit headers so the UI can display them.
    /// Note: Anthropic does not expose an "account balance" endpoint; the
    /// returned `tokensRemaining` is the *rate-limit window* remaining, which
    /// resets each minute, not lifetime credits.
    public func testConnection() async -> ConnectionStatus {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(config.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 1,
            "stream": false,
            "messages": [["role": "user", "content": "."]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return ConnectionStatus(ok: false, message: "No HTTP response",
                                        httpStatus: nil, tokensRemaining: nil,
                                        requestsRemaining: nil, model: config.model)
            }
            let tokensRem = http.value(forHTTPHeaderField: "anthropic-ratelimit-tokens-remaining").flatMap { Int($0) }
            let reqRem = http.value(forHTTPHeaderField: "anthropic-ratelimit-requests-remaining").flatMap { Int($0) }

            if (200..<300).contains(http.statusCode) {
                return ConnectionStatus(
                    ok: true,
                    message: "Connected to \(config.model)",
                    httpStatus: http.statusCode,
                    tokensRemaining: tokensRem,
                    requestsRemaining: reqRem,
                    model: config.model
                )
            } else {
                let bodyString = String(data: data, encoding: .utf8) ?? ""
                let msg = StreamError.invalidResponse(http.statusCode, body: bodyString).errorDescription ?? "HTTP \(http.statusCode)"
                return ConnectionStatus(
                    ok: false,
                    message: msg,
                    httpStatus: http.statusCode,
                    tokensRemaining: tokensRem,
                    requestsRemaining: reqRem,
                    model: config.model
                )
            }
        } catch {
            return ConnectionStatus(
                ok: false,
                message: "Network error: \(error.localizedDescription)",
                httpStatus: nil,
                tokensRemaining: nil,
                requestsRemaining: nil,
                model: config.model
            )
        }
    }

    // MARK: - Internals

    private func makeRequest(
        systemPrompt: String,
        recentTranscript: String,
        alreadyBuffered: String,
        chunkWords: Int,
        maxTokens: Int
    ) -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(config.anthropicVersion, forHTTPHeaderField: "anthropic-version")

        let userMessage = """
        Recent transcript (what the speaker has actually said, may diverge from the script):
        \(recentTranscript.isEmpty ? "(none yet)" : recentTranscript)

        Already in the prompt buffer (do not repeat these):
        \(alreadyBuffered.isEmpty ? "(empty)" : alreadyBuffered)

        Produce the next \(chunkWords) words of natural-sounding continuation. \
        Continue directly from the buffered tail without restating it. \
        Output ONLY the new words, no quotes, no preamble, no punctuation \
        except a single trailing period if the sentence ends.
        """

        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "stream": true,
            "stop_sequences": config.stopSequences,
            "system": [
                [
                    "type": "text",
                    "text": systemPrompt,
                    "cache_control": ["type": "ephemeral"]
                ]
            ],
            "messages": [
                ["role": "user", "content": userMessage]
            ]
        ]

        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        return req
    }

    static func extractDelta(data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let type = obj["type"] as? String else { return nil }
        if type == "content_block_delta",
           let delta = obj["delta"] as? [String: Any],
           let text = delta["text"] as? String {
            return text
        }
        return nil
    }
}

#endif  // canImport(Darwin)

/// Builds the system prompt by concatenating persona + notes. Notes go after
/// the persona so the persona's tone framing applies to the notes content.
public enum SystemPromptBuilder {
    public static func build(persona: Persona, notes: String) -> String {
        """
        You are a real-time speech-prompting assistant. The user is giving a live \
        public speech and hears your output whispered into their ear. Your job: \
        produce only the next few words of natural continuation, in the user's \
        voice, that fits seamlessly with what they have just said.

        Tone: \(persona.systemPromptFragment)

        Rules:
        - Output ONLY new words to say. No quotes, no labels, no commentary.
        - Match the user's pace and register. Short clauses are easier to follow.
        - Never repeat words that are already in the buffered tail.
        - If the user has gone off-script, follow their new direction, do not pull them back to the notes.

        The user's notes for this speech follow. They are the source of truth \
        for facts and the desired direction, but you may rephrase freely.

        ---
        \(notes.isEmpty ? "(no notes provided — improvise based on the live transcript)" : notes)
        ---
        """
    }
}
