import SwiftUI

struct OnboardingSceneLayoutProfile {
    let maxWidth: CGFloat
    let containerAlignment: Alignment

    static func resolve(for scene: OnboardingScene) -> OnboardingSceneLayoutProfile {
        switch scene {
        case .welcome:
            OnboardingSceneLayoutProfile(maxWidth: 560, containerAlignment: .center)
        case .readiness:
            OnboardingSceneLayoutProfile(maxWidth: 560, containerAlignment: .top)
        case .firstWin:
            OnboardingSceneLayoutProfile(maxWidth: 620, containerAlignment: .top)
        case .quickSetup:
            OnboardingSceneLayoutProfile(maxWidth: 520, containerAlignment: .center)
        case .done:
            OnboardingSceneLayoutProfile(maxWidth: 500, containerAlignment: .center)
        }
    }
}
