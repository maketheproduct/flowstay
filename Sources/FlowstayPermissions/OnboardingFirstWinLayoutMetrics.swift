import CoreGraphics

struct OnboardingFirstWinLayoutMetrics {
    let stackSpacing: CGFloat
    let titleBlockHeight: CGFloat
    let keyboardHeight: CGFloat
    let transcriptHeight: CGFloat
    let footerHeight: CGFloat

    static let minTranscriptHeight: CGFloat = 72
    static let maxTranscriptHeight: CGFloat = 104
    private static let spacingCount: CGFloat = 3

    static func make(availableHeight: CGFloat) -> OnboardingFirstWinLayoutMetrics {
        let stackSpacing: CGFloat = 16
        let titleBlockHeight: CGFloat = 52
        let keyboardHeight: CGFloat = 112
        let footerHeight: CGFloat = 48

        let fixedHeight = titleBlockHeight
            + keyboardHeight
            + footerHeight
            + stackSpacing * spacingCount

        let transcriptHeight = min(
            max(availableHeight - fixedHeight, minTranscriptHeight),
            maxTranscriptHeight
        )

        return OnboardingFirstWinLayoutMetrics(
            stackSpacing: stackSpacing,
            titleBlockHeight: titleBlockHeight,
            keyboardHeight: keyboardHeight,
            transcriptHeight: transcriptHeight,
            footerHeight: footerHeight
        )
    }

    var requiredSceneContentHeight: CGFloat {
        titleBlockHeight
            + keyboardHeight
            + transcriptHeight
            + footerHeight
            + stackSpacing * Self.spacingCount
    }
}
