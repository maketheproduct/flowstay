import AVFoundation
import Foundation
import ServiceManagement
import Speech
import SwiftUI

// MARK: - Speech Engine Protocol

public protocol SpeechEngineProtocol: AnyObject {
    var isAvailable: Bool { get }
    var engineType: SpeechEngineType { get }

    func startTranscription(audioBuffer: AVAudioPCMBuffer) async throws
    func stopTranscription() async throws
    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) async

    var transcriptionHandler: ((TranscriptionResult) -> Void)? { get set }
}

public nonisolated enum SpeechEngineType: String, CaseIterable, Codable, Sendable {
    case fluidAudio = "Parakeet ASR"

    public var displayName: String {
        rawValue
    }

    public var requiresMacOS14: Bool {
        false // Both engines work on macOS 14+
    }

    public var isOffline: Bool {
        true // Both engines are offline/on-device
    }
}

public struct TranscriptionResult {
    public let text: String
    public let isFinal: Bool
    public let confidence: Float?
    public let timestamp: Date

    public init(text: String, isFinal: Bool, confidence: Float? = nil, timestamp: Date = Date()) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

// MARK: - Audio Capture Protocol

public protocol AudioCaptureProtocol: AnyObject {
    var isRecording: Bool { get }
    var audioLevel: Float { get }

    func startCapture() async throws
    func stopCapture() async throws

    var audioBufferHandler: ((AVAudioPCMBuffer) -> Void)? { get set }
    var audioLevelHandler: ((Float) -> Void)? { get set }
}

// MARK: - Model Manager Protocol

public protocol ModelManagerProtocol: AnyObject, Sendable {
    var availableModels: [SpeechModel] { get }
    var downloadedModels: [SpeechModel] { get }
    var activeModel: SpeechModel? { get set }

    func fetchManifest() async throws
    func downloadModel(_ model: SpeechModel) async throws
    func deleteModel(_ model: SpeechModel) async throws
    func verifyModel(_ model: SpeechModel) async throws -> Bool
}

public nonisolated struct SpeechModel: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let size: Int64
    public let language: String
    public let url: URL
    public let sha256: String?
    public let engineType: SpeechEngineType

    public init(id: String, name: String, size: Int64, language: String, url: URL, sha256: String?, engineType: SpeechEngineType) {
        self.id = id
        self.name = name
        self.size = size
        self.language = language
        self.url = url
        self.sha256 = sha256
        self.engineType = engineType
    }
}

// MARK: - Storage Protocol

public protocol StorageProtocol: AnyObject {
    func saveTranscript(_ transcript: Transcript) async throws
    func fetchTranscripts(limit: Int) async throws -> [Transcript]
    func deleteTranscript(_ id: UUID) async throws
    func deleteAllTranscripts() async throws

    func saveProfile(_ profile: Profile) async throws
    func fetchProfiles() async throws -> [Profile]
    func deleteProfile(_ id: UUID) async throws

    func saveSetting(_ value: some Codable, forKey key: String) async throws
    func fetchSetting<T: Codable>(_ type: T.Type, forKey key: String) async throws -> T?
}

public struct Transcript: Identifiable, Codable {
    public let id: UUID
    public let text: String
    public let timestamp: Date
    public let duration: TimeInterval
    public let engineType: SpeechEngineType

    public init(id: UUID = UUID(), text: String, timestamp: Date = Date(), duration: TimeInterval, engineType: SpeechEngineType) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.duration = duration
        self.engineType = engineType
    }
}

// MARK: - Routing Protocol

public protocol RoutingProtocol: AnyObject {
    var activeProfile: Profile? { get }

    func detectFrontmostApp() -> AppContext
    func routeTranscript(_ transcript: String, to destination: RoutingDestination) async throws
    func applyProfile(_ profile: Profile, to transcript: String) -> String
}

public struct AppContext {
    public let bundleIdentifier: String
    public let name: String
    public let icon: Data?

    public init(bundleIdentifier: String, name: String, icon: Data? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.icon = icon
    }
}

public enum RoutingDestination {
    case clipboard
    case autoPaste
    case urlScheme(String)
    case shortcut(String)
}

public struct Profile: Identifiable, Codable {
    public let id: UUID
    public let name: String
    public let appBundleId: String?
    public let prePrompt: String?
    public let postPrompt: String?
    public let formatting: FormattingOptions
    public let routingDestination: String // Encoded RoutingDestination

    public init(id: UUID = UUID(), name: String, appBundleId: String? = nil, prePrompt: String? = nil, postPrompt: String? = nil, formatting: FormattingOptions = FormattingOptions(), routingDestination: String) {
        self.id = id
        self.name = name
        self.appBundleId = appBundleId
        self.prePrompt = prePrompt
        self.postPrompt = postPrompt
        self.formatting = formatting
        self.routingDestination = routingDestination
    }
}

public struct FormattingOptions: Codable {
    public let capitalizeSentences: Bool
    public let addPunctuation: Bool
    public let removeFillerWords: Bool
    public let paragraphBreaks: Bool

    public init(capitalizeSentences: Bool = true, addPunctuation: Bool = true, removeFillerWords: Bool = false, paragraphBreaks: Bool = false) {
        self.capitalizeSentences = capitalizeSentences
        self.addPunctuation = addPunctuation
        self.removeFillerWords = removeFillerWords
        self.paragraphBreaks = paragraphBreaks
    }
}

// MARK: - Permission Manager Protocol

public protocol PermissionManagerProtocol: AnyObject {
    var microphoneStatus: PermissionStatus { get }
    var accessibilityStatus: PermissionStatus { get }

    func requestMicrophonePermission() async -> Bool
    func requestAccessibilityPermission() async -> Bool
    func checkAllPermissions() async
}

public enum PermissionStatus {
    case notDetermined
    case authorized
    case denied
    case restricted
}

// MARK: - App State Types

public enum AppStatus {
    case idle
    case recording
    case processing
    case error
}

public enum HotkeyPressMode: String, CaseIterable, Sendable {
    case push
    case hold
    case both

    public var displayName: String {
        switch self {
        case .push:
            "Push"
        case .hold:
            "Hold"
        case .both:
            "Both"
        }
    }

    static func fromStoredValue(_ rawValue: String?) -> HotkeyPressMode {
        switch rawValue {
        case HotkeyPressMode.push.rawValue, "toggle":
            .push
        case HotkeyPressMode.hold.rawValue, "holdToTalk":
            .hold
        case HotkeyPressMode.both.rawValue:
            .both
        default:
            .push
        }
    }
}

// MARK: - App Rule

/// Represents an app-specific persona rule
public nonisolated struct AppRule: Identifiable, Codable, Sendable {
    public let id: String
    public let appBundleId: String
    public let appName: String
    public var appIcon: Data? // NSImage cached as PNG
    public var personaId: String // Which persona to use

    public init(id: String = UUID().uuidString, appBundleId: String, appName: String, appIcon: Data? = nil, personaId: String) {
        self.id = id
        self.appBundleId = appBundleId
        self.appName = appName
        self.appIcon = appIcon
        self.personaId = personaId
    }
}

// MARK: - App State

import os

public class AppState: ObservableObject {
    private let logger = Logger(subsystem: "com.flowstay.core", category: "AppState")

    @Published public var status: AppStatus = .idle
    @Published public var isRecording = false
    @Published public var isProcessing = false
    @Published public var currentTranscript = ""
    @Published public var recentTranscripts: [TranscriptItem] = []
    @Published public var errorMessage: String?
    @Published public var hasCompletedOnboarding: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
        }
    }

    @Published public var autoPasteEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoPasteEnabled, forKey: "autoPasteEnabled")
        }
    }

    @Published public var silenceTimeoutSeconds: Double {
        didSet {
            UserDefaults.standard.set(silenceTimeoutSeconds, forKey: "silenceTimeoutSeconds")
        }
    }

    /// History retention in days. 0 = unlimited.
    @Published public var historyRetentionDays: Int {
        didSet {
            UserDefaults.standard.set(historyRetentionDays, forKey: "historyRetentionDays")
        }
    }

    @Published public var launchAtLogin: Bool {
        didSet {
            setLaunchAtLogin(enabled: launchAtLogin)
        }
    }

    @Published public var personasEnabled: Bool {
        didSet {
            UserDefaults.standard.set(personasEnabled, forKey: "personasEnabled")
        }
    }

    @Published public var selectedPersonaId: String? {
        didSet {
            if let id = selectedPersonaId {
                UserDefaults.standard.set(id, forKey: "selectedPersonaId")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedPersonaId")
            }
        }
    }

    @Published public var allPersonas: [Persona] {
        didSet {
            // Save only user personas to UserDefaults
            let userPersonas = allPersonas.filter { !$0.isBuiltIn }
            do {
                let encoded = try JSONEncoder().encode(userPersonas)
                UserDefaults.standard.set(encoded, forKey: "userPersonas")
            } catch {
                logger.error("[AppState] Failed to encode user personas: \(error.localizedDescription)")
            }
        }
    }

    @Published public var useSmartAppDetection: Bool {
        didSet {
            UserDefaults.standard.set(useSmartAppDetection, forKey: "useSmartAppDetection")
        }
    }

    @Published public var appRules: [AppRule] {
        didSet {
            do {
                let encoded = try JSONEncoder().encode(appRules)
                UserDefaults.standard.set(encoded, forKey: "appRules")
            } catch {
                logger.error("[AppState] Failed to encode app rules: \(error.localizedDescription)")
            }
        }
    }

    @Published public var showPersonaDiscardConfirmation: Bool {
        didSet {
            UserDefaults.standard.set(showPersonaDiscardConfirmation, forKey: "showPersonaDiscardConfirmation")
        }
    }

    @Published public var showPersonaDeleteConfirmation: Bool {
        didSet {
            UserDefaults.standard.set(showPersonaDeleteConfirmation, forKey: "showPersonaDeleteConfirmation")
        }
    }

    @Published public var showAppRuleDeleteConfirmation: Bool {
        didSet {
            UserDefaults.standard.set(showAppRuleDeleteConfirmation, forKey: "showAppRuleDeleteConfirmation")
        }
    }

    @Published public var soundFeedbackEnabled: Bool {
        didSet {
            UserDefaults.standard.set(soundFeedbackEnabled, forKey: "soundFeedbackEnabled")
        }
    }

    @Published public var showOverlay: Bool {
        didSet {
            UserDefaults.standard.set(showOverlay, forKey: "showOverlay")
        }
    }

    @Published public var hotkeyPressMode: HotkeyPressMode {
        didSet {
            UserDefaults.standard.set(hotkeyPressMode.rawValue, forKey: "hotkeyPressMode")
        }
    }

    // MARK: - AI Provider Settings

    @Published public var selectedAIProviderId: String? {
        didSet {
            if let id = selectedAIProviderId {
                UserDefaults.standard.set(id, forKey: "selectedAIProviderId")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedAIProviderId")
            }
        }
    }

    @Published public var selectedOpenRouterModelId: String? {
        didSet {
            if let id = selectedOpenRouterModelId {
                UserDefaults.standard.set(id, forKey: "selectedOpenRouterModelId")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedOpenRouterModelId")
            }
        }
    }

    @Published public var selectedClaudeCodeModelId: String? {
        didSet {
            if let id = selectedClaudeCodeModelId {
                UserDefaults.standard.set(id, forKey: "selectedClaudeCodeModelId")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedClaudeCodeModelId")
            }
        }
    }

    @Published public var claudeCodeProcessingMode: String {
        didSet {
            UserDefaults.standard.set(claudeCodeProcessingMode, forKey: "claudeCodeProcessingMode")
        }
    }

    /// Get the instruction for the currently selected persona
    public var currentInstruction: String {
        guard personasEnabled else { return "" }
        guard let id = selectedPersonaId else { return "" }
        return allPersonas.first { $0.id == id }?.instruction ?? ""
    }

    /// Get persona for a specific app bundle ID
    public func getPersonaForApp(_ bundleId: String) -> String? {
        guard useSmartAppDetection else { return nil }
        return appRules.first { $0.appBundleId == bundleId }?.personaId
    }

    /// Average words per minute across recent transcripts
    public var averageWPM: Int {
        let validTranscripts = recentTranscripts.filter { $0.duration > 0 && $0.wordsPerMinute > 0 }
        guard validTranscripts.count >= 3 else { return 0 }
        let total = validTranscripts.prefix(10).reduce(0) { $0 + $1.wordsPerMinute }
        return total / min(validTranscripts.count, 10)
    }

    public init() {
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        autoPasteEnabled = UserDefaults.standard.bool(forKey: "autoPasteEnabled")
        silenceTimeoutSeconds = UserDefaults.standard.object(forKey: "silenceTimeoutSeconds") as? Double ?? 30.0
        historyRetentionDays = UserDefaults.standard.object(forKey: "historyRetentionDays") as? Int ?? 30
        launchAtLogin = SMAppService.mainApp.status == .enabled

        // Initialize personas settings
        personasEnabled = UserDefaults.standard.bool(forKey: "personasEnabled")
        useSmartAppDetection = UserDefaults.standard.bool(forKey: "useSmartAppDetection")

        // Initialize confirmation preferences (default to true)
        showPersonaDiscardConfirmation = UserDefaults.standard.object(forKey: "showPersonaDiscardConfirmation") as? Bool ?? true
        showPersonaDeleteConfirmation = UserDefaults.standard.object(forKey: "showPersonaDeleteConfirmation") as? Bool ?? true
        showAppRuleDeleteConfirmation = UserDefaults.standard.object(forKey: "showAppRuleDeleteConfirmation") as? Bool ?? true

        // Initialize sound feedback (default to true)
        soundFeedbackEnabled = UserDefaults.standard.object(forKey: "soundFeedbackEnabled") as? Bool ?? true
        showOverlay = UserDefaults.standard.object(forKey: "showOverlay") as? Bool ?? true
        hotkeyPressMode = HotkeyPressMode.fromStoredValue(UserDefaults.standard.string(forKey: "hotkeyPressMode"))

        // Load built-in personas
        var personas = Persona.builtInPresets

        // Load user personas
        if let data = UserDefaults.standard.data(forKey: "userPersonas") {
            do {
                let userPersonas = try JSONDecoder().decode([Persona].self, from: data)
                personas.append(contentsOf: userPersonas)
            } catch {
                logger.error("[AppState] Failed to decode user personas: \(error.localizedDescription)")
            }
        }

        allPersonas = personas
        selectedPersonaId = UserDefaults.standard.string(forKey: "selectedPersonaId")

        // Load app rules
        if let data = UserDefaults.standard.data(forKey: "appRules") {
            do {
                let rules = try JSONDecoder().decode([AppRule].self, from: data)
                appRules = rules
            } catch {
                logger.error("[AppState] Failed to decode app rules: \(error.localizedDescription)")
                appRules = []
            }
        } else {
            appRules = []
        }

        // Initialize AI provider settings
        selectedAIProviderId = UserDefaults.standard.string(forKey: "selectedAIProviderId")
        selectedOpenRouterModelId = UserDefaults.standard.string(forKey: "selectedOpenRouterModelId")
        selectedClaudeCodeModelId = UserDefaults.standard.string(forKey: "selectedClaudeCodeModelId")
        claudeCodeProcessingMode = UserDefaults.standard.string(forKey: "claudeCodeProcessingMode")
            ?? ClaudeCodeProcessingMode.rewriteOnly.rawValue
    }

    // MARK: - Persona Management

    public func addPersona(_ persona: Persona) {
        allPersonas.append(persona)
    }

    public func updatePersona(_ persona: Persona) {
        if let index = allPersonas.firstIndex(where: { $0.id == persona.id }) {
            allPersonas[index] = persona
        }
    }

    public func deletePersona(id: String) {
        allPersonas.removeAll { $0.id == id && !$0.isBuiltIn }
    }

    // MARK: - App Rule Management

    public func addAppRule(_ rule: AppRule) {
        // Remove existing rule for this app if it exists
        appRules.removeAll { $0.appBundleId == rule.appBundleId }
        appRules.append(rule)
    }

    public func updateAppRule(_ rule: AppRule) {
        if let index = appRules.firstIndex(where: { $0.id == rule.id }) {
            appRules[index] = rule
        }
    }

    public func deleteAppRule(id: String) {
        appRules.removeAll { $0.id == id }
    }

    private func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled {
                    logger.debug("[AppState] Launch at login already enabled")
                } else {
                    try SMAppService.mainApp.register()
                    logger.info("[AppState] Launch at login enabled")
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    logger.info("[AppState] Launch at login disabled")
                } else {
                    logger.debug("[AppState] Launch at login already disabled")
                }
            }
        } catch {
            logger.error("[AppState] Failed to set launch at login: \(error.localizedDescription)")
        }
    }
}

public struct TranscriptItem: Identifiable {
    public let id = UUID()
    public let text: String
    public let originalText: String? // Original unprocessed text (nil if not processed by persona)
    public let personaId: String? // ID of persona used for processing (nil if not processed)
    public let timestamp: Date
    public let duration: TimeInterval

    /// Returns true if this transcript was processed by a persona
    public var wasProcessed: Bool {
        originalText != nil
    }

    /// Words per minute calculation based on transcript length and duration
    public var wordsPerMinute: Int {
        guard duration > 0 else { return 0 }
        let wordCount = text.split(separator: " ").count
        let minutes = duration / 60.0
        return Int(Double(wordCount) / max(minutes, 0.1))
    }

    public init(text: String, originalText: String? = nil, personaId: String? = nil, timestamp: Date = Date(), duration: TimeInterval = 0) {
        self.text = text
        self.originalText = originalText
        self.personaId = personaId
        self.timestamp = timestamp
        self.duration = duration
    }
}

// MARK: - Error Types

public nonisolated enum FlowstayError: LocalizedError, Sendable {
    case engineNotAvailable
    case permissionDenied(String)
    case modelNotFound
    case networkError(String)
    case storageError(String)
    case routingError(String)
    case audioError(String)
    case modelDownloadFailure(String)
    case modelIntegrityViolation(String)

    public var errorDescription: String? {
        switch self {
        case .engineNotAvailable:
            "Speech engine is not available"
        case let .permissionDenied(permission):
            "Permission denied: \(permission)"
        case .modelNotFound:
            "Speech model not found"
        case let .networkError(message):
            "Network error: \(message)"
        case let .storageError(message):
            "Storage error: \(message)"
        case let .routingError(message):
            "Routing error: \(message)"
        case let .audioError(message):
            "Audio error: \(message)"
        case let .modelDownloadFailure(message):
            "Model download failed: \(message)"
        case let .modelIntegrityViolation(message):
            "Model integrity check failed: \(message)"
        }
    }
}
