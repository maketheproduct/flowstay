import Foundation
import os

// MARK: - History Errors

/// Errors that can occur during history operations
public nonisolated enum HistoryError: LocalizedError, Sendable {
    case directoryCreationFailed(underlying: Error)
    case readFailed(underlying: Error)
    case writeFailed(underlying: Error)
    case deleteFailed(underlying: Error)
    case parseError(file: String)

    public var errorDescription: String? {
        switch self {
        case let .directoryCreationFailed(error):
            "Failed to create history directory: \(error.localizedDescription)"
        case let .readFailed(error):
            "Failed to read history: \(error.localizedDescription)"
        case let .writeFailed(error):
            "Failed to save transcription: \(error.localizedDescription)"
        case let .deleteFailed(error):
            "Failed to delete record: \(error.localizedDescription)"
        case let .parseError(file):
            "Failed to parse history file: \(file)"
        }
    }
}

/// Persistent storage for transcription history using markdown files
public actor TranscriptionHistoryStore {
    public static let shared = TranscriptionHistoryStore()

    private let logger = Logger(subsystem: "com.flowstay.core", category: "TranscriptionHistory")
    private let fileManager = FileManager.default

    // MARK: - Directory Management

    /// Get the history directory, creating it if needed
    private func historyDirectory() -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            // Fallback to temp directory if Application Support is unavailable
            logger.error("[History] Application Support directory not available, using temp directory")
            return fileManager.temporaryDirectory.appendingPathComponent("Flowstay/History", isDirectory: true)
        }
        let flowstayDir = appSupport.appendingPathComponent("Flowstay", isDirectory: true)
        let historyDir = flowstayDir.appendingPathComponent("History", isDirectory: true)

        if !fileManager.fileExists(atPath: historyDir.path) {
            do {
                try fileManager.createDirectory(at: historyDir, withIntermediateDirectories: true)
                logger.info("[History] Created history directory at \(historyDir.path)")
            } catch {
                logger.error("[History] Failed to create history directory: \(error.localizedDescription)")
            }
        }

        return historyDir
    }

    /// Get file path for a record
    private func filePath(for record: TranscriptionRecord) -> URL {
        historyDirectory().appendingPathComponent(record.fileName)
    }

    private func markdownFiles(
        in directory: URL,
        includingPropertiesForKeys keys: [URLResourceKey]? = nil
    ) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
            .filter { $0.pathExtension == "md" }
    }

    // MARK: - CRUD Operations

    /// Add a new transcription record
    /// - Throws: HistoryError.writeFailed if the record cannot be saved
    public func add(_ record: TranscriptionRecord) async throws {
        do {
            try writeMarkdownFile(record)
            logger.info("[History] Saved transcription \(record.id.uuidString.prefix(8))")
        } catch {
            logger.error("[History] Failed to save transcription: \(error.localizedDescription)")
            throw HistoryError.writeFailed(underlying: error)
        }
    }

    /// Add a new transcription record, logging errors but not throwing
    public func addIgnoringErrors(_ record: TranscriptionRecord) async {
        do {
            try await add(record)
        } catch {
            // Error already logged in add()
        }
    }

    /// Get all transcription records, sorted by timestamp (newest first)
    /// - Throws: HistoryError.readFailed if directory cannot be read
    public func getAll() async throws -> [TranscriptionRecord] {
        let directory = historyDirectory()

        let files: [URL]
        do {
            files = try markdownFiles(in: directory, includingPropertiesForKeys: [.creationDateKey])
        } catch {
            logger.error("[History] Failed to load records: \(error.localizedDescription)")
            throw HistoryError.readFailed(underlying: error)
        }

        var records: [TranscriptionRecord] = []
        for file in files {
            if let record = parseMarkdownFile(file) {
                records.append(record)
            }
        }

        // Sort by timestamp, newest first
        records.sort { $0.timestamp > $1.timestamp }

        logger.debug("[History] Loaded \(records.count) records")
        return records
    }

    /// Get all transcription records, returning empty array on error (backward compatible)
    public func getAllOrEmpty() async -> [TranscriptionRecord] {
        do {
            return try await getAll()
        } catch {
            logger.error("[History] getAllOrEmpty returning empty due to error: \(error.localizedDescription)")
            return []
        }
    }

    /// Delete a specific record
    /// - Throws: HistoryError.deleteFailed if the record cannot be deleted
    public func delete(_ id: UUID) async throws {
        let directory = historyDirectory()

        let files: [URL]
        do {
            files = try markdownFiles(in: directory)
        } catch {
            logger.error("[History] Failed to read directory for deletion: \(error.localizedDescription)")
            throw HistoryError.deleteFailed(underlying: error)
        }

        for file in files {
            if let record = parseMarkdownFile(file), record.id == id {
                do {
                    try fileManager.removeItem(at: file)
                    logger.info("[History] Deleted transcription \(id.uuidString.prefix(8))")
                    return
                } catch {
                    logger.error("[History] Failed to delete record: \(error.localizedDescription)")
                    throw HistoryError.deleteFailed(underlying: error)
                }
            }
        }
        // Record not found - not an error, just nothing to delete
    }

    /// Delete a specific record, ignoring errors
    public func deleteIgnoringErrors(_ id: UUID) async {
        do {
            try await delete(id)
        } catch {
            // Error already logged in delete()
        }
    }

    /// Delete records older than specified days
    /// - Returns: Number of records deleted
    public func deleteOlderThan(days: Int) async -> Int {
        guard days > 0 else { return 0 }

        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else {
            logger.error("[History] Failed to calculate cutoff date")
            return 0
        }
        let directory = historyDirectory()
        var deletedCount = 0

        do {
            let files = try markdownFiles(in: directory)

            for file in files {
                if let record = parseMarkdownFile(file), record.timestamp < cutoffDate {
                    try fileManager.removeItem(at: file)
                    deletedCount += 1
                }
            }

            if deletedCount > 0 {
                logger.info("[History] Cleaned up \(deletedCount) records older than \(days) days")
            }
        } catch {
            logger.error("[History] Failed to cleanup old records: \(error.localizedDescription)")
        }

        return deletedCount
    }

    /// Delete all history
    public func deleteAll() async -> Int {
        let directory = historyDirectory()
        var deletedCount = 0

        do {
            let files = try markdownFiles(in: directory)

            for file in files {
                try fileManager.removeItem(at: file)
                deletedCount += 1
            }

            logger.info("[History] Deleted all \(deletedCount) records")
        } catch {
            logger.error("[History] Failed to delete all records: \(error.localizedDescription)")
        }

        return deletedCount
    }

    // MARK: - Search

    /// Search records by text content
    public func search(_ query: String) async -> [TranscriptionRecord] {
        guard !query.isEmpty else { return await getAllOrEmpty() }

        let allRecords = await getAllOrEmpty()
        let lowercasedQuery = query.lowercased()

        return allRecords.filter { record in
            record.rawText.lowercased().contains(lowercasedQuery) ||
                record.processedText.lowercased().contains(lowercasedQuery) ||
                (record.appName?.lowercased().contains(lowercasedQuery) ?? false) ||
                (record.personaName?.lowercased().contains(lowercasedQuery) ?? false)
        }
    }

    // MARK: - Markdown File Operations

    /// Write a record as a markdown file
    private func writeMarkdownFile(_ record: TranscriptionRecord) throws {
        let path = filePath(for: record)

        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime]

        var content = """
        ---
        id: \(record.id.uuidString)
        timestamp: \(iso8601Formatter.string(from: record.timestamp))
        duration: \(record.duration)
        """

        if let personaId = record.personaId {
            content += "\npersona: \(personaId)"
        }
        if let personaName = record.personaName {
            content += "\npersona_name: \(personaName)"
        }
        if let appBundleId = record.appBundleId {
            content += "\napp_bundle_id: \(appBundleId)"
        }
        if let appName = record.appName {
            content += "\napp_name: \(appName)"
        }

        content += """

        word_count: \(record.wordCount)
        was_processed: \(record.wasProcessed)
        ---

        ## Original Transcription

        \(record.rawText)

        ## Processed Text

        \(record.processedText)
        """

        try content.write(to: path, atomically: true, encoding: .utf8)
    }

    /// Parse a markdown file into a TranscriptionRecord
    private func parseMarkdownFile(_ url: URL) -> TranscriptionRecord? {
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            logger.warning("[History] Failed to read history file \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }

        // Parse YAML frontmatter
        let parts = content.components(separatedBy: "---")
        guard parts.count >= 3 else { return nil }

        let frontmatter = parts[1]
        let body = parts[2...].joined(separator: "---")

        // Parse frontmatter fields
        var fields: [String: String] = [:]
        for line in frontmatter.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let colonIndex = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                fields[key] = value
            }
        }

        // Extract required fields
        guard let idString = fields["id"],
              let id = UUID(uuidString: idString),
              let timestampString = fields["timestamp"],
              let durationString = fields["duration"],
              let duration = Double(durationString)
        else {
            return nil
        }

        // Parse timestamp
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime]
        guard let timestamp = iso8601Formatter.date(from: timestampString) else {
            return nil
        }

        // Extract text sections
        let rawText = extractSection(from: body, header: "## Original Transcription")
        let processedText = extractSection(from: body, header: "## Processed Text")

        return TranscriptionRecord(
            id: id,
            timestamp: timestamp,
            duration: duration,
            rawText: rawText,
            processedText: processedText,
            personaId: fields["persona"],
            personaName: fields["persona_name"],
            appBundleId: fields["app_bundle_id"],
            appName: fields["app_name"]
        )
    }

    /// Extract text content after a markdown header
    private func extractSection(from body: String, header: String) -> String {
        guard let headerRange = body.range(of: header) else { return "" }

        let afterHeader = String(body[headerRange.upperBound...])

        // Find the next header or end of string
        if let nextHeaderRange = afterHeader.range(of: "\n## ") {
            return String(afterHeader[..<nextHeaderRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return afterHeader.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Statistics

    /// Get count of records
    public func count() async -> Int {
        let directory = historyDirectory()
        do {
            let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "md" }
            return files.count
        } catch {
            return 0
        }
    }
}
