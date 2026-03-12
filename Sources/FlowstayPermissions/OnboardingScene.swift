import Foundation

public enum OnboardingScene: Int, CaseIterable {
    case welcome
    case readiness
    case firstWin
    case quickSetup
    case done

    public var title: String {
        switch self {
        case .welcome:
            "Welcome"
        case .readiness:
            "Installation"
        case .firstWin:
            "Learn the shortcuts"
        case .quickSetup:
            "Setup"
        case .done:
            "Done"
        }
    }

    var next: OnboardingScene? {
        OnboardingScene(rawValue: rawValue + 1)
    }

    var previous: OnboardingScene? {
        OnboardingScene(rawValue: rawValue - 1)
    }
}
