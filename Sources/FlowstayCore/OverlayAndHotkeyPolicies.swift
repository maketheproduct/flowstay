import CoreGraphics
import Foundation

public enum HotkeyFeedbackEvent: Equatable, Sendable {
    case queued
    case accepted
    case blockedTransition
    case blockedPermissions
    case notReady
    case error
}

public struct HotkeyStartInput: Equatable, Sendable {
    public var isRecording: Bool
    public var isTransitioning: Bool
    public var isAwaitingCompletion: Bool
    public var permissionsGranted: Bool
    public var modelsDownloaded: Bool
    public var modelsReady: Bool
    public var queuedStartRequest: Bool

    public init(
        isRecording: Bool,
        isTransitioning: Bool,
        isAwaitingCompletion: Bool,
        permissionsGranted: Bool,
        modelsDownloaded: Bool,
        modelsReady: Bool,
        queuedStartRequest: Bool
    ) {
        self.isRecording = isRecording
        self.isTransitioning = isTransitioning
        self.isAwaitingCompletion = isAwaitingCompletion
        self.permissionsGranted = permissionsGranted
        self.modelsDownloaded = modelsDownloaded
        self.modelsReady = modelsReady
        self.queuedStartRequest = queuedStartRequest
    }
}

public enum HotkeyStartAction: Equatable, Sendable {
    case startRecording
    case stopRecording
    case queueWarmup
    case cancelQueuedWarmup
    case showModelGuidance
    case blocked(HotkeyFeedbackEvent)
}

public struct HotkeyStartDecision: Equatable, Sendable {
    public var actions: [HotkeyStartAction]
    public var queuedStartRequest: Bool

    public init(actions: [HotkeyStartAction], queuedStartRequest: Bool) {
        self.actions = actions
        self.queuedStartRequest = queuedStartRequest
    }
}

public enum HotkeyStartPolicy {
    public static func shouldShowStartPendingOnAccepted(
        isRecording: Bool,
        isAwaitingCompletion: Bool,
        permissionsGranted: Bool,
        modelsDownloaded: Bool
    ) -> Bool {
        !isRecording && !isAwaitingCompletion && permissionsGranted && modelsDownloaded
    }

    public static func onToggle(_ input: HotkeyStartInput) -> HotkeyStartDecision {
        if !input.permissionsGranted {
            return HotkeyStartDecision(
                actions: [.blocked(.blockedPermissions)],
                queuedStartRequest: false
            )
        }

        if input.isTransitioning {
            return HotkeyStartDecision(
                actions: [.blocked(.blockedTransition)],
                queuedStartRequest: input.queuedStartRequest
            )
        }

        if input.isAwaitingCompletion {
            return HotkeyStartDecision(
                actions: [.blocked(.blockedTransition)],
                queuedStartRequest: false
            )
        }

        if input.isRecording {
            return HotkeyStartDecision(
                actions: [.stopRecording],
                queuedStartRequest: false
            )
        }

        if input.queuedStartRequest {
            return HotkeyStartDecision(
                actions: [.cancelQueuedWarmup],
                queuedStartRequest: false
            )
        }

        guard input.modelsDownloaded else {
            return HotkeyStartDecision(
                actions: [.showModelGuidance, .blocked(.notReady)],
                queuedStartRequest: false
            )
        }

        guard input.modelsReady else {
            return HotkeyStartDecision(
                actions: [.queueWarmup, .blocked(.queued)],
                queuedStartRequest: true
            )
        }

        return HotkeyStartDecision(
            actions: [.startRecording],
            queuedStartRequest: false
        )
    }

    public static func onModelsReady(queuedStartRequest: Bool, modelsReady: Bool) -> HotkeyStartDecision {
        guard queuedStartRequest else {
            return HotkeyStartDecision(actions: [], queuedStartRequest: false)
        }

        if modelsReady {
            return HotkeyStartDecision(
                actions: [.startRecording],
                queuedStartRequest: false
            )
        }

        return HotkeyStartDecision(
            actions: [.blocked(.queued)],
            queuedStartRequest: true
        )
    }

    public static func onWarmupTimeout(queuedStartRequest: Bool) -> HotkeyStartDecision {
        guard queuedStartRequest else {
            return HotkeyStartDecision(actions: [], queuedStartRequest: false)
        }

        return HotkeyStartDecision(
            actions: [.blocked(.error)],
            queuedStartRequest: false
        )
    }
}

public enum InitializationStep: Equatable, Sendable {
    case checkPermissions
    case initializeShortcuts
    case startModelPrewarmInBackground
}

public struct InitializationExecutionPlan: Equatable, Sendable {
    public var steps: [InitializationStep]
    public var listenerReadyWithoutPrewarmCompletion: Bool

    public init(steps: [InitializationStep], listenerReadyWithoutPrewarmCompletion: Bool) {
        self.steps = steps
        self.listenerReadyWithoutPrewarmCompletion = listenerReadyWithoutPrewarmCompletion
    }
}

public enum InitializationOrderingPolicy {
    public static func makePlan(
        permissionsGranted: Bool,
        onboardingCompleted: Bool
    ) -> InitializationExecutionPlan {
        var steps: [InitializationStep] = [.checkPermissions]
        var listenerReadyWithoutPrewarmCompletion = false

        if permissionsGranted, onboardingCompleted {
            steps.append(.initializeShortcuts)
            steps.append(.startModelPrewarmInBackground)
            listenerReadyWithoutPrewarmCompletion = true
        }

        return InitializationExecutionPlan(
            steps: steps,
            listenerReadyWithoutPrewarmCompletion: listenerReadyWithoutPrewarmCompletion
        )
    }
}

public enum OverlayOutcomeState: Equatable, Sendable {
    case success
    case error
}

public enum OverlayVisibilityPhase: String, Equatable, Sendable {
    case hidden
    case recording
    case warming
    case processing
    case outcomeSuccess
    case outcomeError
}

public struct OverlayVisibilityInput: Equatable, Sendable {
    public var overlayEnabled: Bool
    public var isRecording: Bool
    public var isHotkeyStartPending: Bool
    public var isQueuedWarmup: Bool
    public var isAwaitingCompletion: Bool
    public var outcomeState: OverlayOutcomeState?
    public var outcomeVisibleUntil: Date?

    public init(
        overlayEnabled: Bool,
        isRecording: Bool,
        isHotkeyStartPending: Bool,
        isQueuedWarmup: Bool,
        isAwaitingCompletion: Bool,
        outcomeState: OverlayOutcomeState?,
        outcomeVisibleUntil: Date?
    ) {
        self.overlayEnabled = overlayEnabled
        self.isRecording = isRecording
        self.isHotkeyStartPending = isHotkeyStartPending
        self.isQueuedWarmup = isQueuedWarmup
        self.isAwaitingCompletion = isAwaitingCompletion
        self.outcomeState = outcomeState
        self.outcomeVisibleUntil = outcomeVisibleUntil
    }
}

public enum OverlayVisibilityPolicy {
    public static func resolve(_ input: OverlayVisibilityInput, now: Date = Date()) -> OverlayVisibilityPhase {
        guard input.overlayEnabled else { return .hidden }

        if input.isRecording {
            return .recording
        }

        if input.isHotkeyStartPending || input.isQueuedWarmup {
            return .warming
        }

        if input.isAwaitingCompletion {
            return .processing
        }

        if let outcomeState = input.outcomeState,
           let outcomeVisibleUntil = input.outcomeVisibleUntil,
           outcomeVisibleUntil > now
        {
            switch outcomeState {
            case .success:
                return .outcomeSuccess
            case .error:
                return .outcomeError
            }
        }

        return .hidden
    }
}

public struct OverlayTopBarMetricsInput: Equatable, Sendable {
    public var visibleTopInset: CGFloat
    public var safeAreaTopInset: CGFloat
    public var minimumHeight: CGFloat
    public var maximumHeight: CGFloat
    public var fallbackHeight: CGFloat

    public init(
        visibleTopInset: CGFloat,
        safeAreaTopInset: CGFloat,
        minimumHeight: CGFloat,
        maximumHeight: CGFloat,
        fallbackHeight: CGFloat
    ) {
        self.visibleTopInset = visibleTopInset
        self.safeAreaTopInset = safeAreaTopInset
        self.minimumHeight = minimumHeight
        self.maximumHeight = maximumHeight
        self.fallbackHeight = fallbackHeight
    }
}

public enum OverlayTopBarMetricsPolicy {
    public static func resolveHeight(_ input: OverlayTopBarMetricsInput) -> CGFloat {
        let primaryInset = max(0, input.visibleTopInset)
        let safeAreaInset = max(0, input.safeAreaTopInset)
        let fallback = max(0, input.fallbackHeight)

        let chosen = if primaryInset > 0 {
            primaryInset
        } else if safeAreaInset > 0 {
            safeAreaInset
        } else {
            fallback
        }

        return min(input.maximumHeight, max(input.minimumHeight, chosen))
    }
}

public enum OverlayAnimationTiming {
    public static let rightOutroDuration: TimeInterval = 0.26
    public static let resizeBouncePhaseOneDuration: TimeInterval = 0.13
    public static let resizeBouncePhaseTwoDuration: TimeInterval = 0.16
    public static let resizeOvershootFraction: CGFloat = 0.16
    public static let resizeReducedMotionDuration: TimeInterval = 0.16
}

public struct OverlayContainerWidthInput: Equatable, Sendable {
    public var leftSegmentWidth: CGFloat
    public var centerGapWidth: CGFloat
    public var rightSegmentWidth: CGFloat

    public init(
        leftSegmentWidth: CGFloat,
        centerGapWidth: CGFloat,
        rightSegmentWidth: CGFloat
    ) {
        self.leftSegmentWidth = leftSegmentWidth
        self.centerGapWidth = centerGapWidth
        self.rightSegmentWidth = rightSegmentWidth
    }
}

public struct OverlayContainerWidths: Equatable, Sendable {
    public var expandedWidth: CGFloat
    public var collapsedWidth: CGFloat

    public init(expandedWidth: CGFloat, collapsedWidth: CGFloat) {
        self.expandedWidth = expandedWidth
        self.collapsedWidth = collapsedWidth
    }
}

public enum OverlayContainerWidthPolicy {
    public static func resolve(_ input: OverlayContainerWidthInput) -> OverlayContainerWidths {
        let left = max(0, input.leftSegmentWidth)
        let center = max(0, input.centerGapWidth)
        let right = max(0, input.rightSegmentWidth)

        return OverlayContainerWidths(
            expandedWidth: left + center + right,
            collapsedWidth: left + center
        )
    }
}

public struct OverlayContainerAnchorInput: Equatable, Sendable {
    public var proposedExpandedOriginX: CGFloat
    public var expandedWidth: CGFloat
    public var screenMinX: CGFloat
    public var screenMaxX: CGFloat
    public var horizontalInset: CGFloat

    public init(
        proposedExpandedOriginX: CGFloat,
        expandedWidth: CGFloat,
        screenMinX: CGFloat,
        screenMaxX: CGFloat,
        horizontalInset: CGFloat
    ) {
        self.proposedExpandedOriginX = proposedExpandedOriginX
        self.expandedWidth = expandedWidth
        self.screenMinX = screenMinX
        self.screenMaxX = screenMaxX
        self.horizontalInset = horizontalInset
    }
}

public enum OverlayContainerAnchorPolicy {
    public static func resolveOriginX(_ input: OverlayContainerAnchorInput) -> CGFloat {
        let minX = input.screenMinX + input.horizontalInset
        let maxX = input.screenMaxX - input.expandedWidth - input.horizontalInset
        return min(max(input.proposedExpandedOriginX, minX), maxX)
    }
}

public enum FinalTranscriptionOutcome: Equatable, Sendable {
    case noSpeech
    case transcript(String)
}

public enum FinalTranscriptionPolicy {
    public static func classify(_ text: String) -> FinalTranscriptionOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .noSpeech
        }
        return .transcript(trimmed)
    }
}

public enum OverlayIconState: Equatable, Hashable, Sendable {
    case recording
    case warming
    case processing
    case success
    case error
    case hidden
}

public enum OverlayContainerState: Equatable, Sendable {
    case split
    case leftOnly
    case hidden
}

public struct OverlayTransitionDecision: Equatable, Sendable {
    public enum ContainerChange: Equatable, Sendable {
        case none
        case animateToSplit
        case beginRightOutro
        case collapseRightAfterOutro
        case foldLeftForHide
    }

    public var containerChange: ContainerChange
    public var iconOnlyUpdate: Bool

    public init(containerChange: ContainerChange, iconOnlyUpdate: Bool) {
        self.containerChange = containerChange
        self.iconOnlyUpdate = iconOnlyUpdate
    }
}

public enum OverlayTransitionPolicy {
    public static func decide(
        from oldIcon: OverlayIconState,
        to newIcon: OverlayIconState,
        container: OverlayContainerState,
        rightOutroCompleted: Bool
    ) -> OverlayTransitionDecision {
        if newIcon == .hidden {
            return OverlayTransitionDecision(containerChange: .foldLeftForHide, iconOnlyUpdate: false)
        }

        if oldIcon == .recording, newIcon == .processing, container == .split, !rightOutroCompleted {
            return OverlayTransitionDecision(containerChange: .beginRightOutro, iconOnlyUpdate: false)
        }

        if container == .split,
           rightOutroCompleted,
           newIcon != .recording,
           newIcon != .warming
        {
            return OverlayTransitionDecision(containerChange: .collapseRightAfterOutro, iconOnlyUpdate: false)
        }

        let iconOnlyStates: Set<OverlayIconState> = [.processing, .success, .error]
        if iconOnlyStates.contains(oldIcon), iconOnlyStates.contains(newIcon) {
            return OverlayTransitionDecision(containerChange: .none, iconOnlyUpdate: true)
        }

        if newIcon == .recording || newIcon == .warming {
            return OverlayTransitionDecision(containerChange: .animateToSplit, iconOnlyUpdate: false)
        }

        return OverlayTransitionDecision(containerChange: .none, iconOnlyUpdate: false)
    }
}
