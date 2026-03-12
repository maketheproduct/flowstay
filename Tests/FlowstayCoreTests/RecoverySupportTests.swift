import AppKit
@testable import FlowstayCore
import KeyboardShortcuts
import XCTest

@MainActor
final class RecoverySupportTests: XCTestCase {
    private enum Keys {
        static let selectedPersonaId = "selectedPersonaId"
        static let userPersonas = "userPersonas"
        static let appRules = "appRules"
        static let holdToTalkInputSource = "holdToTalkInputSource"
        static let toggleShortcut = "KeyboardShortcuts_toggleDictation"
        static let holdShortcut = "KeyboardShortcuts_holdToTalk"
        static let unrelated = "recoverySupportTests.unrelated"
        static let currentBuildIdentifier = "startupRecovery.currentBuildIdentifier"
        static let currentStage = "startupRecovery.currentStage"
        static let startupCompleted = "startupRecovery.startupCompleted"
        static let crashLoopCount = "startupRecovery.crashLoopCount"
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var diagnosticsDirectoryURL: URL!
    private var recoveryManager: StartupRecoveryManager!

    override func setUp() async throws {
        suiteName = "RecoverySupportTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)

        diagnosticsDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoverySupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: diagnosticsDirectoryURL, withIntermediateDirectories: true)

        recoveryManager = StartupRecoveryManager(
            defaults: defaults,
            fileManager: .default,
            bundleProvider: { .main },
            diagnosticsDirectoryProvider: { [unowned self] in
                diagnosticsDirectoryURL
            }
        )
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: diagnosticsDirectoryURL)
        recoveryManager = nil
        defaults = nil
        diagnosticsDirectoryURL = nil
        suiteName = nil
    }

    func testHealthyDiagnosticsWhenStartupStateLooksNormal() {
        let snapshot = makeSnapshot()
        let diagnostics = RecoveryDiagnosticsService.collect(snapshot: snapshot, defaults: defaults)

        XCTAssertEqual(check(named: "launch-recovery", in: diagnostics)?.status, .healthy)
        XCTAssertEqual(check(named: "skipped-subsystems", in: diagnostics)?.status, .healthy)
        XCTAssertEqual(check(named: "diagnostics-log", in: diagnostics)?.status, .healthy)
        XCTAssertEqual(check(named: "toggle-shortcut", in: diagnostics)?.status, .healthy)
        XCTAssertEqual(check(named: "hold-shortcut", in: diagnostics)?.status, .healthy)
        XCTAssertEqual(check(named: "selected-persona", in: diagnostics)?.status, .healthy)
        XCTAssertEqual(check(named: "user-personas", in: diagnostics)?.status, .healthy)
        XCTAssertEqual(check(named: "app-rules", in: diagnostics)?.status, .healthy)
        XCTAssertFalse(diagnostics.hasRepairableIssues)
    }

    func testDiagnosticsFlagInvalidShortcutAndStalePersona() throws {
        defaults.set("not-json", forKey: Keys.toggleShortcut)
        defaults.set("persona-that-is-gone", forKey: Keys.selectedPersonaId)

        let snapshot = makeSnapshot(recoveryMode: true, previousStage: .shortcutsInitializing)
        let diagnostics = RecoveryDiagnosticsService.collect(snapshot: snapshot, defaults: defaults)

        let toggleCheck = try XCTUnwrap(check(named: "toggle-shortcut", in: diagnostics))
        XCTAssertEqual(toggleCheck.status, .repairable)
        XCTAssertEqual(toggleCheck.actions, [.resetToggleShortcut])

        let personaCheck = try XCTUnwrap(check(named: "selected-persona", in: diagnostics))
        XCTAssertEqual(personaCheck.status, .repairable)
        XCTAssertEqual(personaCheck.actions, [.clearSelectedPersona])
    }

    func testDiagnosticsFlagInvalidPersonaPayloadsAndBrokenRules() throws {
        defaults.set("{ definitely-not-json", forKey: Keys.userPersonas)

        let validRules = [
            AppRule(appBundleId: "com.apple.TextEdit", appName: "TextEdit", personaId: "missing-persona"),
        ]
        try defaults.set(JSONEncoder().encode(validRules), forKey: Keys.appRules)

        let diagnostics = RecoveryDiagnosticsService.collect(snapshot: makeSnapshot(), defaults: defaults)

        let personasCheck = try XCTUnwrap(check(named: "user-personas", in: diagnostics))
        XCTAssertEqual(personasCheck.status, .repairable)
        XCTAssertEqual(personasCheck.actions, [.clearUserPersonas])

        let rulesCheck = try XCTUnwrap(check(named: "app-rules", in: diagnostics))
        XCTAssertEqual(rulesCheck.status, .repairable)
        XCTAssertEqual(rulesCheck.actions, [.clearAppRules])
    }

    func testResetToggleShortcutOnlyTouchesToggleKey() throws {
        defaults.set("legacy", forKey: Keys.toggleShortcut)
        defaults.set("keep-me", forKey: Keys.unrelated)

        _ = RecoveryRepairService.apply(.resetToggleShortcut, defaults: defaults)

        let encodedShortcut = try XCTUnwrap(defaults.string(forKey: Keys.toggleShortcut))
        let shortcutData = try XCTUnwrap(encodedShortcut.data(using: .utf8))
        let shortcut = try JSONDecoder().decode(
            KeyboardShortcuts.Shortcut.self,
            from: shortcutData
        )

        XCTAssertEqual(shortcut, KeyboardShortcuts.Shortcut(.space, modifiers: [.option]))
        XCTAssertEqual(defaults.string(forKey: Keys.unrelated), "keep-me")
        XCTAssertNil(defaults.object(forKey: Keys.holdShortcut))
    }

    func testResetHoldToTalkConfigurationOnlyTouchesHoldSettings() {
        defaults.set(encodedShortcut(.h, modifiers: [.command]), forKey: Keys.toggleShortcut)
        defaults.set(encodedShortcut(.j, modifiers: [.control, .shift]), forKey: Keys.holdShortcut)
        defaults.set(HoldToTalkInputSource.alternativeShortcut.rawValue, forKey: Keys.holdToTalkInputSource)
        defaults.set("keep-me", forKey: Keys.unrelated)

        _ = RecoveryRepairService.apply(.resetHoldToTalkConfiguration, defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: Keys.toggleShortcut), encodedShortcut(.h, modifiers: [.command]))
        XCTAssertNil(defaults.object(forKey: Keys.holdShortcut))
        XCTAssertEqual(defaults.string(forKey: Keys.holdToTalkInputSource), HoldToTalkInputSource.functionKey.rawValue)
        XCTAssertEqual(defaults.string(forKey: Keys.unrelated), "keep-me")
    }

    func testClearPersonaAndRuleActionsOnlyTouchIntendedKeys() throws {
        defaults.set("old-persona", forKey: Keys.selectedPersonaId)
        try defaults.set(JSONEncoder().encode([Persona(id: "custom", name: "Custom", instruction: "Help")]), forKey: Keys.userPersonas)
        try defaults.set(
            JSONEncoder().encode([AppRule(appBundleId: "com.apple.TextEdit", appName: "TextEdit", personaId: "custom")]),
            forKey: Keys.appRules
        )
        defaults.set("keep-me", forKey: Keys.unrelated)

        _ = RecoveryRepairService.apply(.clearSelectedPersona, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: Keys.selectedPersonaId))
        XCTAssertNotNil(defaults.object(forKey: Keys.userPersonas))
        XCTAssertNotNil(defaults.object(forKey: Keys.appRules))

        _ = RecoveryRepairService.apply(.clearUserPersonas, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: Keys.userPersonas))
        XCTAssertNotNil(defaults.object(forKey: Keys.appRules))

        _ = RecoveryRepairService.apply(.clearAppRules, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: Keys.appRules))
        XCTAssertEqual(defaults.string(forKey: Keys.unrelated), "keep-me")
    }

    func testClearRecoveryMarkersOnlyTouchesRecoveryKeys() {
        defaults.set("keep-me", forKey: Keys.unrelated)
        _ = recoveryManager.beginLaunch(version: "1.5.3", build: "153")
        recoveryManager.markStage(.appInitializationStarted)

        _ = RecoveryRepairService.apply(
            .clearRecoveryMarkers,
            defaults: defaults,
            recoveryManager: recoveryManager
        )

        XCTAssertNil(defaults.object(forKey: Keys.currentBuildIdentifier))
        XCTAssertNil(defaults.object(forKey: Keys.currentStage))
        XCTAssertNil(defaults.object(forKey: Keys.startupCompleted))
        XCTAssertNil(defaults.object(forKey: Keys.crashLoopCount))
        XCTAssertEqual(defaults.string(forKey: Keys.unrelated), "keep-me")
    }

    func testReportBuilderRedactsPathsAndIncludesRecoveryContext() throws {
        let homeDirectoryPath = "/Users/tester"
        let logURL = diagnosticsDirectoryURL.appendingPathComponent("startup-diagnostics.log")
        try """
        [2026-03-06T10:00:00Z] begin launch build=1.5.3 (153) bundlePath=\(homeDirectoryPath)/Applications/Flowstay.app
        [2026-03-06T10:00:01Z] skipped subsystem=globalShortcuts
        """.write(to: logURL, atomically: true, encoding: .utf8)

        defaults.set("bad-shortcut", forKey: Keys.toggleShortcut)
        let snapshot = StartupRecoverySnapshot(
            launchContext: StartupLaunchContext(
                buildIdentifier: "1.5.3 (153)",
                recoveryMode: true,
                crashLoopCount: 1,
                previousIncompleteStage: .shortcutsInitializing
            ),
            skippedSubsystems: [.globalShortcuts, .autoUpdate],
            diagnosticsLogURL: logURL,
            automaticRepairs: [
                RecoveryAutomaticRepair(
                    key: Keys.selectedPersonaId,
                    title: "Cleared stale selected persona",
                    detail: "Removed missing persona at \(homeDirectoryPath)/Library/Preferences."
                ),
            ]
        )
        let diagnostics = RecoveryDiagnosticsService.collect(snapshot: snapshot, defaults: defaults)

        let report = RecoveryReportBuilder.build(
            snapshot: snapshot,
            diagnostics: diagnostics,
            homeDirectoryPath: homeDirectoryPath,
            operatingSystemVersion: "macOS 26.0",
            hardwareModel: "MacBookPro22,1",
            logTailLineCount: 10
        )

        XCTAssertTrue(report.body.contains("Previous incomplete startup stage: shortcutsInitializing"))
        XCTAssertTrue(report.body.contains("Global shortcuts, Automatic updates"))
        XCTAssertTrue(report.body.contains("~/Applications/Flowstay.app"))
        XCTAssertFalse(report.body.contains(homeDirectoryPath))
    }

    func testGithubIssueURLUsesBugTemplateAndPrefilledBody() throws {
        let diagnostics = RecoveryDiagnosticsService.collect(snapshot: makeSnapshot(recoveryMode: true), defaults: defaults)
        let report = RecoveryReportBuilder.build(
            snapshot: makeSnapshot(recoveryMode: true, previousStage: .launched),
            diagnostics: diagnostics,
            homeDirectoryPath: "/Users/tester",
            operatingSystemVersion: "macOS 26.0",
            hardwareModel: "MacBookPro22,1"
        )

        let url = try XCTUnwrap(RecoveryReportBuilder.githubIssueURL(for: report))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []

        XCTAssertEqual(queryItems.first(where: { $0.name == "template" })?.value, "bug_report.md")
        XCTAssertEqual(queryItems.first(where: { $0.name == "title" })?.value, report.title)
        XCTAssertEqual(queryItems.first(where: { $0.name == "body" })?.value, report.body)
    }

    private func makeSnapshot(
        recoveryMode: Bool = false,
        previousStage: StartupStage? = nil,
        skippedSubsystems: [RecoverySkippedSubsystem] = [],
        automaticRepairs: [RecoveryAutomaticRepair] = []
    ) -> StartupRecoverySnapshot {
        let logURL = diagnosticsDirectoryURL.appendingPathComponent("startup-diagnostics.log")
        try? "[2026-03-06T10:00:00Z] startup check\n".write(to: logURL, atomically: true, encoding: .utf8)

        return StartupRecoverySnapshot(
            launchContext: StartupLaunchContext(
                buildIdentifier: "1.5.3 (153)",
                recoveryMode: recoveryMode,
                crashLoopCount: recoveryMode ? 1 : 0,
                previousIncompleteStage: previousStage
            ),
            skippedSubsystems: skippedSubsystems,
            diagnosticsLogURL: logURL,
            automaticRepairs: automaticRepairs
        )
    }

    private func check(named id: String, in diagnostics: RecoveryDiagnostics) -> RecoveryCheckResult? {
        diagnostics.checks.first(where: { $0.id == id })
    }

    private func encodedShortcut(_ key: KeyboardShortcuts.Key, modifiers: NSEvent.ModifierFlags) -> String {
        let shortcut = KeyboardShortcuts.Shortcut(key, modifiers: modifiers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try? encoder.encode(shortcut)
        return String(data: data ?? Data(), encoding: .utf8) ?? ""
    }
}
