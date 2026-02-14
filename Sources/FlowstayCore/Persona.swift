import Foundation

/// A persona (built-in or user-created) that defines how transcripts should be styled
public nonisolated struct Persona: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var instruction: String
    public var emoji: String?
    public let isBuiltIn: Bool

    public init(id: String, name: String, instruction: String, emoji: String? = nil, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.instruction = instruction
        self.emoji = emoji
        self.isBuiltIn = isBuiltIn
    }

    /// Personas represent logical identities; equality/hash are keyed by stable `id`.
    public static func == (lhs: Persona, rhs: Persona) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: - Built-in Presets

    public static let cleanup = Persona(
        id: "cleanup",
        name: "Cleanup",
        instruction: """
        Remove filler words like: um, uh, like. Fix punctuation and capitalization.
        """,
        emoji: "🧹",
        isBuiltIn: true
    )

    public static let professional = Persona(
        id: "professional",
        name: "Professional",
        instruction: "Rewrite in a professional business tone",
        emoji: "💼",
        isBuiltIn: true
    )

    public static let concise = Persona(
        id: "concise",
        name: "Concise",
        instruction: "Make this text concise while preserving the core message",
        emoji: "✂️",
        isBuiltIn: true
    )

    public static var builtInPresets: [Persona] {
        [cleanup, professional, concise]
    }
}
