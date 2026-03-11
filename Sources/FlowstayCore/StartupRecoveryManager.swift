import Darwin
import Foundation
import os

public enum StartupStage: String, Sendable {
    case launched
    case fontsRegistered
    case stateInitialized
    case uiReady
    case appInitializationStarted
    case shortcutsInitializing
    case updateInitializing
    case appInitializationCompleted
    case startupComplete
}

public struct StartupLaunchContext: Sendable {
    public let buildIdentifier: String
    public let recoveryMode: Bool
    public let crashLoopCount: Int
    public let previousIncompleteStage: StartupStage?
}

public final class StartupRecoveryManager {
    public static let shared = StartupRecoveryManager()

    private enum Keys {
        static let currentBuildIdentifier = "startupRecovery.currentBuildIdentifier"
        static let currentStage = "startupRecovery.currentStage"
        static let startupCompleted = "startupRecovery.startupCompleted"
        static let crashLoopCount = "startupRecovery.crashLoopCount"
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let bundleProvider: () -> Bundle
    private let diagnosticsDirectoryProvider: () -> URL
    private let logger = Logger(subsystem: "com.flowstay.core", category: "StartupRecovery")
    private var skippedSubsystems = Set<RecoverySkippedSubsystem>()
    private var automaticRepairs: [RecoveryAutomaticRepair] = []

    public private(set) var launchContext: StartupLaunchContext?

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        bundleProvider: @escaping () -> Bundle = { .main },
        diagnosticsDirectoryProvider: @escaping () -> URL = { FileManager.flowstayDocumentsURL }
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.bundleProvider = bundleProvider
        self.diagnosticsDirectoryProvider = diagnosticsDirectoryProvider
    }

    @MainActor
    public var isRecoveryMode: Bool {
        launchContext?.recoveryMode ?? false
    }

    @MainActor
    public var shouldSkipGlobalShortcuts: Bool {
        isRecoveryMode
    }

    @MainActor
    public var shouldSkipAutoUpdate: Bool {
        isRecoveryMode
    }

    @MainActor
    public var snapshot: StartupRecoverySnapshot {
        StartupRecoverySnapshot(
            launchContext: launchContext,
            skippedSubsystems: skippedSubsystems.sorted { $0.rawValue < $1.rawValue },
            diagnosticsLogURL: diagnosticsLogURL(),
            automaticRepairs: automaticRepairs
        )
    }

    @MainActor
    @discardableResult
    public func beginLaunch(version: String? = nil, build: String? = nil) -> StartupLaunchContext {
        skippedSubsystems.removeAll()
        automaticRepairs.removeAll()

        let bundle = bundleProvider()
        let resolvedVersion = version ?? (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "Unknown"
        let resolvedBuild = build ?? (bundle.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        let buildIdentifier = "\(resolvedVersion) (\(resolvedBuild))"

        let previousBuildIdentifier = defaults.string(forKey: Keys.currentBuildIdentifier)
        let previousStageRawValue = defaults.string(forKey: Keys.currentStage)
        let previousIncompleteStage = StartupStage(rawValue: previousStageRawValue ?? "")
        let previousStartupCompleted = defaults.bool(forKey: Keys.startupCompleted)

        let crashLoopCount: Int = if previousBuildIdentifier == buildIdentifier,
                                     !previousStartupCompleted,
                                     previousIncompleteStage != nil
        {
            defaults.integer(forKey: Keys.crashLoopCount) + 1
        } else {
            0
        }

        let context = StartupLaunchContext(
            buildIdentifier: buildIdentifier,
            recoveryMode: crashLoopCount > 0,
            crashLoopCount: crashLoopCount,
            previousIncompleteStage: previousIncompleteStage
        )

        launchContext = context
        defaults.set(buildIdentifier, forKey: Keys.currentBuildIdentifier)
        defaults.set(false, forKey: Keys.startupCompleted)
        defaults.set(StartupStage.launched.rawValue, forKey: Keys.currentStage)
        defaults.set(crashLoopCount, forKey: Keys.crashLoopCount)

        let bundlePath = bundle.bundlePath
        let translocated = bundlePath.contains("/AppTranslocation/")
        let quarantineValue = quarantineAttribute(at: bundlePath) ?? "none"
        let message =
            "begin launch build=\(buildIdentifier) recovery=\(context.recoveryMode) crashLoopCount=\(crashLoopCount) previousStage=\(previousStageRawValue ?? "none") bundlePath=\(bundlePath) translocated=\(translocated) quarantine=\(quarantineValue)"

        logger.log(level: context.recoveryMode ? .fault : .info, "[StartupRecovery] \(message, privacy: .public)")
        appendDiagnostic(message)
        return context
    }

    @MainActor
    public func markStage(_ stage: StartupStage) {
        defaults.set(stage.rawValue, forKey: Keys.currentStage)
        let message = "stage=\(stage.rawValue)"
        logger.info("[StartupRecovery] \(message, privacy: .public)")
        appendDiagnostic(message)
    }

    @MainActor
    public func markStartupComplete() {
        defaults.set(true, forKey: Keys.startupCompleted)
        defaults.set(0, forKey: Keys.crashLoopCount)
        defaults.set(StartupStage.startupComplete.rawValue, forKey: Keys.currentStage)
        let message = "startup complete"
        logger.info("[StartupRecovery] \(message, privacy: .public)")
        appendDiagnostic(message)
    }

    @MainActor
    public func markSubsystemSkipped(_ subsystem: RecoverySkippedSubsystem) {
        guard skippedSubsystems.insert(subsystem).inserted else { return }
        let message = "skipped subsystem=\(subsystem.rawValue)"
        logger.warning("[StartupRecovery] \(message, privacy: .public)")
        appendDiagnostic(message)
    }

    @MainActor
    public func recordAutomaticRepair(_ repair: RecoveryAutomaticRepair) {
        guard !automaticRepairs.contains(repair) else { return }
        automaticRepairs.append(repair)
        let message = "automatic repair \(repair.key): \(repair.title)"
        logger.warning("[StartupRecovery] \(message)")
        appendDiagnostic(message)
    }

    @MainActor
    public func clearPersistedRecoveryMarkers() {
        defaults.removeObject(forKey: Keys.currentBuildIdentifier)
        defaults.removeObject(forKey: Keys.currentStage)
        defaults.removeObject(forKey: Keys.startupCompleted)
        defaults.removeObject(forKey: Keys.crashLoopCount)
        appendDiagnostic("cleared persisted recovery markers")
    }

    @MainActor
    public func appendDiagnostic(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let path = diagnosticsLogURL()?.path else { return }
        do {
            try line.appendToFile(at: path)
        } catch {
            logger.error("[StartupRecovery] Failed to write diagnostics log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func diagnosticsLogURL() -> URL? {
        let directoryURL = diagnosticsDirectoryProvider()
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("[StartupRecovery] Failed to create diagnostics directory: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return directoryURL.appendingPathComponent("startup-diagnostics.log")
    }

    private func quarantineAttribute(at path: String) -> String? {
        let name = "com.apple.quarantine"
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: size + 1)
        let result = getxattr(path, name, &buffer, size, 0, 0)
        guard result >= 0 else { return nil }
        let bytes = buffer.prefix(Int(size)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
