import Foundation

/// Represents an OpenRouter AI model
public nonisolated struct OpenRouterModel: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let description: String?
    public let contextLength: Int
    public let pricing: OpenRouterPricing
    public let architecture: OpenRouterArchitecture?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case contextLength = "context_length"
        case pricing
        case architecture
    }

    /// Whether this model is free to use
    public var isFree: Bool {
        pricing.prompt == "0" && pricing.completion == "0"
    }

    /// Human-readable context length
    public var contextLengthFormatted: String {
        if contextLength >= 1_000_000 {
            return "\(contextLength / 1_000_000)M tokens"
        } else if contextLength >= 1000 {
            return "\(contextLength / 1000)K tokens"
        }
        return "\(contextLength) tokens"
    }

    /// Short display name (without provider prefix)
    public var shortName: String {
        // Remove provider prefix like "meta-llama/" or "google/"
        if let slashIndex = name.firstIndex(of: "/") {
            return String(name[name.index(after: slashIndex)...])
        }
        return name
    }

    /// Provider name extracted from model ID (e.g., "meta-llama" from "meta-llama/llama-3")
    public var providerName: String {
        if let slashIndex = id.firstIndex(of: "/") {
            return String(id[..<slashIndex])
        }
        return id
    }

    /// Formatted price per million tokens (for display)
    public var pricePerMillionTokens: String? {
        guard !isFree else { return nil }

        // Parse price strings (they're in dollars per token)
        guard let promptPrice = Double(pricing.prompt),
              let completionPrice = Double(pricing.completion)
        else {
            return nil
        }

        // Average of input/output, multiplied by 1M for per-million-token price
        let avgPrice = (promptPrice + completionPrice) / 2.0 * 1_000_000

        if avgPrice < 0.01 {
            return "<$0.01/M"
        } else if avgPrice < 1.0 {
            return String(format: "$%.2f/M", avgPrice)
        } else {
            return String(format: "$%.1f/M", avgPrice)
        }
    }

    /// Whether this is a text-only model (suitable for persona processing)
    public var isTextModel: Bool {
        // Filter out image-generation, audio, and other non-text models
        guard let modality = architecture?.modality else { return true }
        return modality.contains("text")
    }
}

public nonisolated struct OpenRouterPricing: Codable, Sendable, Hashable {
    public let prompt: String // Cost per input token (string for precision)
    public let completion: String // Cost per output token
    public let request: String? // Cost per request
    public let image: String? // Cost per image (for multimodal)

    enum CodingKeys: String, CodingKey {
        case prompt
        case completion
        case request
        case image
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try container.decode(String.self, forKey: .prompt)
        completion = try container.decode(String.self, forKey: .completion)
        request = try container.decodeIfPresent(String.self, forKey: .request)
        image = try container.decodeIfPresent(String.self, forKey: .image)
    }
}

public nonisolated struct OpenRouterArchitecture: Codable, Sendable, Hashable {
    public let tokenizer: String?
    public let instructType: String?
    public let modality: String?

    enum CodingKeys: String, CodingKey {
        case tokenizer
        case instructType = "instruct_type"
        case modality
    }
}

/// Response from /api/v1/models endpoint
public nonisolated struct OpenRouterModelsResponse: Codable, Sendable {
    public let data: [OpenRouterModel]
}

/// Chat completion request structure
public nonisolated struct OpenRouterChatRequest: Encodable, Sendable {
    public let model: String
    public let messages: [OpenRouterMessage]
    public let maxTokens: Int?
    public let temperature: Double?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case temperature
    }

    public init(
        model: String,
        messages: [OpenRouterMessage],
        maxTokens: Int? = 4096,
        temperature: Double? = 0.3
    ) {
        self.model = model
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public nonisolated struct OpenRouterMessage: Codable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// Chat completion response structure
public nonisolated struct OpenRouterChatResponse: Decodable, Sendable {
    public let id: String?
    public let choices: [OpenRouterChoice]
    public let usage: OpenRouterUsage?
}

public nonisolated struct OpenRouterChoice: Decodable, Sendable {
    public let message: OpenRouterMessage
    public let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }
}

public nonisolated struct OpenRouterUsage: Decodable, Sendable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

/// OAuth key exchange response
public nonisolated struct OpenRouterKeyResponse: Decodable, Sendable {
    public let key: String
}

/// Error response from OpenRouter API
public nonisolated struct OpenRouterErrorResponse: Decodable, Sendable {
    public let error: OpenRouterErrorDetail?
}

public nonisolated struct OpenRouterErrorDetail: Decodable, Sendable {
    public let message: String?
    public let code: String?
}
