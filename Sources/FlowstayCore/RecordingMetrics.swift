import Foundation

/// Metrics collected for each recording session
/// Used for debugging and understanding transcription performance
public nonisolated struct RecordingMetrics: Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let totalDuration: TimeInterval
    public let chunkCount: Int
    public let chunkDurations: [TimeInterval]
    public let transcriptionTimes: [TimeInterval]
    public let finalTextLength: Int
    public let hadErrors: Bool
    public let errorMessages: [String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        totalDuration: TimeInterval,
        chunkCount: Int,
        chunkDurations: [TimeInterval],
        transcriptionTimes: [TimeInterval],
        finalTextLength: Int,
        hadErrors: Bool,
        errorMessages: [String]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.totalDuration = totalDuration
        self.chunkCount = chunkCount
        self.chunkDurations = chunkDurations
        self.transcriptionTimes = transcriptionTimes
        self.finalTextLength = finalTextLength
        self.hadErrors = hadErrors
        self.errorMessages = errorMessages
    }
}

/// Persistent logger for recording metrics
/// Stores recent metrics to disk for debugging user-reported issues
public actor MetricsLogger {
    public static let shared = MetricsLogger()

    private let maxStoredMetrics = 100
    private var recentMetrics: [RecordingMetrics] = []
    private var fileURL: URL?

    private init() {
        // Setup file URL synchronously using nonisolated helper
        fileURL = Self.createFileURL()
        Task {
            await loadMetrics()
        }
    }

    /// Create the file URL for metrics storage (nonisolated for use in init)
    private nonisolated static func createFileURL() -> URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let flowstayDir = appSupport?.appendingPathComponent("Flowstay", isDirectory: true)

        // Ensure directory exists
        if let dir = flowstayDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        return flowstayDir?.appendingPathComponent("recording_metrics.json")
    }

    /// Log a new recording's metrics
    public func log(_ metrics: RecordingMetrics) {
        recentMetrics.insert(metrics, at: 0)

        // Keep only the most recent metrics
        if recentMetrics.count > maxStoredMetrics {
            recentMetrics = Array(recentMetrics.prefix(maxStoredMetrics))
        }

        // Persist to disk
        saveMetrics()

        // Log summary to console
        let summary = """
        [MetricsLogger] Recording metrics:
          - Duration: \(String(format: "%.1f", metrics.totalDuration))s
          - Chunks: \(metrics.chunkCount)
          - Text length: \(metrics.finalTextLength) chars
          - Had errors: \(metrics.hadErrors)
        """
        print(summary)
    }

    /// Get recent metrics for debugging
    public func getRecentMetrics() -> [RecordingMetrics] {
        recentMetrics
    }

    /// Get metrics summary for support requests
    public func getMetricsSummary() -> String {
        let recent = Array(recentMetrics.prefix(10))
        guard !recent.isEmpty else {
            return "No recent recordings"
        }

        let totalRecordings = recentMetrics.count
        let avgDuration = recent.map(\.totalDuration).reduce(0, +) / Double(recent.count)
        let avgChunks = Double(recent.map(\.chunkCount).reduce(0, +)) / Double(recent.count)
        let errorCount = recent.filter(\.hadErrors).count

        return """
        Recording Metrics Summary (last \(totalRecordings) recordings):
        - Avg duration: \(String(format: "%.1f", avgDuration))s
        - Avg chunks: \(String(format: "%.1f", avgChunks))
        - Error rate: \(errorCount)/\(recent.count)
        """
    }

    private func saveMetrics() {
        guard let url = fileURL else { return }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(recentMetrics)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[MetricsLogger] Failed to save metrics: \(error)")
        }
    }

    private func loadMetrics() {
        guard let url = fileURL,
              FileManager.default.fileExists(atPath: url.path)
        else {
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            recentMetrics = try decoder.decode([RecordingMetrics].self, from: data)
            print("[MetricsLogger] Loaded \(recentMetrics.count) historical metrics")
        } catch {
            print("[MetricsLogger] Failed to load metrics: \(error)")
            // Don't fail - just start fresh
            recentMetrics = []
        }
    }
}
