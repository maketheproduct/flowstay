import Combine
import Foundation

/// Focused view model for settings UI that only exposes properties needed by settings
/// Prevents unnecessary re-renders from high-frequency updates like audioLevel
@MainActor
public class SettingsViewModel: ObservableObject {
    // Only expose settings-relevant properties
    @Published public var isModelsReady: Bool = false
    @Published public var engineError: String?
    @Published public var downloadProgress: Double = 0.0
    @Published public var validTranscriptsCount: Int = 0

    public init(
        engineCoordinator: EngineCoordinatorViewModel,
        appState: AppState
    ) {
        // Subscribe to only the properties we need from engineCoordinator
        engineCoordinator.$isModelsReady
            .assign(to: &$isModelsReady)

        engineCoordinator.$engineError
            .assign(to: &$engineError)

        engineCoordinator.$downloadProgress
            .assign(to: &$downloadProgress)

        // Cache expensive transcript count computation
        appState.$recentTranscripts
            .map { transcripts in
                transcripts.count(where: { $0.duration > 0 })
            }
            .assign(to: &$validTranscriptsCount)
    }
}
