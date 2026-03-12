import Foundation

enum TutorialKeyVisualState: Equatable {
    case inactive
    case target
    case pressed
}

enum TutorialKeyVisualStatePolicy {
    static func resolve(
        tutorialStep: HotkeyTutorialStep,
        activeMode: OnboardingTutorialMode?,
        isRecording: Bool,
        isTogglePressFeedbackActive: Bool,
        isHoldPressed: Bool
    ) -> TutorialKeyVisualState {
        switch tutorialStep {
        case .toggleStartPrompt, .toggleStopPrompt, .togglePasteDemo:
            return isTogglePressFeedbackActive ? .pressed : .target

        case .toggleRecording:
            if activeMode == .toggle, isRecording {
                return .pressed
            }
            return isTogglePressFeedbackActive ? .pressed : .target

        case .holdStartPrompt, .holdReleasePrompt, .holdPasteDemo:
            return isHoldPressed ? .pressed : .target

        case .holdRecording:
            return isHoldPressed ? .pressed : .target

        case .complete:
            return .inactive
        }
    }
}
