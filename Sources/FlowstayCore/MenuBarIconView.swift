import SwiftUI

// NOTE: MenuBarIconWrapper removed - no longer needed since we use NSStatusItem instead of MenuBarExtra
// The status bar icon is now managed directly by FlowstayAppDelegate.updateStatusIcon()

/// Menu bar icon view for SwiftUI contexts (kept for potential future use)
public struct MenuBarIconView: View {
    let isRecording: Bool
    let isProcessing: Bool

    public init(isRecording: Bool, isProcessing: Bool = false) {
        self.isRecording = isRecording
        self.isProcessing = isProcessing
    }

    public var body: some View {
        Group {
            if isProcessing {
                if #available(macOS 15.0, *) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .symbolEffect(.rotate)
                } else {
                    // Fallback for macOS 14: Manual rotation animation
                    ProcessingIconView()
                }
            } else if let logoImage = MenuBarIcon.loadIcon(isRecording: isRecording) {
                Image(nsImage: logoImage)
            } else {
                Image(systemName: MenuBarIcon.systemIconName(isRecording: isRecording))
            }
        }
        // Force view refresh when state changes
        .id("\(isRecording)-\(isProcessing)")
    }
}

struct ProcessingIconView: View {
    @State private var isRotating = false

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    isRotating = true
                }
            }
    }
}
