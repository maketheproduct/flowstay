import SwiftUI

struct OnboardingKeyboardVisual: View {
    let visuals: [TutorialKeyVisual]
    let theme: OnboardingTheme

    private var visualStateByLabel: [String: TutorialKeyVisualState] {
        Dictionary(uniqueKeysWithValues: visuals.map { (normalize($0.label), $0.state) })
    }

    var body: some View {
        let layout = KeyboardClusterLayout(visualStateByLabel: visualStateByLabel)

        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.keyboardShellTop, theme.keyboardShellBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(theme.cardHighlight.opacity(0.65), lineWidth: 0.8)
                )
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(theme.cardHighlight.opacity(0.08))
                        .frame(height: 26)
                        .blur(radius: 10)
                }
                .shadow(color: theme.cardShadow.opacity(0.6), radius: 18, y: 12)

            VStack(spacing: 10) {
                if !layout.topRow.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(layout.topRow) { key in
                            KeyboardVisualKeyView(key: key, theme: theme)
                        }
                    }
                }

                HStack(spacing: 8) {
                    ForEach(layout.bottomRow) { key in
                        KeyboardVisualKeyView(key: key, theme: theme)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity)
        .frame(height: layout.height)
        .rotation3DEffect(.degrees(8), axis: (x: 1, y: 0, z: 0), perspective: 0.75)
        .compositingGroup()
    }

    private func normalize(_ label: String) -> String {
        label.lowercased().replacingOccurrences(of: " ", with: "")
    }
}

private struct KeyboardVisualKeyView: View {
    let key: KeyboardClusterKey
    let theme: OnboardingTheme

    private var fillColor: Color {
        switch key.state {
        case .inactive:
            theme.keyboardKey.opacity(key.isContext ? 0.38 : 0.58)
        case .target:
            theme.accentSoft.opacity(0.78)
        case .pressed:
            theme.keyboardKeyPressed
        }
    }

    private var strokeColor: Color {
        switch key.state {
        case .inactive:
            theme.keyboardEdge.opacity(key.isContext ? 0.28 : 0.45)
        case .target:
            theme.accent.opacity(0.72)
        case .pressed:
            theme.keyboardKeyPressed.opacity(0.98)
        }
    }

    private var textColor: Color {
        switch key.state {
        case .inactive:
            theme.primaryText.opacity(key.isContext ? 0.38 : 0.72)
        case .target:
            theme.primaryText
        case .pressed:
            .white
        }
    }

    private var glowColor: Color {
        switch key.state {
        case .inactive:
            .clear
        case .target:
            theme.accent.opacity(0.12)
        case .pressed:
            theme.accent.opacity(0.18)
        }
    }

    var body: some View {
        Text(key.label)
            .font(.system(size: key.fontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(textColor)
            .frame(width: key.width, height: key.height)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(strokeColor, lineWidth: key.state == .target ? 1.1 : 0.8)
            )
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.cardHighlight.opacity(key.state == .inactive ? 0.08 : 0.18))
                    .frame(height: 12)
                    .blur(radius: 6)
                    .padding(.horizontal, 4)
                    .padding(.top, 3)
            }
            .shadow(color: glowColor, radius: key.state == .pressed ? 14 : 10)
            .shadow(color: theme.keyboardKeyShadow.opacity(key.state == .pressed ? 0.08 : 0.18), radius: 8, y: key.state == .pressed ? 1 : 5)
            .offset(y: key.state == .pressed ? 2 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.84), value: key.state)
    }
}

private struct KeyboardClusterLayout {
    let topRow: [KeyboardClusterKey]
    let bottomRow: [KeyboardClusterKey]
    let height: CGFloat

    private static let modifierOrder = ["fn", "control", "option", "shift", "command"]
    private static let alphaStrip = ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "j", "k", "l"]

    init(visualStateByLabel: [String: TutorialKeyVisualState]) {
        let targets = Set(visualStateByLabel.keys)
        let targetNonModifier = targets.first(where: { !Self.modifierOrder.contains($0) && $0 != "space" })
        let includesSpace = targets.contains("space")

        if let targetNonModifier {
            topRow = Self.alphaRow(around: targetNonModifier, states: visualStateByLabel)
        } else {
            topRow = []
        }

        bottomRow = Self.bottomRow(
            targets: targets,
            states: visualStateByLabel,
            includesSpace: includesSpace
        )

        height = topRow.isEmpty ? 108 : 124
    }

    private static func alphaRow(
        around target: String,
        states: [String: TutorialKeyVisualState]
    ) -> [KeyboardClusterKey] {
        guard let index = alphaStrip.firstIndex(of: target) else {
            return [key(for: target, states: states, context: false)]
        }

        let left = alphaStrip[max(index - 1, 0)]
        let right = alphaStrip[min(index + 1, alphaStrip.count - 1)]

        return [
            key(for: left, states: states, context: left != target),
            key(for: target, states: states, context: false),
            key(for: right, states: states, context: right != target)
        ]
    }

    private static func bottomRow(
        targets: Set<String>,
        states: [String: TutorialKeyVisualState],
        includesSpace: Bool
    ) -> [KeyboardClusterKey] {
        var labels: [String] = []

        if targets.contains("fn") {
            labels.append("fn")
        } else if includesSpace {
            labels.append("control")
        } else {
            labels.append("fn")
        }

        for modifier in modifierOrder where targets.contains(modifier) && !labels.contains(modifier) {
            labels.append(modifier)
        }

        if includesSpace {
            if !labels.contains("command") {
                labels.append("command")
            }
            labels.append("space")
        } else if targets.isEmpty == false {
            if labels.isEmpty {
                labels.append("command")
            }
        }

        if labels.count == 1, let onlyLabel = labels.first, onlyLabel == "fn" {
            labels.append("control")
            labels.append("option")
        }

        return labels.map { key(for: $0, states: states, context: !targets.contains($0)) }
    }

    private static func key(
        for normalizedLabel: String,
        states: [String: TutorialKeyVisualState],
        context: Bool
    ) -> KeyboardClusterKey {
        KeyboardClusterKey(
            label: displayLabel(for: normalizedLabel),
            width: width(for: normalizedLabel),
            height: normalizedLabel == "space" ? 46 : 42,
            state: states[normalizedLabel] ?? .inactive,
            isContext: context
        )
    }

    private static func displayLabel(for normalizedLabel: String) -> String {
        switch normalizedLabel {
        case "fn":
            "Fn"
        case "control":
            "Control"
        case "option":
            "Option"
        case "shift":
            "Shift"
        case "command":
            "Command"
        case "space":
            "Space"
        default:
            normalizedLabel.uppercased()
        }
    }

    private static func width(for normalizedLabel: String) -> CGFloat {
        switch normalizedLabel {
        case "fn":
            62
        case "control":
            82
        case "option":
            84
        case "shift":
            90
        case "command":
            94
        case "space":
            212
        default:
            48
        }
    }
}

private struct KeyboardClusterKey: Identifiable {
    let label: String
    let width: CGFloat
    let height: CGFloat
    let state: TutorialKeyVisualState
    let isContext: Bool

    var id: String { "\(label)-\(width)" }

    var fontSize: CGFloat {
        width >= 82 ? 12 : 13
    }
}
