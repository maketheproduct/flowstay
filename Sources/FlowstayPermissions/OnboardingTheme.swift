import AppKit
import SwiftUI

public struct OnboardingTheme {
    public let backgroundGradientStart: Color
    public let backgroundGradientEnd: Color
    public let ambientGlow: Color
    public let surface: Color
    public let elevatedSurface: Color
    public let cardBorder: Color
    public let cardHighlight: Color
    public let primaryText: Color
    public let secondaryText: Color
    public let tertiaryText: Color
    public let accent: Color
    public let accentSoft: Color
    public let success: Color
    public let warning: Color
    public let cardShadow: Color
    public let keyboardShellTop: Color
    public let keyboardShellBottom: Color
    public let keyboardEdge: Color
    public let keyboardKey: Color
    public let keyboardKeyPressed: Color
    public let keyboardKeyShadow: Color

    public static let cardCornerRadius: CGFloat = 22

    public static func resolve(for scheme: ColorScheme) -> OnboardingTheme {
        switch scheme {
        case .dark:
            OnboardingTheme(
                backgroundGradientStart: Color(hex: "14171D"),
                backgroundGradientEnd: Color(hex: "1B2028"),
                ambientGlow: Color.white.opacity(0.05),
                surface: Color.white.opacity(0.05),
                elevatedSurface: Color.white.opacity(0.08),
                cardBorder: Color.white.opacity(0.08),
                cardHighlight: Color.white.opacity(0.12),
                primaryText: Color.white.opacity(0.96),
                secondaryText: Color.white.opacity(0.7),
                tertiaryText: Color.white.opacity(0.46),
                accent: Color.flowstayBlue,
                accentSoft: Color.flowstayBlue.opacity(0.09),
                success: Color.green.opacity(0.94),
                warning: Color.orange.opacity(0.94),
                cardShadow: Color.black.opacity(0.14),
                keyboardShellTop: Color.white.opacity(0.14),
                keyboardShellBottom: Color.white.opacity(0.09),
                keyboardEdge: Color.white.opacity(0.1),
                keyboardKey: Color.white.opacity(0.1),
                keyboardKeyPressed: Color.flowstayBlue.opacity(0.7),
                keyboardKeyShadow: Color.black.opacity(0.2)
            )
        default:
            OnboardingTheme(
                backgroundGradientStart: Color(hex: "F5F7FB"),
                backgroundGradientEnd: Color(hex: "EEF2F8"),
                ambientGlow: Color.white.opacity(0.28),
                surface: Color.white.opacity(0.46),
                elevatedSurface: Color.white.opacity(0.64),
                cardBorder: Color.black.opacity(0.05),
                cardHighlight: Color.white.opacity(0.7),
                primaryText: Color(hex: "0F172A"),
                secondaryText: Color(hex: "4F5B6B"),
                tertiaryText: Color(hex: "7B8797"),
                accent: Color.flowstayBlue,
                accentSoft: Color.flowstayBlue.opacity(0.08),
                success: Color.green.opacity(0.88),
                warning: Color.orange.opacity(0.88),
                cardShadow: Color.black.opacity(0.06),
                keyboardShellTop: Color.white.opacity(0.88),
                keyboardShellBottom: Color(hex: "E7ECF4").opacity(0.88),
                keyboardEdge: Color.black.opacity(0.06),
                keyboardKey: Color.white.opacity(0.9),
                keyboardKeyPressed: Color.flowstayBlue.opacity(0.92),
                keyboardKeyShadow: Color.black.opacity(0.12)
            )
        }
    }
}
