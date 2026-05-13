import Foundation

public struct Persona: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let systemPromptFragment: String

    public init(id: String, displayName: String, systemPromptFragment: String) {
        self.id = id
        self.displayName = displayName
        self.systemPromptFragment = systemPromptFragment
    }

    public static let presets: [Persona] = [
        .init(id: "natural",
              displayName: "Natural & Conversational",
              systemPromptFragment: "Continue in a warm, conversational tone. Use everyday words. Keep sentences short."),
        .init(id: "persuasive",
              displayName: "Persuasive",
              systemPromptFragment: "Continue persuasively. Use active voice, concrete examples, and confident verbs."),
        .init(id: "formal",
              displayName: "Formal & Professional",
              systemPromptFragment: "Continue in a polished, professional register. Avoid contractions and slang."),
        .init(id: "executive",
              displayName: "Executive Brief",
              systemPromptFragment: "Continue tersely, as a senior executive would. Lead with the point, then justify."),
        .init(id: "storyteller",
              displayName: "Storyteller",
              systemPromptFragment: "Continue with vivid sensory detail. Favor concrete nouns and rhythmic phrasing.")
    ]

    public static var natural: Persona { presets[0] }
}
