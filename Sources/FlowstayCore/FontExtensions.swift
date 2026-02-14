import AppKit
import SwiftUI

// MARK: - Custom Fonts

public extension Font {
    /// Albert Sans font for headings
    /// Uses variable font from Google Fonts
    static func albertSans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // Map SwiftUI weight to font variant
        let fontName = switch weight {
        case .ultraLight:
            "AlbertSansRoman-Thin"
        case .thin:
            "AlbertSansRoman-ExtraLight"
        case .light:
            "AlbertSansRoman-Light"
        case .medium:
            "AlbertSansRoman-Medium"
        case .semibold:
            "AlbertSansRoman-SemiBold"
        case .bold:
            "AlbertSansRoman-Bold"
        case .heavy:
            "AlbertSansRoman-ExtraBold"
        case .black:
            "AlbertSansRoman-Black"
        default:
            "AlbertSans-Regular"
        }

        if let _ = NSFont(name: fontName, size: size) {
            return .custom(fontName, size: size, relativeTo: .body)
        } else {
            print("[FontExtensions] ⚠️ Font not found: \(fontName), using system font")
            return .system(size: size, weight: weight)
        }
    }
}
