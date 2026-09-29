import CoreGraphics
import Foundation

enum StreamEvent {
    /// Reasoning has begun. Raw thinking text is never returned, so this is a
    /// progress signal only — it lets the UI say "thinking" instead of showing
    /// an empty pane during the pause before visible text starts.
    case thinkingStarted
    case textDelta(String)
}

enum ProviderError: LocalizedError {
    case missingKey(Provider)
    case http(status: Int, message: String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider):
            return "No \(provider.displayName) API key set. Add one in Settings."
        case .http(let status, let message):
            return "\(status): \(message)"
        case .badResponse(let message):
            return message
        }
    }
}

/// Extra framing appended to the user's prompt template. Keeps the model on the
/// code rather than the screenshot, and the XML-tag line guards against
/// internal tags leaking into visible output (a documented failure mode when
/// thinking is disabled).
private let framing = """

The image is a screenshot of a region of the user's screen that contains code. \
Explain the code itself — do not describe the screenshot, the editor, the theme, \
colors, or fonts. If the region is clipped, work with what is visible and only \
mention the clipping if it changes your answer. Do not include internal or \
system XML tags in your response.
"""

protocol ExplainProvider {
    func stream(prompt: String, imagePNG: Data, settings: Settings)
        -> AsyncThrowingStream<StreamEvent, Error>
}

enum Providers {
    /// Endpoint overrides, so the streaming path can be exercised against a
    /// local fake server without a live API key. Unset in normal use.
    static func baseURL(for provider: Provider) -> String {
        let key: String
        let fallback: String
        switch provider {
        case .anthropic:
            key = "POINTER_ANTHROPIC_BASE_URL"
            fallback = "https://api.anthropic.com"
        case .openai:
            key = "POINTER_OPENAI_BASE_URL"
            fallback = "https://api.openai.com"
        }
        let value = ProcessInfo.processInfo.environment[key] ?? ""
        return value.isEmpty ? fallback : value
    }

    /// Keychain first; falls back to the provider's conventional environment
    /// variable so a key already exported in the shell works without re-entry.
    static func apiKey(for provider: Provider) -> String? {
        if let stored = Keychain.key(for: provider) { return stored }
        let name = provider == .anthropic ? "ANTHROPIC_API_KEY" : "OPENAI_API_KEY"
        let value = ProcessInfo.processInfo.environment[name] ?? ""
        return value.isEmpty ? nil : value
    }

    static func provider(for settings: Settings) -> ExplainProvider {
        switch settings.provider {
        case .anthropic: return AnthropicProvider()
        case .openai: return OpenAIProvider()
        }
    }

    static func systemPrompt(from template: String) -> String {
        template.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + framing
    }
}

// MARK: - Anthropic

struct AnthropicProvider: ExplainProvider {
    func stream(prompt: String, imagePNG: Data, settings: Settings)
        -> AsyncThrowingStream<StreamEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = Providers.apiKey(for: .anthropic) else {
                        throw ProviderError.missingKey(.anthropic)
                    }

                    var body: [String: Any] = [
                        "model": settings.anthropicModel,
                        "max_tokens": settings.maxTokens,
                        "stream": true,
                        "system": Providers.systemPrompt(from: prompt),
                        "messages": [
                            [
                                "role": "user",
                                "content": [
                                    [
                                        "type": "image",
                                        "source": [
                                            "type": "base64",
                                            "media_type": "image/png",
                                            "data": imagePNG.base64EncodedString(),
                                        ],
                                    ],
                                    [
                                        "type": "text",
                                        "text": "Explain the code in this image.",
                                    ],
                                ],
                            ]
                        ],
                    ]

                    // Both are model-gated: adaptive thinking and `effort` are
                    // rejected by older models such as Haiku 4.5. They are
                    // config fields (rather than hardcoded) so switching model
                    // is a config edit, not a code change.
                    if !settings.anthropicThinking.isEmpty {
                        body["thinking"] = ["type": settings.anthropicThinking]
                    }
                    if !settings.anthropicEffort.isEmpty {
                        body["output_config"] = ["effort": settings.anthropicEffort]
                    }

                    let endpoint = Providers.baseURL(for: .anthropic) + "/v1/messages"
                    var request = URLRequest(url: URL(string: endpoint)!)
                    request.httpMethod = "POST"
                    request.setValue(key, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try await SSE.checkStatus(response, bytes: bytes, extract: Self.errorMessage)

                    var sawText = false
                    for try await line in bytes.lines {
                        guard let payload = SSE.dataPayload(from: line) else { continue }
                        guard let json = payload.jsonObject else { continue }

                        switch json["type"] as? String {
                        case "content_block_start":
                            let block = json["content_block"] as? [String: Any]
                            if block?["type"] as? String == "thinking", !sawText {
                                continuation.yield(.thinkingStarted)
                            }

                        case "content_block_delta":
                            guard let delta = json["delta"] as? [String: Any] else { continue }
                            // Ignore thinking_delta: with display omitted (the
                            // default) it carries no text anyway.
                            if delta["type"] as? String == "text_delta",
                               let text = delta["text"] as? String
                            {
                                sawText = true
                                continuation.yield(.textDelta(text))
                            }

                        case "message_delta":
                            if let delta = json["delta"] as? [String: Any],
                               let stop = delta["stop_reason"] as? String,
                               stop == "refusal"
                            {
                                throw ProviderError.badResponse(
                                    "The model declined this request (stop_reason: refusal)."
                                )
                            }

                        case "error":
                            let error = json["error"] as? [String: Any]
                            let message = error?["message"] as? String ?? "Unknown streaming error."
                            throw ProviderError.badResponse(message)

                        case "message_stop":
                            continuation.finish()
                            return

                        default:
                            continue
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

    private static func errorMessage(from data: Data) -> String {
        guard let json = data.jsonObject,
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String
        else {
            return String(data: data, encoding: .utf8) ?? "Unknown error"
        }
        return message
    }
}

// MARK: - OpenAI

struct OpenAIProvider: ExplainProvider {
    func stream(prompt: String, imagePNG: Data, settings: Settings)
        -> AsyncThrowingStream<StreamEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = Providers.apiKey(for: .openai) else {
                        throw ProviderError.missingKey(.openai)
                    }

                    let dataURI = "data:image/png;base64,\(imagePNG.base64EncodedString())"
                    let body: [String: Any] = [
                        "model": settings.openaiModel,
                        "stream": true,
                        // The forward-compatible spelling; newer models reject
                        // the older `max_tokens`.
                        "max_completion_tokens": settings.maxTokens,
                        "messages": [
                            [
                                "role": "system",
                                "content": Providers.systemPrompt(from: prompt),
                            ],
                            [
                                "role": "user",
                                "content": [
                                    ["type": "text", "text": "Explain the code in this image."],
                                    ["type": "image_url", "image_url": ["url": dataURI]],
                                ],
                            ],
                        ],
                    ]

                    let endpoint = Providers.baseURL(for: .openai) + "/v1/chat/completions"
                    var request = URLRequest(url: URL(string: endpoint)!)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try await SSE.checkStatus(response, bytes: bytes, extract: Self.errorMessage)

                    for try await line in bytes.lines {
                        guard let payload = SSE.dataPayload(from: line) else { continue }
                        if payload == "[DONE]" {
                            continuation.finish()
                            return
                        }
                        guard let json = payload.jsonObject else { continue }

                        if let error = json["error"] as? [String: Any] {
                            let message = error["message"] as? String ?? "Unknown streaming error."
                            throw ProviderError.badResponse(message)
                        }

                        guard let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let text = delta["content"] as? String,
                              !text.isEmpty
                        else { continue }

                        continuation.yield(.textDelta(text))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func errorMessage(from data: Data) -> String {
        guard let json = data.jsonObject,
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String
        else {
            return String(data: data, encoding: .utf8) ?? "Unknown error"
        }
        return message
    }
}

// MARK: - SSE helpers

enum SSE {
    /// Extracts the payload of a `data:` line, or nil for comments, blank
    /// lines, and `event:` lines.
    static func dataPayload(from line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let value = line.dropFirst("data:".count)
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A non-2xx response still arrives as a byte stream, so the body has to be
    /// drained to recover the API's error message.
    static func checkStatus(
        _ response: URLResponse,
        bytes: URLSession.AsyncBytes,
        extract: (Data) -> String
    ) async throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }

        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 64_000 { break }
        }
        throw ProviderError.http(status: http.statusCode, message: extract(data))
    }
}

extension Data {
    var jsonObject: [String: Any]? {
        try? JSONSerialization.jsonObject(with: self) as? [String: Any]
    }
}

extension String {
    var jsonObject: [String: Any]? {
        Data(utf8).jsonObject
    }
}

// MARK: - Cost estimation

enum CostEstimate {
    /// Input/output USD per million tokens for models with published pricing.
    private static let anthropicPricing: [String: (input: Double, output: Double)] = [
        "claude-fable-5": (10, 50),
        "claude-mythos-5": (10, 50),
        "claude-opus-5": (5, 25),
        "claude-opus-4-8": (5, 25),
        "claude-opus-4-7": (5, 25),
        "claude-opus-4-6": (5, 25),
        "claude-sonnet-5": (3, 15),
        "claude-sonnet-4-6": (3, 15),
        "claude-haiku-4-5": (1, 5),
    ]

    /// Anthropic bills images at roughly (width × height) / 750 tokens.
    static func imageTokens(pixelWidth: Int, pixelHeight: Int) -> Int {
        max(1, (pixelWidth * pixelHeight) / 750)
    }

    /// Rough per-capture cost. Returns nil when the model's pricing isn't known
    /// (any OpenAI model, or a Claude model not in the table) — better to show
    /// a token count than invent a number.
    static func describe(settings: Settings, image: CGImage) -> String {
        let tokens = imageTokens(pixelWidth: image.width, pixelHeight: image.height)
        // Prompt overhead plus a short answer.
        let inputTokens = tokens + 250
        let outputTokens = 250

        guard settings.provider == .anthropic,
              let price = anthropicPricing[settings.anthropicModel]
        else {
            return "≈\(inputTokens.formattedThousands) input tokens"
        }

        let cost = Double(inputTokens) / 1_000_000 * price.input
            + Double(outputTokens) / 1_000_000 * price.output

        let formatted: String
        if cost < 0.01 {
            formatted = String(format: "%.3f", cost)
        } else {
            formatted = String(format: "%.2f", cost)
        }
        return "≈\(inputTokens.formattedThousands) input tokens · ~$\(formatted)"
    }
}

extension Int {
    var formattedThousands: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}
