import Darwin
import Foundation
import KeyboardShortcuts

public nonisolated enum RecoveryCheckStatus: String, CaseIterable, Sendable {
    case healthy
    case warning
    case repairable
    case unknown

    public var displayName: String {
        switch self {
        case .healthy:
            "Healthy"
        case .warning:
            "Warning"
        case .repairable:
            "Repairable"
        case .unknown:
            "Unknown"
        }
    }
}

public nonisolated enum RecoverySkippedSubsystem: String, CaseIterable, Sendable, Hashable {
    case globalShortcuts
    case autoUpdate

    public var displayName: String {
        switch self {
        case .globalShortcuts:
            "Global shortcuts"
        case .autoUpdate:
            "Automatic updates"
        }
    }
}

public nonisolated struct RecoveryAutomaticRepair: Identifiable, Sendable, Hashable {
    public let key: String
    public let title: String
    public let detail: String

    public var id: String {
        "\(key):\(title)"
    }

    public init(key: String, title: String, detail: String) {
        self.key = key
        self.title = title
        self.detail = detail
    }
}

public nonisolated enum RecoveryActionKind: String, CaseIterable, Sendable, Hashable {
    case resetToggleShortcut
    case resetHoldToTalkConfiguration
    case clearSelectedPersona
    case clearAppRules
    case clearUserPersonas
    case clearRecoveryMarkers
}

public nonisolated struct RecoveryAction: Identifiable, Sendable, Hashable {
    public let kind: RecoveryActionKind
    public let title: String
    public let detail: String
    public let requiresRestart: Bool

    public var id: String {
        kind.rawValue
    }

    public init(kind: RecoveryActionKind, title: String, detail: String, requiresRestart: Bool = false) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.requiresRestart = requiresRestart
    }
}

public nonisolated struct RecoveryCheckResult: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let status: RecoveryCheckStatus
    public let actions: [RecoveryAction]

    public init(
        id: String,
        title: String,
        detail: String,
        status: RecoveryCheckStatus,
        actions: [RecoveryAction] = []
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.actions = actions
    }
}

public nonisolated struct RecoveryDiagnostics: Sendable {
    public let checks: [RecoveryCheckResult]

    public init(checks: [RecoveryCheckResult]) {
        self.checks = checks
    }

    public var hasRepairableIssues: Bool {
        checks.contains { $0.status == .repairable }
    }

    public var highlightedChecks: [RecoveryCheckResult] {
        let highlighted = checks.filter { $0.status != .healthy }
        return highlighted.isEmpty ? checks : highlighted
    }
}

public nonisolated struct StartupRecoverySnapshot: Sendable {
    public let launchContext: StartupLaunchContext?
    public let skippedSubsystems: [RecoverySkippedSubsystem]
    public let diagnosticsLogURL: URL?
    public let automaticRepairs: [RecoveryAutomaticRepair]

    public var isDegradedLaunch: Bool {
        launchContext?.recoveryMode ?? false
    }

    public init(
        launchContext: StartupLaunchContext?,
        skippedSubsystems: [RecoverySkippedSubsystem],
        diagnosticsLogURL: URL?,
        automaticRepairs: [RecoveryAutomaticRepair]
    ) {
        self.launchContext = launchContext
        self.skippedSubsystems = skippedSubsystems
        self.diagnosticsLogURL = diagnosticsLogURL
        self.automaticRepairs = automaticRepairs
    }
}

public nonisolated struct RecoveryReport: Sendable {
    public let title: String
    public let body: String
    public let exportFilename: String

    public init(title: String, body: String, exportFilename: String) {
        self.title = title
        self.body = body
        self.exportFilename = exportFilename
    }
}

public nonisolated enum RecoveryReportDestination: Sendable, Equatable {
    case github(URL)
    case email(URL)
    case exportedFile(URL)
}

private nonisolated enum RecoveryDefaultsKeys {
    static let selectedPersonaId = "selectedPersonaId"
    static let userPersonas = "userPersonas"
    static let appRules = "appRules"
    static let hotkeyPressMode = "hotkeyPressMode"
    static let holdToTalkInputSource = "holdToTalkInputSource"
    static let toggleShortcut = "KeyboardShortcuts_toggleDictation"
    static let holdShortcut = "KeyboardShortcuts_holdToTalk"
}

private nonisolated enum RecoveryStoredValueInspection<T> {
    case missing
    case valid(T)
    case invalid(String)
}

private nonisolated enum RecoveryShortcutStorageStatus {
    case missing
    case disabled
    case valid(KeyboardShortcuts.Shortcut)
    case invalid(String)
}

public enum RecoveryDiagnosticsService {
    public static func collect(
        snapshot: StartupRecoverySnapshot,
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> RecoveryDiagnostics {
        let personasInspection = inspectStoredValue([Persona].self, key: RecoveryDefaultsKeys.userPersonas, defaults: defaults)
        let availablePersonas = resolveAvailablePersonas(from: personasInspection)
        let availablePersonaIds = Set(availablePersonas.map(\.id))

        let appRulesInspection = inspectStoredValue([AppRule].self, key: RecoveryDefaultsKeys.appRules, defaults: defaults)
        let selectedPersonaId = defaults.string(forKey: RecoveryDefaultsKeys.selectedPersonaId)
        let toggleShortcutStatus = inspectShortcut(named: .toggleDictation, defaultsKey: RecoveryDefaultsKeys.toggleShortcut, defaults: defaults)
        let holdShortcutStatus = inspectShortcut(named: .holdToTalk, defaultsKey: RecoveryDefaultsKeys.holdShortcut, defaults: defaults)

        let checks = [
            launchCheck(snapshot: snapshot),
            skippedSubsystemsCheck(snapshot: snapshot),
            automaticRepairsCheck(snapshot: snapshot),
            diagnosticsLogCheck(snapshot: snapshot),
            bundleCheck(bundle: bundle),
            toggleShortcutCheck(status: toggleShortcutStatus),
            holdShortcutCheck(status: holdShortcutStatus, defaults: defaults),
            selectedPersonaCheck(selectedPersonaId: selectedPersonaId, availablePersonaIds: availablePersonaIds),
            userPersonasCheck(personasInspection),
            appRulesCheck(appRulesInspection, availablePersonaIds: availablePersonaIds),
        ]

        return RecoveryDiagnostics(checks: checks)
    }

    private static func launchCheck(snapshot: StartupRecoverySnapshot) -> RecoveryCheckResult {
        if let launchContext = snapshot.launchContext, launchContext.recoveryMode {
            let previousStage = launchContext.previousIncompleteStage?.rawValue ?? "unknown"
            return RecoveryCheckResult(
                id: "launch-recovery",
                title: "Startup recovery activated",
                detail: "Flowstay detected an incomplete startup on build \(launchContext.buildIdentifier). Previous stage: \(previousStage).",
                status: .warning
            )
        }

        return RecoveryCheckResult(
            id: "launch-recovery",
            title: "Startup recovery activated",
            detail: "Flowstay did not enter recovery mode for this launch.",
            status: .healthy
        )
    }

    private static func skippedSubsystemsCheck(snapshot: StartupRecoverySnapshot) -> RecoveryCheckResult {
        guard !snapshot.skippedSubsystems.isEmpty else {
            return RecoveryCheckResult(
                id: "skipped-subsystems",
                title: "Startup subsystems",
                detail: "No startup subsystems were skipped for this launch.",
                status: .healthy
            )
        }

        let subsystemList = snapshot.skippedSubsystems.map(\.displayName).joined(separator: ", ")
        return RecoveryCheckResult(
            id: "skipped-subsystems",
            title: "Reduced startup mode",
            detail: "Flowstay skipped \(subsystemList) for this launch to avoid another startup failure.",
            status: .warning
        )
    }

    private static func automaticRepairsCheck(snapshot: StartupRecoverySnapshot) -> RecoveryCheckResult {
        guard !snapshot.automaticRepairs.isEmpty else {
            return RecoveryCheckResult(
                id: "automatic-repairs",
                title: "Automatic startup repairs",
                detail: "No broken startup settings needed automatic repair.",
                status: .healthy
            )
        }

        let summary = snapshot.automaticRepairs
            .map { "\($0.title): \($0.detail)" }
            .joined(separator: " ")
        return RecoveryCheckResult(
            id: "automatic-repairs",
            title: "Automatic startup repairs",
            detail: summary,
            status: .warning
        )
    }

    private static func diagnosticsLogCheck(snapshot: StartupRecoverySnapshot) -> RecoveryCheckResult {
        guard let diagnosticsLogURL = snapshot.diagnosticsLogURL else {
            return RecoveryCheckResult(
                id: "diagnostics-log",
                title: "Startup diagnostics log",
                detail: "Flowstay could not resolve a diagnostics log path for this launch.",
                status: .unknown
            )
        }

        guard FileManager.default.fileExists(atPath: diagnosticsLogURL.path) else {
            return RecoveryCheckResult(
                id: "diagnostics-log",
                title: "Startup diagnostics log",
                detail: "Expected diagnostics log was not found at \(diagnosticsLogURL.path).",
                status: .warning
            )
        }

        return RecoveryCheckResult(
            id: "diagnostics-log",
            title: "Startup diagnostics log",
            detail: "Diagnostics log is available at \(diagnosticsLogURL.path).",
            status: .healthy
        )
    }

    private static func bundleCheck(bundle: Bundle) -> RecoveryCheckResult {
        let bundlePath = bundle.bundlePath
        let isTranslocated = bundlePath.contains("/AppTranslocation/")
        let quarantineValue = currentBundleQuarantineValue(bundlePath: bundlePath)

        if isTranslocated || quarantineValue != nil {
            let quarantineDetail = quarantineValue.map { " Quarantine: \($0)." } ?? ""
            return RecoveryCheckResult(
                id: "bundle-state",
                title: "Updated app bundle state",
                detail: "Bundle path: \(bundlePath). Translocated: \(isTranslocated).\(quarantineDetail)",
                status: .warning
            )
        }

        return RecoveryCheckResult(
            id: "bundle-state",
            title: "Updated app bundle state",
            detail: "Bundle path and quarantine state look normal for this launch.",
            status: .healthy
        )
    }

    private static func toggleShortcutCheck(status: RecoveryShortcutStorageStatus) -> RecoveryCheckResult {
        switch status {
        case .missing:
            RecoveryCheckResult(
                id: "toggle-shortcut",
                title: "Toggle shortcut",
                detail: "No custom toggle shortcut is stored. Flowstay can still fall back to the default Option+Space binding.",
                status: .healthy
            )
        case .disabled:
            RecoveryCheckResult(
                id: "toggle-shortcut",
                title: "Toggle shortcut",
                detail: "The toggle shortcut is explicitly disabled in stored settings.",
                status: .warning,
                actions: [.resetToggleShortcut]
            )
        case let .valid(shortcut):
            RecoveryCheckResult(
                id: "toggle-shortcut",
                title: "Toggle shortcut",
                detail: "Stored toggle shortcut decoded successfully as \(shortcut.description).",
                status: .healthy
            )
        case let .invalid(reason):
            RecoveryCheckResult(
                id: "toggle-shortcut",
                title: "Toggle shortcut",
                detail: "Stored toggle shortcut could not be decoded. \(reason)",
                status: .repairable,
                actions: [.resetToggleShortcut]
            )
        }
    }

    private static func holdShortcutCheck(
        status: RecoveryShortcutStorageStatus,
        defaults: UserDefaults
    ) -> RecoveryCheckResult {
        let holdInputSource = HoldToTalkInputSource.fromStoredValue(
            defaults.string(forKey: RecoveryDefaultsKeys.holdToTalkInputSource)
        )
        let hotkeyPressMode = HotkeyPressMode.fromStoredValue(
            defaults.string(forKey: RecoveryDefaultsKeys.hotkeyPressMode)
        )

        let requiresAlternativeShortcut =
            holdInputSource == .alternativeShortcut &&
            hotkeyPressMode != .toggle

        switch status {
        case .missing where requiresAlternativeShortcut:
            return RecoveryCheckResult(
                id: "hold-shortcut",
                title: "Hold-to-talk shortcut",
                detail: "Hold-to-talk is configured to use an alternative shortcut, but no shortcut is currently stored.",
                status: .repairable,
                actions: [.resetHoldToTalkConfiguration]
            )
        case .missing:
            return RecoveryCheckResult(
                id: "hold-shortcut",
                title: "Hold-to-talk shortcut",
                detail: "No alternative hold-to-talk shortcut is stored.",
                status: .healthy
            )
        case .disabled where requiresAlternativeShortcut:
            return RecoveryCheckResult(
                id: "hold-shortcut",
                title: "Hold-to-talk shortcut",
                detail: "The alternative hold-to-talk shortcut is disabled while hold-to-talk mode still expects one.",
                status: .repairable,
                actions: [.resetHoldToTalkConfiguration]
            )
        case .disabled:
            return RecoveryCheckResult(
                id: "hold-shortcut",
                title: "Hold-to-talk shortcut",
                detail: "The alternative hold-to-talk shortcut is explicitly disabled.",
                status: .warning,
                actions: [.resetHoldToTalkConfiguration]
            )
        case let .valid(shortcut):
            return RecoveryCheckResult(
                id: "hold-shortcut",
                title: "Hold-to-talk shortcut",
                detail: "Stored hold-to-talk shortcut decoded successfully as \(shortcut.description).",
                status: .healthy
            )
        case let .invalid(reason):
            return RecoveryCheckResult(
                id: "hold-shortcut",
                title: "Hold-to-talk shortcut",
                detail: "Stored hold-to-talk shortcut could not be decoded. \(reason)",
                status: .repairable,
                actions: [.resetHoldToTalkConfiguration]
            )
        }
    }

    private static func selectedPersonaCheck(
        selectedPersonaId: String?,
        availablePersonaIds: Set<String>
    ) -> RecoveryCheckResult {
        guard let selectedPersonaId else {
            return RecoveryCheckResult(
                id: "selected-persona",
                title: "Selected persona",
                detail: "No persisted default persona is selected.",
                status: .healthy
            )
        }

        guard availablePersonaIds.contains(selectedPersonaId) else {
            return RecoveryCheckResult(
                id: "selected-persona",
                title: "Selected persona",
                detail: "Stored selected persona \(selectedPersonaId) no longer exists.",
                status: .repairable,
                actions: [.clearSelectedPersona]
            )
        }

        return RecoveryCheckResult(
            id: "selected-persona",
            title: "Selected persona",
            detail: "Stored selected persona is valid.",
            status: .healthy
        )
    }

    private static func userPersonasCheck(
        _ inspection: RecoveryStoredValueInspection<[Persona]>
    ) -> RecoveryCheckResult {
        switch inspection {
        case .missing:
            RecoveryCheckResult(
                id: "user-personas",
                title: "User personas",
                detail: "No custom personas are stored.",
                status: .healthy
            )
        case let .valid(personas):
            RecoveryCheckResult(
                id: "user-personas",
                title: "User personas",
                detail: "Stored custom personas decoded successfully (\(personas.count) entries).",
                status: .healthy
            )
        case let .invalid(reason):
            RecoveryCheckResult(
                id: "user-personas",
                title: "User personas",
                detail: "Stored custom personas could not be decoded. \(reason)",
                status: .repairable,
                actions: [.clearUserPersonas]
            )
        }
    }

    private static func appRulesCheck(
        _ inspection: RecoveryStoredValueInspection<[AppRule]>,
        availablePersonaIds: Set<String>
    ) -> RecoveryCheckResult {
        switch inspection {
        case .missing:
            return RecoveryCheckResult(
                id: "app-rules",
                title: "App-specific persona rules",
                detail: "No app-specific persona rules are stored.",
                status: .healthy
            )
        case let .valid(appRules):
            let invalidRuleCount = appRules.count(where: {
                $0.personaId != "none" && !availablePersonaIds.contains($0.personaId)
            })

            guard invalidRuleCount > 0 else {
                return RecoveryCheckResult(
                    id: "app-rules",
                    title: "App-specific persona rules",
                    detail: "Stored app-specific persona rules decoded successfully (\(appRules.count) entries).",
                    status: .healthy
                )
            }

            return RecoveryCheckResult(
                id: "app-rules",
                title: "App-specific persona rules",
                detail: "\(invalidRuleCount) stored app-specific persona rule(s) reference persona IDs that no longer exist.",
                status: .repairable,
                actions: [.clearAppRules]
            )
        case let .invalid(reason):
            return RecoveryCheckResult(
                id: "app-rules",
                title: "App-specific persona rules",
                detail: "Stored app-specific persona rules could not be decoded. \(reason)",
                status: .repairable,
                actions: [.clearAppRules]
            )
        }
    }

    private static func inspectStoredValue<T: Decodable>(
        _ type: T.Type,
        key: String,
        defaults: UserDefaults
    ) -> RecoveryStoredValueInspection<T> {
        guard defaults.object(forKey: key) != nil else {
            return .missing
        }

        let decoder = JSONDecoder()

        if let data = defaults.data(forKey: key),
           let decoded = try? decoder.decode(T.self, from: data)
        {
            return .valid(decoded)
        }

        if let string = defaults.string(forKey: key),
           let data = string.data(using: .utf8),
           let decoded = try? decoder.decode(T.self, from: data)
        {
            return .valid(decoded)
        }

        if let object = defaults.object(forKey: key),
           JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object),
           let decoded = try? decoder.decode(T.self, from: data)
        {
            return .valid(decoded)
        }

        let storedType = if let object = defaults.object(forKey: key) {
            String(describing: Swift.type(of: object))
        } else {
            "unknown"
        }
        return .invalid("Stored value type was \(storedType).")
    }

    private static func resolveAvailablePersonas(
        from inspection: RecoveryStoredValueInspection<[Persona]>
    ) -> [Persona] {
        switch inspection {
        case let .valid(userPersonas):
            Persona.builtInPresets + userPersonas
        case .missing, .invalid:
            Persona.builtInPresets
        }
    }

    private static func inspectShortcut(
        named _: KeyboardShortcuts.Name,
        defaultsKey: String,
        defaults: UserDefaults
    ) -> RecoveryShortcutStorageStatus {
        guard let object = defaults.object(forKey: defaultsKey) else {
            return .missing
        }

        if let disabled = object as? Bool, disabled == false {
            return .disabled
        }

        guard let encoded = object as? String else {
            return .invalid("Stored shortcut value type was \(String(describing: type(of: object))).")
        }

        guard let data = encoded.data(using: .utf8) else {
            return .invalid("Stored shortcut value was not valid UTF-8.")
        }

        do {
            let shortcut = try JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: data)
            return .valid(shortcut)
        } catch {
            return .invalid("Decode failed: \(error.localizedDescription)")
        }
    }

    private static func currentBundleQuarantineValue(bundlePath: String) -> String? {
        let name = "com.apple.quarantine"
        let size = getxattr(bundlePath, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: size + 1)
        let result = getxattr(bundlePath, name, &buffer, size, 0, 0)
        guard result >= 0 else { return nil }

        let bytes = buffer.prefix(Int(size)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public enum RecoveryRepairService {
    @discardableResult
    public static func apply(
        _ action: RecoveryAction,
        defaults: UserDefaults = .standard,
        appState: AppState? = nil,
        recoveryManager: StartupRecoveryManager = .shared
    ) -> String {
        switch action.kind {
        case .resetToggleShortcut:
            storeShortcut(
                KeyboardShortcuts.Shortcut(.space, modifiers: [.option]),
                defaultsKey: RecoveryDefaultsKeys.toggleShortcut,
                shortcutName: "toggleDictation",
                defaults: defaults
            )
            return "Restored the toggle shortcut to Option+Space."

        case .resetHoldToTalkConfiguration:
            removeShortcut(
                defaultsKey: RecoveryDefaultsKeys.holdShortcut,
                shortcutName: "holdToTalk",
                defaults: defaults
            )
            defaults.set(HoldToTalkInputSource.functionKey.rawValue, forKey: RecoveryDefaultsKeys.holdToTalkInputSource)
            appState?.holdToTalkInputSource = HoldToTalkInputSource.functionKey
            return "Cleared the alternative hold-to-talk shortcut and switched hold input back to the Function key."

        case .clearSelectedPersona:
            defaults.removeObject(forKey: RecoveryDefaultsKeys.selectedPersonaId)
            appState?.selectedPersonaId = nil
            return "Cleared the stale selected persona."

        case .clearAppRules:
            defaults.removeObject(forKey: RecoveryDefaultsKeys.appRules)
            appState?.appRules = []
            return "Cleared stored app-specific persona rules."

        case .clearUserPersonas:
            defaults.removeObject(forKey: RecoveryDefaultsKeys.userPersonas)
            appState?.allPersonas = Persona.builtInPresets
            return "Cleared stored custom personas."

        case .clearRecoveryMarkers:
            recoveryManager.clearPersistedRecoveryMarkers()
            return "Cleared persisted recovery markers for future launches."
        }
    }

    private static func storeShortcut(
        _ shortcut: KeyboardShortcuts.Shortcut,
        defaultsKey: String,
        shortcutName: String,
        defaults: UserDefaults
    ) {
        guard let encodedData = try? JSONEncoder().encode(shortcut),
              let encodedString = String(data: encodedData, encoding: .utf8)
        else {
            return
        }

        defaults.set(encodedString, forKey: defaultsKey)
        postShortcutDidChangeNotification(shortcutName: shortcutName)
    }

    private static func removeShortcut(
        defaultsKey: String,
        shortcutName: String,
        defaults: UserDefaults
    ) {
        defaults.removeObject(forKey: defaultsKey)
        postShortcutDidChangeNotification(shortcutName: shortcutName)
    }

    private static func postShortcutDidChangeNotification(shortcutName: String) {
        let notificationName = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: ["name": KeyboardShortcuts.Name(shortcutName)]
        )
    }
}

public enum RecoveryReportBuilder {
    public static func build(
        snapshot: StartupRecoverySnapshot,
        diagnostics: RecoveryDiagnostics,
        bundle: Bundle = .main,
        homeDirectoryPath: String = NSHomeDirectory(),
        operatingSystemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        hardwareModel: String = currentHardwareModel(),
        logTailLineCount: Int = 40
    ) -> RecoveryReport {
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let reportTitle = "[Bug] Startup recovery mode on \(version) (\(build))"
        let highlightedChecks = diagnostics.highlightedChecks
        let failedStage = snapshot.launchContext?.previousIncompleteStage?.rawValue ?? "unknown"
        let skippedSubsystems = snapshot.skippedSubsystems.map(\.displayName).joined(separator: ", ")
        let logExcerpt = redactedLogExcerpt(
            from: snapshot.diagnosticsLogURL,
            homeDirectoryPath: homeDirectoryPath,
            lineCount: logTailLineCount
        )

        let actualBehaviorDetails: String = if highlightedChecks.isEmpty {
            "- Flowstay launched in recovery mode without an obvious local configuration fault."
        } else {
            highlightedChecks
                .map { "- [\($0.status.displayName)] \($0.title): \(redact($0.detail, homeDirectoryPath: homeDirectoryPath))" }
                .joined(separator: "\n")
        }

        let automaticRepairDetails: String = if snapshot.automaticRepairs.isEmpty {
            "- No automatic startup repairs were recorded."
        } else {
            snapshot.automaticRepairs
                .map { "- \($0.title): \(redact($0.detail, homeDirectoryPath: homeDirectoryPath))" }
                .joined(separator: "\n")
        }

        let body = """
        ## Description
        Flowstay launched in recovery mode after an incomplete startup on build \(version) (\(build)). Please review and edit anything inaccurate before submitting.

        ## Environment
        - **macOS version**: \(operatingSystemVersion)
        - **Hardware**: \(hardwareModel)
        - **Flowstay version**: \(version) (Build \(build))

        ## Steps to Reproduce
        1. Launch Flowstay.
        2. Observe that startup recovery mode opens instead of a normal launch.
        3. Describe anything that happened immediately before the last failed launch.

        ## Expected Behavior
        Flowstay should launch normally without entering recovery mode or skipping startup systems.

        ## Actual Behavior
        - Previous incomplete startup stage: \(failedStage)
        - Skipped startup subsystems: \(skippedSubsystems.isEmpty ? "none" : skippedSubsystems)
        \(actualBehaviorDetails)

        ## Screenshots/Logs
        Redacted startup diagnostics excerpt:
        ```text
        \(logExcerpt)
        ```

        ## Additional Context
        Automatic startup repairs:
        \(automaticRepairDetails)
        """

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return RecoveryReport(
            title: reportTitle,
            body: redact(body, homeDirectoryPath: homeDirectoryPath),
            exportFilename: "flowstay-recovery-report-\(timestamp).md"
        )
    }

    public static func githubIssueURL(for report: RecoveryReport) -> URL? {
        var components = URLComponents(string: "https://github.com/maketheproduct/flowstay/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.md"),
            URLQueryItem(name: "title", value: report.title),
            URLQueryItem(name: "body", value: report.body),
        ]
        return components?.url
    }

    public static func emailURL(for report: RecoveryReport) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "flowstay@maketheproduct.com"
        components.queryItems = [
            URLQueryItem(name: "subject", value: report.title),
            URLQueryItem(name: "body", value: report.body),
        ]
        return components.url
    }

    public static func export(
        _ report: RecoveryReport,
        diagnosticsDirectoryURL: URL? = nil
    ) throws -> URL {
        let directoryURL = diagnosticsDirectoryURL ?? FileManager.flowstayDocumentsURL
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent(report.exportFilename)
        try report.body.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    public static func currentHardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Unknown Mac" }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return "Unknown Mac"
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func redactedLogExcerpt(
        from url: URL?,
        homeDirectoryPath: String,
        lineCount: Int
    ) -> String {
        guard let url,
              let content = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "No startup diagnostics log was available."
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let excerpt = lines.suffix(max(lineCount, 1)).joined(separator: "\n")
        return redact(String(excerpt), homeDirectoryPath: homeDirectoryPath)
    }

    private static func redact(_ text: String, homeDirectoryPath: String) -> String {
        guard !homeDirectoryPath.isEmpty else { return text }
        return text.replacingOccurrences(of: homeDirectoryPath, with: "~")
    }
}

public extension RecoveryAction {
    static let resetToggleShortcut = RecoveryAction(
        kind: .resetToggleShortcut,
        title: "Reset toggle shortcut",
        detail: "Restore the main toggle shortcut to Option+Space."
    )

    static let resetHoldToTalkConfiguration = RecoveryAction(
        kind: .resetHoldToTalkConfiguration,
        title: "Reset hold-to-talk configuration",
        detail: "Clear the alternative hold-to-talk shortcut and switch back to the Function key."
    )

    static let clearSelectedPersona = RecoveryAction(
        kind: .clearSelectedPersona,
        title: "Clear selected persona",
        detail: "Remove a stale default persona selection."
    )

    static let clearAppRules = RecoveryAction(
        kind: .clearAppRules,
        title: "Clear app-specific persona rules",
        detail: "Remove stored app routing rules that reference missing personas."
    )

    static let clearUserPersonas = RecoveryAction(
        kind: .clearUserPersonas,
        title: "Clear custom personas",
        detail: "Remove stored custom personas that no longer decode cleanly."
    )

    static let clearRecoveryMarkers = RecoveryAction(
        kind: .clearRecoveryMarkers,
        title: "Reset recovery state",
        detail: "Clear persisted recovery markers for the next launch.",
        requiresRestart: true
    )
}
