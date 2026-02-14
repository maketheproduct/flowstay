import Foundation

/// Represents a single transcription record with both raw and processed text
public nonisolated struct TranscriptionRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let duration: TimeInterval
    public let rawText: String
    public let processedText: String
    public let personaId: String?
    public let personaName: String?
    public let appBundleId: String?
    public let appName: String?
    public let wordCount: Int
    public let wasProcessed: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        duration: TimeInterval,
        rawText: String,
        processedText: String,
        personaId: String? = nil,
        personaName: String? = nil,
        appBundleId: String? = nil,
        appName: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.duration = duration
        self.rawText = rawText
        self.processedText = processedText
        self.personaId = personaId
        self.personaName = personaName
        self.appBundleId = appBundleId
        self.appName = appName
        wordCount = processedText.split(separator: " ").count
        wasProcessed = personaId != nil && rawText != processedText
    }

    /// Formatted timestamp for display
    public var formattedTimestamp: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(timestamp) {
            formatter.dateFormat = "'Today at' h:mm a"
        } else if calendar.isDateInYesterday(timestamp) {
            formatter.dateFormat = "'Yesterday at' h:mm a"
        } else {
            formatter.dateFormat = "MMM d 'at' h:mm a"
        }

        return formatter.string(from: timestamp)
    }

    /// Formatted duration for display
    public var formattedDuration: String {
        if duration < 60 {
            return String(format: "%.0fs", duration)
        } else {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return "\(minutes)m \(seconds)s"
        }
    }

    /// File name for markdown storage
    public var fileName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let shortId = id.uuidString.prefix(8).lowercased()
        return "\(formatter.string(from: timestamp))_\(shortId).md"
    }
}
