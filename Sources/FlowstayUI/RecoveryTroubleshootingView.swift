import AppKit
import FlowstayCore
import SwiftUI

enum RecoveryCardStyle {
    case actionable
    case limitation
    case info
}

struct RecoveryActionPresentation: Identifiable {
    let action: RecoveryAction
    let title: String
    let detail: String

    var id: String {
        action.id
    }
}

struct RecoveryPresentationCard: Identifiable {
    let id: String
    let title: String
    let message: String
    let style: RecoveryCardStyle
    let actions: [RecoveryActionPresentation]
}

@MainActor
final class RecoveryTroubleshootingViewModel: ObservableObject {
    @Published private(set) var snapshot: StartupRecoverySnapshot
    @Published private(set) var diagnostics: RecoveryDiagnostics
    @Published var statusMessage: String?
    @Published var lastReportDestination: RecoveryReportDestination?
    @Published var isShowingAdvancedDetails = false

    private let defaults: UserDefaults
    private unowned let appState: AppState

    init(
        appState: AppState,
        defaults: UserDefaults = .standard
    ) {
        self.appState = appState
        self.defaults = defaults
        let initialSnapshot = StartupRecoveryManager.shared.snapshot
        snapshot = initialSnapshot
        diagnostics = RecoveryDiagnosticsService.collect(snapshot: initialSnapshot, defaults: defaults)
    }

    var primaryTitle: String {
        autoPresentedTitle
    }

    var primaryMessage: String {
        autoPresentedMessage
    }

    var summaryRows: [(title: String, message: String)] {
        [
            (
                "What happened",
                "Flowstay had trouble finishing startup, so it opened in a safer mode for this launch."
            ),
            (
                "What is limited right now",
                temporaryLimitationsSummary
            ),
            (
                "What to do next",
                recommendedActions.isEmpty
                    ? "Restart Flowstay when you're ready to leave the safer startup mode, or share a support report if something still feels off."
                    : "Use Fix and Restart to repair the settings most likely to block a normal startup."
            ),
        ]
    }

    var actionableCards: [RecoveryPresentationCard] {
        presentedCards.filter { $0.style == .actionable }
    }

    var limitationCards: [RecoveryPresentationCard] {
        presentedCards.filter { $0.style != .actionable }
    }

    var recommendedActions: [RecoveryAction] {
        uniqueActions(from: diagnostics.highlightedChecks.filter { $0.status == .repairable })
    }

    var primaryActionTitle: String {
        recommendedActions.isEmpty ? "Restart Flowstay" : "Fix and Restart"
    }

    var canRestartNormally: Bool {
        snapshot.isDegradedLaunch || !recommendedActions.isEmpty
    }

    var additionalActions: [RecoveryActionPresentation] {
        let recommendedIDs = Set(recommendedActions.map(\.id))
        return allActionPresentations.filter { !recommendedIDs.contains($0.id) }
    }

    var advancedChecks: [RecoveryCheckResult] {
        diagnostics.highlightedChecks
    }

    var skippedSubsystemsDescription: String {
        if snapshot.skippedSubsystems.isEmpty {
            return "No startup features were paused for this launch."
        }

        return snapshot.skippedSubsystems.map(\.displayName).joined(separator: ", ")
    }

    func refresh() {
        snapshot = StartupRecoveryManager.shared.snapshot
        diagnostics = RecoveryDiagnosticsService.collect(snapshot: snapshot, defaults: defaults)
    }

    func apply(_ action: RecoveryAction) {
        _ = RecoveryRepairService.apply(action, defaults: defaults, appState: appState)
        statusMessage = friendlyCompletionMessage(for: action)
        refresh()
    }

    func applyRecommendedRepairs() {
        let actions = recommendedActions
        for action in actions {
            _ = RecoveryRepairService.apply(action, defaults: defaults, appState: appState)
        }
        _ = RecoveryRepairService.apply(.clearRecoveryMarkers, defaults: defaults, appState: appState)

        let prefix: String
        if actions.isEmpty {
            prefix = "Restarting Flowstay so it can leave the safer startup mode."
        } else {
            let count = actions.count
            let fixSummary = count == 1 ? "Applied 1 recommended fix." : "Applied \(count) recommended fixes."
            prefix = "\(fixSummary) Restarting Flowstay now."
        }

        statusMessage = prefix
        refresh()
        relaunchApplication()
    }

    func reportProblem() {
        let report = RecoveryReportBuilder.build(snapshot: snapshot, diagnostics: diagnostics)

        if let githubURL = RecoveryReportBuilder.githubIssueURL(for: report),
           NSWorkspace.shared.open(githubURL)
        {
            lastReportDestination = .github(githubURL)
            statusMessage = "Opened a support report in GitHub with startup diagnostics."
            return
        }

        if let emailURL = RecoveryReportBuilder.emailURL(for: report),
           NSWorkspace.shared.open(emailURL)
        {
            lastReportDestination = .email(emailURL)
            statusMessage = "Opened an email draft with the startup report."
            return
        }

        do {
            let exportedURL = try RecoveryReportBuilder.export(report)
            NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
            lastReportDestination = .exportedFile(exportedURL)
            statusMessage = "Saved the startup report so you can share it manually."
        } catch {
            statusMessage = "Could not prepare a support report: \(error.localizedDescription)"
        }
    }

    private var presentedCards: [RecoveryPresentationCard] {
        diagnostics.highlightedChecks.compactMap(presentationCard(for:))
    }

    private var allActionPresentations: [RecoveryActionPresentation] {
        var presentations = uniqueActions(from: diagnostics.highlightedChecks)
            .map(actionPresentation(for:))

        let resetPresentation = actionPresentation(for: .clearRecoveryMarkers)
        if !presentations.contains(where: { $0.id == resetPresentation.id }) {
            presentations.append(resetPresentation)
        }
        return presentations
    }

    private var temporaryLimitationsSummary: String {
        guard !snapshot.skippedSubsystems.isEmpty else {
            return "A few startup protections are in place until you review the suggested fixes."
        }

        let names = userFacingSubsystemList(snapshot.skippedSubsystems)
        return "\(names) are temporarily paused for this launch so Flowstay can stay open."
    }

    private var autoPresentedTitle: String {
        autoPresentedMessage.contains("safer mode") ? "Flowstay had trouble starting" : "Fix startup issues"
    }

    private var autoPresentedMessage: String {
        "We started Flowstay in a safer mode so you can keep using the app while we check a few saved settings."
    }

    private func presentationCard(for check: RecoveryCheckResult) -> RecoveryPresentationCard? {
        switch check.id {
        case "launch-recovery":
            RecoveryPresentationCard(
                id: check.id,
                title: "Flowstay switched to a safer startup path",
                message: "We detected a startup problem from the last launch and opened with extra protections turned on.",
                style: .info,
                actions: []
            )

        case "skipped-subsystems":
            RecoveryPresentationCard(
                id: check.id,
                title: "Some features are temporarily limited",
                message: temporaryLimitationsSummary,
                style: .limitation,
                actions: []
            )

        case "automatic-repairs":
            RecoveryPresentationCard(
                id: check.id,
                title: "Flowstay already repaired a few saved settings",
                message: "We cleaned up some obviously broken startup settings automatically. You only need to act if something still looks wrong.",
                style: .info,
                actions: []
            )

        case "toggle-shortcut":
            RecoveryPresentationCard(
                id: check.id,
                title: "Your main shortcut settings look broken",
                message: "The shortcut you use to start dictation may not work correctly until it is reset.",
                style: .actionable,
                actions: check.actions.map(actionPresentation(for:))
            )

        case "hold-shortcut":
            RecoveryPresentationCard(
                id: check.id,
                title: "Hold-to-talk needs attention",
                message: "Hold-to-talk is expecting a shortcut that is missing or unreadable.",
                style: .actionable,
                actions: check.actions.map(actionPresentation(for:))
            )

        case "selected-persona":
            RecoveryPresentationCard(
                id: check.id,
                title: "A saved persona is no longer available",
                message: "Flowstay found a previously selected persona that no longer exists and can clear that choice for you.",
                style: .actionable,
                actions: check.actions.map(actionPresentation(for:))
            )

        case "user-personas":
            RecoveryPresentationCard(
                id: check.id,
                title: "Some custom personas could not be read",
                message: "One or more saved custom personas look broken and may need to be removed so startup can return to normal.",
                style: .actionable,
                actions: check.actions.map(actionPresentation(for:))
            )

        case "app-rules":
            RecoveryPresentationCard(
                id: check.id,
                title: "Some app-specific writing rules need attention",
                message: "A saved rule points to a missing persona or could not be read cleanly.",
                style: .actionable,
                actions: check.actions.map(actionPresentation(for:))
            )

        case "bundle-state":
            RecoveryPresentationCard(
                id: check.id,
                title: "This copy of Flowstay may be running from a temporary location",
                message: "That can confuse startup services after an update. If problems continue, reinstall or report the issue.",
                style: .limitation,
                actions: []
            )

        case "diagnostics-log":
            RecoveryPresentationCard(
                id: check.id,
                title: "Startup logs may be incomplete",
                message: "Flowstay could not fully confirm its startup log location for this launch.",
                style: .info,
                actions: []
            )

        default:
            RecoveryPresentationCard(
                id: check.id,
                title: check.title,
                message: check.detail,
                style: check.status == .repairable ? .actionable : .info,
                actions: check.actions.map(actionPresentation(for:))
            )
        }
    }

    private func actionPresentation(for action: RecoveryAction) -> RecoveryActionPresentation {
        switch action.kind {
        case .resetToggleShortcut:
            RecoveryActionPresentation(
                action: action,
                title: "Reset toggle shortcut",
                detail: "Restore the main dictation shortcut to the default Option-Space binding."
            )
        case .resetHoldToTalkConfiguration:
            RecoveryActionPresentation(
                action: action,
                title: "Switch hold-to-talk back to Fn",
                detail: "Clear the broken hold-to-talk shortcut and use the Function key instead."
            )
        case .clearSelectedPersona:
            RecoveryActionPresentation(
                action: action,
                title: "Clear missing persona selection",
                detail: "Remove the saved persona choice that no longer exists."
            )
        case .clearAppRules:
            RecoveryActionPresentation(
                action: action,
                title: "Remove broken custom rules",
                detail: "Delete app-specific writing rules that point to missing or unreadable personas."
            )
        case .clearUserPersonas:
            RecoveryActionPresentation(
                action: action,
                title: "Remove broken custom personas",
                detail: "Delete unreadable custom personas so Flowstay can start cleanly."
            )
        case .clearRecoveryMarkers:
            RecoveryActionPresentation(
                action: action,
                title: "Reset startup recovery state",
                detail: "Clear Flowstay's saved recovery markers so the next launch starts fresh."
            )
        }
    }

    private func friendlyCompletionMessage(for action: RecoveryAction) -> String {
        switch action.kind {
        case .resetToggleShortcut:
            "Reset the main dictation shortcut. Restart Flowstay when you're ready to leave the safer startup mode."
        case .resetHoldToTalkConfiguration:
            "Switched hold-to-talk back to the Function key. Restart Flowstay when you're ready to leave the safer startup mode."
        case .clearSelectedPersona:
            "Cleared the missing persona selection. Restart Flowstay when you're ready to leave the safer startup mode."
        case .clearAppRules:
            "Removed the broken app-specific rules. Restart Flowstay when you're ready to leave the safer startup mode."
        case .clearUserPersonas:
            "Removed the broken custom personas. Restart Flowstay when you're ready to leave the safer startup mode."
        case .clearRecoveryMarkers:
            "Startup recovery will start fresh on the next launch."
        }
    }

    private func relaunchApplication() {
        let bundlePath = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "sleep 1; /usr/bin/open -n \"$1\"",
            "relaunch",
            bundlePath,
        ]

        do {
            try process.run()
        } catch {
            statusMessage = "Applied the fixes, but Flowstay could not restart automatically: \(error.localizedDescription)"
            refresh()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func userFacingSubsystemList(_ subsystems: [RecoverySkippedSubsystem]) -> String {
        let names = subsystems.map {
            switch $0 {
            case .globalShortcuts:
                "Shortcuts"
            case .autoUpdate:
                "automatic updates"
            }
        }

        if names.count == 1 {
            return names[0]
        }

        if names.count == 2 {
            return "\(names[0]) and \(names[1])"
        }

        return names.joined(separator: ", ")
    }

    private func uniqueActions(from checks: [RecoveryCheckResult]) -> [RecoveryAction] {
        var seen = Set<String>()
        return checks
            .flatMap(\.actions)
            .filter { seen.insert($0.id).inserted }
    }
}

public struct RecoveryTroubleshootingView: View {
    @StateObject private var viewModel: RecoveryTroubleshootingViewModel
    private let autoPresented: Bool
    private let onContinue: () -> Void

    public init(
        appState: AppState,
        autoPresented: Bool,
        onContinue: @escaping () -> Void
    ) {
        self.autoPresented = autoPresented
        self.onContinue = onContinue
        _viewModel = StateObject(wrappedValue: RecoveryTroubleshootingViewModel(appState: appState))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    summaryCard
                    if !viewModel.actionableCards.isEmpty {
                        actionableSection
                    }
                    if !viewModel.limitationCards.isEmpty {
                        limitationsSection
                    }
                    if !viewModel.additionalActions.isEmpty {
                        additionalActionsSection
                    }
                    advancedDetailsSection
                }
                .padding(24)
            }

            Divider()

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
        }
        .frame(minWidth: 720, minHeight: 620)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            viewModel.refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(viewModel.primaryTitle, systemImage: "wrench.and.screwdriver.fill")
                .font(.albertSans(28, weight: .bold))
                .foregroundStyle(.primary)

            Text(autoPresented ? viewModel.primaryMessage : "Review the suggested fixes and keep the technical details tucked away unless you need them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(viewModel.summaryRows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(row.message)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(18)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var actionableSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recommended fixes")
                .font(.headline)

            ForEach(viewModel.actionableCards) { card in
                cardView(card)
            }
        }
    }

    private var limitationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What to expect for this launch")
                .font(.headline)

            ForEach(viewModel.limitationCards) { card in
                cardView(card)
            }
        }
    }

    private var additionalActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("More options")
                .font(.headline)

            ForEach(viewModel.additionalActions) { action in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(action.title)
                            .font(.subheadline.weight(.semibold))
                        Text(action.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if action.action.requiresRestart {
                            Text("Use this only if you want the next launch to start fresh.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button("Run") {
                        viewModel.apply(action.action)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var advancedDetailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(
                isExpanded: $viewModel.isShowingAdvancedDetails,
                content: {
                    VStack(alignment: .leading, spacing: 16) {
                        technicalSummary

                        if !viewModel.advancedChecks.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Technical checks")
                                    .font(.subheadline.weight(.semibold))

                                ForEach(viewModel.advancedChecks) { check in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(check.title)
                                                .font(.caption.weight(.semibold))
                                            Spacer()
                                            statusBadge(for: check.status)
                                        }
                                        Text(check.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    .padding(12)
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
                    .padding(.top, 12)
                },
                label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Advanced details")
                            .font(.headline)
                        Text("Show technical startup information and the details included in a support report.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            )
        }
    }

    private var technicalSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Technical summary")
                .font(.subheadline.weight(.semibold))

            if let context = viewModel.snapshot.launchContext {
                detailRow(label: "Build", value: context.buildIdentifier)
                detailRow(label: "Startup step", value: context.previousIncompleteStage?.rawValue ?? "unknown")
                detailRow(label: "Safer startup active", value: context.recoveryMode ? "Yes" : "No")
                detailRow(label: "Recovery count", value: "\(context.crashLoopCount)")
            }

            detailRow(label: "Paused features", value: viewModel.skippedSubsystemsDescription)

            if let logPath = viewModel.snapshot.diagnosticsLogURL?.path {
                detailRow(label: "Diagnostics log", value: logPath)
            }

            if !viewModel.snapshot.automaticRepairs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Automatic repairs already applied")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(viewModel.snapshot.automaticRepairs) { repair in
                        Text("- \(repair.title): \(repair.detail)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Need help instead?")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Report a Problem shares startup diagnostics so support can understand what happened. You can review the technical details above first if you want.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let statusMessage = viewModel.statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button("Not Now") {
                    onContinue()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Report a Problem") {
                    viewModel.reportProblem()
                }
                .buttonStyle(.bordered)

                Button(viewModel.primaryActionTitle) {
                    viewModel.applyRecommendedRepairs()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canRestartNormally)
            }
        }
    }

    private func cardView(_ card: RecoveryPresentationCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                cardBadge(for: card.style)
            }

            Text(card.message)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !card.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(card.actions) { action in
                        Button(action.title) {
                            viewModel.apply(action.action)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    private func cardBadge(for style: RecoveryCardStyle) -> some View {
        switch style {
        case .actionable:
            return AnyView(
                Text("Can fix")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.14))
                    .foregroundStyle(Color.orange)
                    .clipShape(Capsule())
            )
        case .limitation:
            return AnyView(
                Text("Temporary")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.14))
                    .foregroundStyle(Color.blue)
                    .clipShape(Capsule())
            )
        case .info:
            return AnyView(
                Text("Info")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12))
                    .foregroundStyle(.secondary)
                    .clipShape(Capsule())
            )
        }
    }

    private func statusBadge(for status: RecoveryCheckStatus) -> some View {
        Text(status.displayName)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor(for: status).opacity(0.14))
            .foregroundStyle(statusColor(for: status))
            .clipShape(Capsule())
    }

    private func statusColor(for status: RecoveryCheckStatus) -> Color {
        switch status {
        case .healthy:
            .green
        case .warning:
            .orange
        case .repairable:
            .red
        case .unknown:
            .secondary
        }
    }
}
