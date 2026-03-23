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
    case toggle
    case hold
    case both

    public var displayName: String {
        switch self {
        case .toggle:
            "Toggle"
        case .hold:
            "Hold"
        case .both:
            "Both"
        }
    }

    static func fromStoredValue(_ rawValue: String?) -> HotkeyPressMode {
        switch rawValue {
        case HotkeyPressMode.toggle.rawValue, "push":
            .toggle
        case HotkeyPressMode.hold.rawValue, "holdToTalk":
            .hold
        case HotkeyPressMode.both.rawValue:
            .both
        default:
            .both
        }
    }

    static func initialMode(storedValue: String?) -> HotkeyPressMode {
        if let storedValue {
            return fromStoredValue(storedValue)
        }
        return .both
    }
}

public enum HoldToTalkInputSource: String, CaseIterable, Sendable {
    case functionKey
    case alternativeShortcut

    public var displayName: String {
        switch self {
        case .functionKey:
            "Function key"
        case .alternativeShortcut:
            "Alternative shortcut"
        }
    }

    static func fromStoredValue(_ rawValue: String?) -> HoldToTalkInputSource {
        switch rawValue {
        case HoldToTalkInputSource.alternativeShortcut.rawValue:
            .alternativeShortcut
        case HoldToTalkInputSource.functionKey.rawValue, nil:
            .functionKey
        default:
            .functionKey
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

private final class AutomaticRepairRecorder {
    private let handler: (RecoveryAutomaticRepair) -> Void

    init(handler: @escaping (RecoveryAutomaticRepair) -> Void) {
        self.handler = handler
    }

    func record(_ repair: RecoveryAutomaticRepair) {
        handler(repair)
    }
}

public class AppState: ObservableObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.flowstay.core", category: "AppState")
    private let defaults: UserDefaults
    private let automaticRepairRecorder: AutomaticRepairRecorder

    @Published public var status: AppStatus = .idle
    @Published public var isRecording = false
    @Published public var isProcessing = false
    @Published public var currentTranscript = ""
    @Published public var recentTranscripts: [TranscriptItem] = []
    @Published public var errorMessage: String?
    @Published public var hasCompletedOnboarding: Bool {
        didSet {
            defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
        }
    }

    @Published public var autoPasteEnabled: Bool {
        didSet {
            defaults.set(autoPasteEnabled, forKey: "autoPasteEnabled")
        }
    }

    @Published public var silenceTimeoutSeconds: Double {
        didSet {
            defaults.set(silenceTimeoutSeconds, forKey: "silenceTimeoutSeconds")
        }
    }

    /// History retention in days. 0 = unlimited.
    @Published public var historyRetentionDays: Int {
        didSet {
            defaults.set(historyRetentionDays, forKey: "historyRetentionDays")
        }
    }

    @Published public var launchAtLogin: Bool {
        didSet {
            setLaunchAtLogin(enabled: launchAtLogin)
        }
    }

    @Published public var personasEnabled: Bool {
        didSet {
            defaults.set(personasEnabled, forKey: "personasEnabled")
        }
    }

    @Published public var selectedPersonaId: String? {
        didSet {
            if let id = selectedPersonaId {
                defaults.set(id, forKey: "selectedPersonaId")
            } else {
                defaults.removeObject(forKey: "selectedPersonaId")
            }
        }
    }

    @Published public var allPersonas: [Persona] {
        didSet {
            // Save only user personas to UserDefaults
            let userPersonas = allPersonas.filter { !$0.isBuiltIn }
            do {
                let encoded = try JSONEncoder().encode(userPersonas)
                defaults.set(encoded, forKey: "userPersonas")
            } catch {
                logger.error("[AppState] Failed to encode user personas: \(error.localizedDescription)")
            }
        }
    }

    @Published public var useSmartAppDetection: Bool {
        didSet {
            defaults.set(useSmartAppDetection, forKey: "useSmartAppDetection")
        }
    }

    @Published public var appRules: [AppRule] {
        didSet {
            do {
                let encoded = try JSONEncoder().encode(appRules)
                defaults.set(encoded, forKey: "appRules")
            } catch {
                logger.error("[AppState] Failed to encode app rules: \(error.localizedDescription)")
            }
        }
    }

    @Published public var showPersonaDiscardConfirmation: Bool {
        didSet {
            defaults.set(showPersonaDiscardConfirmation, forKey: "showPersonaDiscardConfirmation")
        }
    }

    @Published public var showPersonaDeleteConfirmation: Bool {
        didSet {
            defaults.set(showPersonaDeleteConfirmation, forKey: "showPersonaDeleteConfirmation")
        }
    }

    @Published public var showAppRuleDeleteConfirmation: Bool {
        didSet {
            defaults.set(showAppRuleDeleteConfirmation, forKey: "showAppRuleDeleteConfirmation")
        }
    }

    @Published public var soundFeedbackEnabled: Bool {
        didSet {
            defaults.set(soundFeedbackEnabled, forKey: "soundFeedbackEnabled")
        }
    }

    @Published public var showOverlay: Bool {
        didSet {
            defaults.set(showOverlay, forKey: "showOverlay")
        }
    }

    @Published public var hotkeyPressMode: HotkeyPressMode {
        didSet {
            defaults.set(hotkeyPressMode.rawValue, forKey: "hotkeyPressMode")
        }
    }

    @Published public var holdToTalkInputSource: HoldToTalkInputSource {
        didSet {
            defaults.set(holdToTalkInputSource.rawValue, forKey: "holdToTalkInputSource")
        }
    }

    // MARK: - AI Provider Settings

    @Published public var selectedAIProviderId: String? {
        didSet {
            if let id = selectedAIProviderId {
                defaults.set(id, forKey: "selectedAIProviderId")
            } else {
                defaults.removeObject(forKey: "selectedAIProviderId")
            }
        }
    }

    @Published public var selectedOpenRouterModelId: String? {
        didSet {
            if let id = selectedOpenRouterModelId {
                defaults.set(id, forKey: "selectedOpenRouterModelId")
            } else {
                defaults.removeObject(forKey: "selectedOpenRouterModelId")
            }
        }
    }

    @Published public var selectedClaudeCodeModelId: String? {
        didSet {
            if let id = selectedClaudeCodeModelId {
                defaults.set(id, forKey: "selectedClaudeCodeModelId")
            } else {
                defaults.removeObject(forKey: "selectedClaudeCodeModelId")
            }
        }
    }

    @Published public var claudeCodeProcessingMode: String {
        didSet {
            defaults.set(claudeCodeProcessingMode, forKey: "claudeCodeProcessingMode")
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

    public init(
        defaults: UserDefaults = .standard,
        launchAtLoginStatusProvider: @escaping () throws -> Bool = {
            SMAppService.mainApp.status == .enabled
        },
        recordAutomaticRepair: @escaping (RecoveryAutomaticRepair) -> Void = { repair in
            Task { @MainActor in
                StartupRecoveryManager.shared.recordAutomaticRepair(repair)
            }
        }
    ) {
        self.defaults = defaults
        automaticRepairRecorder = AutomaticRepairRecorder(handler: recordAutomaticRepair)

        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        autoPasteEnabled = defaults.bool(forKey: "autoPasteEnabled")
        silenceTimeoutSeconds = defaults.object(forKey: "silenceTimeoutSeconds") as? Double ?? 30.0
        historyRetentionDays = defaults.object(forKey: "historyRetentionDays") as? Int ?? 30
        launchAtLogin = Self.resolveInitialLaunchAtLogin(
            defaults: defaults,
            logger: logger,
            statusProvider: launchAtLoginStatusProvider
        )

        // Initialize personas settings
        personasEnabled = defaults.bool(forKey: "personasEnabled")
        useSmartAppDetection = defaults.bool(forKey: "useSmartAppDetection")

        // Initialize confirmation preferences (default to true)
        showPersonaDiscardConfirmation = defaults.object(forKey: "showPersonaDiscardConfirmation") as? Bool ?? true
        showPersonaDeleteConfirmation = defaults.object(forKey: "showPersonaDeleteConfirmation") as? Bool ?? true
        showAppRuleDeleteConfirmation = defaults.object(forKey: "showAppRuleDeleteConfirmation") as? Bool ?? true

        // Initialize sound feedback (default to true)
        soundFeedbackEnabled = defaults.object(forKey: "soundFeedbackEnabled") as? Bool ?? true
        showOverlay = defaults.object(forKey: "showOverlay") as? Bool ?? true

        let storedHotkeyPressMode = defaults.string(forKey: "hotkeyPressMode")
        let resolvedHotkeyPressMode = Self.resolveInitialHotkeyPressMode(defaults: defaults)
        hotkeyPressMode = resolvedHotkeyPressMode
        if storedHotkeyPressMode != resolvedHotkeyPressMode.rawValue {
            defaults.set(resolvedHotkeyPressMode.rawValue, forKey: "hotkeyPressMode")
            if let storedHotkeyPressMode {
                logger.warning("[AppState] Normalized hotkeyPressMode from \(storedHotkeyPressMode) to \(resolvedHotkeyPressMode.rawValue)")
                automaticRepairRecorder.record(
                    RecoveryAutomaticRepair(
                        key: "hotkeyPressMode",
                        title: "Normalized hotkey mode",
                        detail: "Replaced unsupported stored value \(storedHotkeyPressMode) with \(resolvedHotkeyPressMode.rawValue)."
                    )
                )
            }
        }

        let storedHoldInputSource = defaults.string(forKey: "holdToTalkInputSource")
        let resolvedHoldInputSource = HoldToTalkInputSource.fromStoredValue(storedHoldInputSource)
        holdToTalkInputSource = resolvedHoldInputSource
        if storedHoldInputSource != resolvedHoldInputSource.rawValue {
            defaults.set(resolvedHoldInputSource.rawValue, forKey: "holdToTalkInputSource")
            if let storedHoldInputSource {
                logger.warning("[AppState] Normalized holdToTalkInputSource from \(storedHoldInputSource) to \(resolvedHoldInputSource.rawValue)")
                automaticRepairRecorder.record(
                    RecoveryAutomaticRepair(
                        key: "holdToTalkInputSource",
                        title: "Normalized hold input",
                        detail: "Replaced unsupported stored value \(storedHoldInputSource) with \(resolvedHoldInputSource.rawValue)."
                    )
                )
            }
        }

        // Load built-in personas
        var personas = Persona.builtInPresets

        // Load user personas
        if let userPersonas = Self.decodeStoredValue(
            [Persona].self,
            from: defaults,
            key: "userPersonas",
            logger: logger,
            recordAutomaticRepair: automaticRepairRecorder.record
        ) {
            personas.append(contentsOf: userPersonas)
        }

        allPersonas = personas
        let storedSelectedPersonaId = defaults.string(forKey: "selectedPersonaId")
        if let storedSelectedPersonaId,
           personas.contains(where: { $0.id == storedSelectedPersonaId })
        {
            selectedPersonaId = storedSelectedPersonaId
        } else {
            selectedPersonaId = nil
            if let storedSelectedPersonaId {
                logger.warning("[AppState] Clearing stale selectedPersonaId: \(storedSelectedPersonaId)")
                defaults.removeObject(forKey: "selectedPersonaId")
                automaticRepairRecorder.record(
                    RecoveryAutomaticRepair(
                        key: "selectedPersonaId",
                        title: "Cleared stale selected persona",
                        detail: "Removed missing persona selection \(storedSelectedPersonaId)."
                    )
                )
            }
        }

        // Load app rules
        appRules = Self.decodeStoredValue(
            [AppRule].self,
            from: defaults,
            key: "appRules",
            logger: logger,
            recordAutomaticRepair: automaticRepairRecorder.record
        ) ?? []

        // Initialize AI provider settings
        selectedAIProviderId = defaults.string(forKey: "selectedAIProviderId")
        selectedOpenRouterModelId = defaults.string(forKey: "selectedOpenRouterModelId")
        selectedClaudeCodeModelId = defaults.string(forKey: "selectedClaudeCodeModelId")
        claudeCodeProcessingMode = defaults.string(forKey: "claudeCodeProcessingMode")
            ?? ClaudeCodeProcessingMode.rewriteOnly.rawValue
    }

    private static func resolveInitialHotkeyPressMode(defaults: UserDefaults) -> HotkeyPressMode {
        HotkeyPressMode.initialMode(
            storedValue: defaults.string(forKey: "hotkeyPressMode")
        )
    }

    private static func resolveInitialLaunchAtLogin(
        defaults: UserDefaults,
        logger: Logger,
        statusProvider: () throws -> Bool
    ) -> Bool {
        do {
            return try statusProvider()
        } catch {
            logger.error("[AppState] Failed to read launch at login status: \(error.localizedDescription)")
            if let storedPreference = defaults.object(forKey: "launchAtLogin") as? Bool {
                logger.warning("[AppState] Falling back to stored launchAtLogin preference: \(storedPreference)")
                return storedPreference
            }
            return false
        }
    }

    private static func decodeStoredValue<T: Decodable>(
        _ type: T.Type,
        from defaults: UserDefaults,
        key: String,
        logger: Logger,
        recordAutomaticRepair: (RecoveryAutomaticRepair) -> Void
    ) -> T? {
        let decoder = JSONDecoder()

        if let data = defaults.data(forKey: key) {
            if let decoded = try? decoder.decode(T.self, from: data) {
                return decoded
            }
        }

        if let string = defaults.string(forKey: key),
           let data = string.data(using: .utf8),
           let decoded = try? decoder.decode(T.self, from: data)
        {
            return decoded
        }

        if let object = defaults.object(forKey: key),
           JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object),
           let decoded = try? decoder.decode(T.self, from: data)
        {
            return decoded
        }

        guard defaults.object(forKey: key) != nil else {
            return nil
        }

        logger.error("[AppState] Failed to decode \(key, privacy: .public); removing persisted value")
        defaults.removeObject(forKey: key)
        recordAutomaticRepair(
            RecoveryAutomaticRepair(
                key: key,
                title: "Removed corrupt stored value",
                detail: "Failed to decode persisted value for \(key)."
            )
        )
        return nil
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
        defaults.set(enabled, forKey: "launchAtLogin")
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
