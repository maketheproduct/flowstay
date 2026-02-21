import AppKit
import FlowstayCore
import FlowstayUI
import os
import SwiftUI

@MainActor
final class OverlayWindowController: NSObject {
    private enum Constants {
        static let initialHeight: CGFloat = 26
        static let minimumHeight: CGFloat = 24
        static let maximumHeight: CGFloat = 48
        static let fallbackHeight: CGFloat = 26
        static let bottomCornerRadius: CGFloat = 11
        static let iconSize: CGFloat = 13
        static let leftSegmentWidth: CGFloat = 34
        static let rightWaveSegmentWidth: CGFloat = 34
        static let notchPadding: CGFloat = 10
        static let nonNotchSyntheticGapWidth: CGFloat = 64
        static let horizontalInset: CGFloat = 8
        static let outcomeVisibleDuration: TimeInterval = 0.9
        static let revealDuration: TimeInterval = 0.14
        static let relocateDuration: TimeInterval = 0.18
        static let rightOutroDuration: TimeInterval = OverlayAnimationTiming.rightOutroDuration
        static let squashDuration: TimeInterval = 0.12
        static let frameEpsilon: CGFloat = 0.5
    }

    private struct Placement {
        let frame: NSRect
        let metrics: OverlayNotchSafeMetrics
    }

    private struct CachedNotchGeometry {
        let notchMinX: CGFloat
        let centerGapWidth: CGFloat
    }

    private struct TopBarMetricsResolver {
        static func resolveHeight(
            for screen: NSScreen,
            minimumHeight: CGFloat,
            maximumHeight: CGFloat,
            fallbackHeight: CGFloat
        ) -> CGFloat {
            let visibleTopInset = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
            let safeAreaTopInset: CGFloat
            if #available(macOS 12.0, *) {
                safeAreaTopInset = max(0, screen.safeAreaInsets.top)
            } else {
                safeAreaTopInset = 0
            }

            return OverlayTopBarMetricsPolicy.resolveHeight(
                OverlayTopBarMetricsInput(
                    visibleTopInset: visibleTopInset,
                    safeAreaTopInset: safeAreaTopInset,
                    minimumHeight: minimumHeight,
                    maximumHeight: maximumHeight,
                    fallbackHeight: fallbackHeight
                )
            )
        }
    }

    private let logger = Logger(subsystem: "com.flowstay.app", category: "OverlayWindow")
    private let engineCoordinator: EngineCoordinatorViewModel
    private let window: NSPanel
    private let hostingView: NSHostingView<FlowstayUI.OverlayBubbleView>
    private let presentationModel: OverlayPresentationModel

    private var displayState: OverlayDisplayState = .recording
    private var layoutMode: OverlayLayoutMode = .splitAroundNotch
    private var rightSegmentMode: OverlayRightSegmentMode = .liveWave
    private var notchSafeMetrics = OverlayNotchSafeMetrics(
        hasNotch: false,
        centerGapWidth: Constants.nonNotchSyntheticGapWidth,
        leftSegmentWidth: Constants.leftSegmentWidth,
        rightSegmentWidth: Constants.rightWaveSegmentWidth,
        height: Constants.initialHeight,
        iconSize: Constants.iconSize,
        bottomCornerRadius: Constants.bottomCornerRadius
    )
    private var restingFrame: NSRect = .zero
    private var outcomeHideWorkItem: DispatchWorkItem?
    private var rightOutroWorkItem: DispatchWorkItem?
    private var outcomeHideGeneration: Int = 0
    private var rightOutroGeneration: Int = 0
    private var frameAnimationGeneration: Int = 0
    private var anchoredScreenID: NSNumber?
    private var anchoredTopY: CGFloat?
    private var anchoredHeight: CGFloat?
    private var cachedNotchByScreenID: [NSNumber: CachedNotchGeometry] = [:]

    init(engineCoordinator: EngineCoordinatorViewModel) {
        self.engineCoordinator = engineCoordinator

        presentationModel = OverlayPresentationModel(
            displayState: .recording,
            layoutMode: .splitAroundNotch,
            rightSegmentMode: .liveWave,
            metrics: notchSafeMetrics,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )

        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: Constants.initialHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isMovableByWindowBackground = false
        window.ignoresMouseEvents = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        hostingView = NSHostingView(
            rootView: FlowstayUI.OverlayBubbleView(
                engineCoordinator: engineCoordinator,
                presentation: presentationModel
            )
        )
        hostingView.wantsLayer = true
        window.contentView = hostingView

        super.init()
    }

    func showRecording(on screen: NSScreen?) {
        cancelOutcomeHide()
        cancelRightOutro()
        primeSessionAnchor(with: screen)

        updateIconStateOnly(.recording)
        updateContainerMode(
            layout: .splitAroundNotch,
            rightSegment: .liveWave,
            on: screen,
            animated: true
        )
    }

    func showWarmup(on screen: NSScreen?) {
        cancelOutcomeHide()
        cancelRightOutro()
        primeSessionAnchor(with: screen)

        updateIconStateOnly(.warming)
        updateContainerMode(
            layout: .leftExtension,
            rightSegment: .hidden,
            on: screen,
            animated: true
        )
    }

    func showProcessing(on screen: NSScreen?) {
        cancelOutcomeHide()

        updateIconStateOnly(.processing)

        if !notchSafeMetrics.hasNotch {
            guard layoutMode != .leftExtension || rightSegmentMode != .hidden else { return }
            updateContainerMode(
                layout: .leftExtension,
                rightSegment: .hidden,
                on: screen,
                animated: true
            )
            return
        }

        if layoutMode == .splitAroundNotch {
            if rightSegmentMode == .outro {
                return
            }

            if rightSegmentMode != .hidden {
                beginRightSegmentOutro(on: screen)
                return
            }
        }

        guard layoutMode != .leftExtension || rightSegmentMode != .hidden else { return }
        updateContainerMode(
            layout: .leftExtension,
            rightSegment: .hidden,
            on: screen,
            animated: true
        )
    }

    func showOutcome(success: Bool, on screen: NSScreen?) {
        cancelOutcomeHide()

        updateIconStateOnly(success ? .success : .error)

        if !notchSafeMetrics.hasNotch {
            if layoutMode != .leftExtension || rightSegmentMode != .hidden {
                updateContainerMode(
                    layout: .leftExtension,
                    rightSegment: .hidden,
                    on: screen,
                    animated: true
                )
            }
            scheduleOutcomeHide()
            return
        }

        if layoutMode == .splitAroundNotch {
            if rightSegmentMode == .outro {
                scheduleOutcomeHide()
                return
            }

            if rightSegmentMode != .hidden {
                beginRightSegmentOutro(on: screen)
                scheduleOutcomeHide()
                return
            }
        }

        if layoutMode != .leftExtension || rightSegmentMode != .hidden {
            updateContainerMode(
                layout: .leftExtension,
                rightSegment: .hidden,
                on: screen,
                animated: true
            )
        }

        scheduleOutcomeHide()
    }

    func forceHide() {
        cancelOutcomeHide()
        cancelRightOutro()
        window.orderOut(nil)
        window.alphaValue = 0
        clearSessionAnchor()
    }

    private func cancelOutcomeHide() {
        outcomeHideGeneration += 1
        outcomeHideWorkItem?.cancel()
        outcomeHideWorkItem = nil
    }

    private func cancelRightOutro() {
        rightOutroGeneration += 1
        rightOutroWorkItem?.cancel()
        rightOutroWorkItem = nil
    }

    private func screenIdentifier(for screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    private func primeSessionAnchor(with preferredScreen: NSScreen?) {
        guard let screen = preferredScreen ?? NSScreen.main else { return }
        guard let screenID = screenIdentifier(for: screen) else { return }

        if anchoredScreenID != screenID {
            anchoredTopY = nil
            anchoredHeight = nil
        }
        anchoredScreenID = screenID
    }

    private func clearSessionAnchor() {
        anchoredScreenID = nil
        anchoredTopY = nil
        anchoredHeight = nil
    }

    private func resolveAnchoredScreen(preferredScreen: NSScreen?) -> NSScreen? {
        let canReanchor = !window.isVisible || displayState == .recording || displayState == .warming

        if canReanchor, let preferredScreen {
            primeSessionAnchor(with: preferredScreen)
        } else if anchoredScreenID == nil {
            primeSessionAnchor(with: preferredScreen)
        }

        if let anchoredScreenID,
           let anchoredScreen = NSScreen.screens.first(where: { screenIdentifier(for: $0) == anchoredScreenID })
        {
            return anchoredScreen
        }

        if let preferredScreen {
            return preferredScreen
        }

        if let mainScreen = NSScreen.main {
            return mainScreen
        }

        return NSScreen.screens.first
    }

    private func updateIconStateOnly(_ newState: OverlayDisplayState) {
        guard displayState != newState else { return }
        logger.debug("[OverlayWindow] icon transition \(String(describing: self.displayState)) -> \(String(describing: newState))")
        displayState = newState
        presentationModel.displayState = newState
    }

    private func updateContainerMode(
        layout: OverlayLayoutMode,
        rightSegment: OverlayRightSegmentMode,
        on preferredScreen: NSScreen?,
        animated: Bool
    ) {
        if layout == .splitAroundNotch, !allowsSplitExpansion(for: displayState), layoutMode != .splitAroundNotch {
            return
        }

        let layoutChanged = layoutMode != layout
        let rightSegmentChanged = rightSegmentMode != rightSegment

        if !layoutChanged, !rightSegmentChanged {
            return
        }

        logger.debug(
            "[OverlayWindow] container transition layout \(String(describing: self.layoutMode)) -> \(String(describing: layout)), right \(String(describing: self.rightSegmentMode)) -> \(String(describing: rightSegment))"
        )
        if layoutChanged {
            let nextWidthMode = layout == .splitAroundNotch ? "expanded" : "collapsed-left"
            logger.debug("[OverlayWindow] width mode -> \(nextWidthMode)")
        }
        layoutMode = layout
        rightSegmentMode = rightSegment
        presentationModel.layoutMode = layout
        presentationModel.rightSegmentMode = rightSegment

        updatePlacementIfNeeded(screen: preferredScreen, animated: animated && layoutChanged)
    }

    private func allowsSplitExpansion(for state: OverlayDisplayState) -> Bool {
        state == .recording || state == .warming
    }

    private func beginRightSegmentOutro(on preferredScreen: NSScreen?) {
        guard rightSegmentMode != .outro, rightSegmentMode != .hidden else { return }

        cancelRightOutro()
        logger.debug("[OverlayWindow] begin right segment outro")
        rightSegmentMode = .outro
        presentationModel.rightSegmentMode = .outro
        let generation = rightOutroGeneration

        // Window stays at expanded width while the SwiftUI waveform fades (0.26s).
        // After the fade, the timer fires and:
        //   1. Saves the current (expanded) frame
        //   2. Snaps layout to .leftExtension (contentWidth drops to collapsed)
        //   3. Resets window to expanded frame
        //   4. Animates window from expanded → collapsed
        // Because contentWidth (collapsed) ≤ windowWidth throughout the slide,
        // maxWidth:.infinity with .leading alignment keeps the icon pinned left.

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.rightOutroGeneration == generation else { return }
                guard self.rightSegmentMode == .outro else { return }

                let expandedFrame = self.window.frame

                // Snap layout — contentWidth drops to collapsed
                self.updateContainerMode(
                    layout: .leftExtension,
                    rightSegment: .hidden,
                    on: preferredScreen,
                    animated: false
                )

                // Slide window's right edge inward from expanded → collapsed
                let collapsedFrame = self.window.frame
                if self.frameHasMeaningfulDelta(current: expandedFrame, target: collapsedFrame) {
                    self.window.setFrame(expandedFrame, display: false)
                    self.frameAnimationGeneration += 1
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.15
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        self.window.animator().setFrame(collapsedFrame, display: true)
                    }
                }

                self.rightOutroWorkItem = nil
            }
        }

        rightOutroWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.rightOutroDuration, execute: workItem)
    }

    private func updatePlacementIfNeeded(screen preferredScreen: NSScreen?, animated: Bool) {
        guard let screen = resolveAnchoredScreen(preferredScreen: preferredScreen) else { return }

        let placement = computePlacement(for: screen, layout: layoutMode)
        notchSafeMetrics = placement.metrics
        restingFrame = placement.frame

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        presentationModel.metrics = placement.metrics
        presentationModel.reduceMotion = reduceMotion

        if !window.isVisible {
            let hasNotchRegion = placement.metrics.hasNotch
            let isLeftExtension = layoutMode == .leftExtension

            if hasNotchRegion && isLeftExtension {
                // Notch screen, leftExtension: start as 1pt sliver at right edge
                // (invisible against the notch) and slide out to the left.
                let sliverFrame = NSRect(
                    x: placement.frame.maxX - 1,
                    y: placement.frame.origin.y,
                    width: 1,
                    height: placement.frame.height
                )
                window.setFrame(sliverFrame, display: true)
                window.alphaValue = 1
                window.orderFrontRegardless()

                frameAnimationGeneration += 1
                let generation = frameAnimationGeneration
                animateWindowFrameTransition(
                    from: sliverFrame,
                    to: placement.frame,
                    reduceMotion: reduceMotion,
                    generation: generation
                )
            } else if !hasNotchRegion {
                // Non-notch screen: slide down from above the screen edge.
                let aboveFrame = NSRect(
                    x: placement.frame.origin.x,
                    y: placement.frame.origin.y + placement.frame.height,
                    width: placement.frame.width,
                    height: placement.frame.height
                )
                window.setFrame(aboveFrame, display: true)
                window.alphaValue = 0
                window.orderFrontRegardless()

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Constants.revealDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.window.animator().setFrame(placement.frame, display: true)
                    self.window.animator().alphaValue = 1
                }
            } else {
                // Notch screen, direct-to-split (rare): simple fade-in.
                window.setFrame(placement.frame, display: true)
                window.alphaValue = 0
                window.orderFrontRegardless()

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Constants.revealDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.window.animator().alphaValue = 1
                }
            }
            return
        }

        guard frameHasMeaningfulDelta(current: window.frame, target: placement.frame) else { return }
        frameAnimationGeneration += 1
        let generation = frameAnimationGeneration

        if animated {
            animateWindowFrameTransition(
                from: window.frame,
                to: placement.frame,
                reduceMotion: reduceMotion,
                generation: generation
            )
        } else {
            window.setFrame(placement.frame, display: true)
            window.alphaValue = 1
        }
    }

    private func animateWindowFrameTransition(
        from currentFrame: NSRect,
        to targetFrame: NSRect,
        reduceMotion: Bool,
        generation: Int
    ) {
        let widthDelta = abs(currentFrame.width - targetFrame.width)
        let widthChanged = widthDelta > Constants.frameEpsilon

        if widthChanged && !reduceMotion && notchSafeMetrics.hasNotch {
            logger.debug(
                "[OverlayWindow] bouncy width animation from \(self.debugFrameString(currentFrame)) to \(self.debugFrameString(targetFrame))"
            )

            let overshoot = widthDelta * OverlayAnimationTiming.resizeOvershootFraction
            let direction: CGFloat = targetFrame.width >= currentFrame.width ? 1 : -1
            var overshootFrame = targetFrame
            overshootFrame.size.width = max(1, targetFrame.width + (direction * overshoot))
            // Anchor whichever edge stays fixed between frames:
            // - Same origin.x → left pinned, right bounces (split↔leftExtension)
            // - Different origin.x → right pinned, left bounces (initial reveal)
            let anchorLeft = abs(currentFrame.origin.x - targetFrame.origin.x) < Constants.frameEpsilon
            if anchorLeft {
                overshootFrame.origin.x = targetFrame.origin.x
            } else {
                overshootFrame.origin.x = targetFrame.maxX - overshootFrame.width
            }

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = OverlayAnimationTiming.resizeBouncePhaseOneDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.window.animator().setFrame(overshootFrame, display: true)
                self.window.animator().alphaValue = 1
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.frameAnimationGeneration == generation else { return }

                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = OverlayAnimationTiming.resizeBouncePhaseTwoDuration
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        self.window.animator().setFrame(targetFrame, display: true)
                        self.window.animator().alphaValue = 1
                    }
                }
            })
            return
        }

        let profile = widthChanged ? "reduced-motion" : "standard"
        let duration = widthChanged && reduceMotion
            ? OverlayAnimationTiming.resizeReducedMotionDuration
            : Constants.relocateDuration
        logger.debug(
            "[OverlayWindow] \(profile, privacy: .public) frame animation from \(self.debugFrameString(currentFrame)) to \(self.debugFrameString(targetFrame))"
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(targetFrame, display: true)
            window.animator().alphaValue = 1
        }
    }

    private func debugFrameString(_ frame: NSRect) -> String {
        String(
            format: "x=%.2f y=%.2f w=%.2f h=%.2f",
            frame.origin.x,
            frame.origin.y,
            frame.width,
            frame.height
        )
    }

    private func frameHasMeaningfulDelta(current: NSRect, target: NSRect) -> Bool {
        abs(current.origin.x - target.origin.x) > Constants.frameEpsilon
            || abs(current.origin.y - target.origin.y) > Constants.frameEpsilon
            || abs(current.width - target.width) > Constants.frameEpsilon
            || abs(current.height - target.height) > Constants.frameEpsilon
    }

    private func scheduleOutcomeHide() {
        let generation = outcomeHideGeneration
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.outcomeHideGeneration == generation else { return }
                self.foldAndHideTowardCenter(generation: generation)
            }
        }

        outcomeHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.outcomeVisibleDuration, execute: workItem)
    }

    private func foldAndHideTowardCenter(generation: Int) {
        guard window.isVisible else { return }
        guard outcomeHideGeneration == generation else { return }
        let frame = window.frame
        let hasNotchRegion = notchSafeMetrics.hasNotch
        let targetFrame: NSRect
        let animationLabel: String

        if hasNotchRegion {
            // Retract only the left extension back into the notch region by keeping
            // the right edge fixed and shrinking width toward center-gap width.
            let notchWidth = min(frame.width, max(1, notchSafeMetrics.centerGapWidth))
            targetFrame = NSRect(
                x: frame.maxX - notchWidth,
                y: frame.origin.y,
                width: notchWidth,
                height: frame.height
            )
            animationLabel = "retract-into-notch"
        } else {
            // On non-notch screens, slide the synthetic bar upward out of the screen.
            targetFrame = NSRect(
                x: frame.origin.x,
                y: frame.origin.y + frame.height,
                width: frame.width,
                height: frame.height
            )
            animationLabel = "slide-up-hide"
        }

        logger.debug(
            "[OverlayWindow] \(animationLabel, privacy: .public) from \(self.debugFrameString(frame)) to \(self.debugFrameString(targetFrame))"
        )

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Constants.squashDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(targetFrame, display: true)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.outcomeHideGeneration == generation else { return }
                self.window.orderOut(nil)
                self.window.alphaValue = 0
                if self.restingFrame != .zero {
                    self.window.setFrame(self.restingFrame, display: false)
                }
                self.clearSessionAnchor()
            }
        })
    }

    private func computePlacement(for screen: NSScreen, layout: OverlayLayoutMode) -> Placement {
        let screenScale = max(1, screen.backingScaleFactor)
        let baseStatusBarHeight = TopBarMetricsResolver.resolveHeight(
            for: screen,
            minimumHeight: Constants.minimumHeight,
            maximumHeight: Constants.maximumHeight,
            fallbackHeight: Constants.fallbackHeight
        )
        let statusBarHeight = ceil(baseStatusBarHeight * screenScale) / screenScale

        if anchoredHeight == nil {
            anchoredHeight = statusBarHeight
        }
        let height = anchoredHeight ?? statusBarHeight

        if anchoredTopY == nil {
            let topY = (screen.frame.maxY * screenScale).rounded() / screenScale
            anchoredTopY = topY
        }
        let topY = anchoredTopY ?? screen.frame.maxY

        let leftWidth = Constants.leftSegmentWidth
        let rightWidth = Constants.rightWaveSegmentWidth

        var hasNotch = false
        var centerGap = Constants.nonNotchSyntheticGapWidth
        var originX = screen.frame.midX - ((leftWidth + centerGap + rightWidth) / 2)

        let screenID = screenIdentifier(for: screen)
        if let notchGeometry = resolveNotchGeometry(for: screen, screenID: screenID)
        {
            hasNotch = true
            centerGap = notchGeometry.centerGapWidth
            originX = notchGeometry.notchMinX - Constants.notchPadding - leftWidth
        }

        let containerWidths = OverlayContainerWidthPolicy.resolve(
            OverlayContainerWidthInput(
                leftSegmentWidth: leftWidth,
                centerGapWidth: centerGap,
                rightSegmentWidth: rightWidth
            )
        )
        let expandedWidth = containerWidths.expandedWidth
        let currentWidth = layout == .splitAroundNotch
            ? containerWidths.expandedWidth
            : containerWidths.collapsedWidth

        // Clamp origin BEFORE computing currentOriginX so both layouts
        // share the same left edge. Only width differs between them,
        // ensuring transitions animate the right edge (not the left).
        originX = OverlayContainerAnchorPolicy.resolveOriginX(
            OverlayContainerAnchorInput(
                proposedExpandedOriginX: originX,
                expandedWidth: expandedWidth,
                screenMinX: screen.frame.minX,
                screenMaxX: screen.frame.maxX,
                horizontalInset: Constants.horizontalInset
            )
        )

        let currentOriginX = originX

        let alignedOriginX = (currentOriginX * screenScale).rounded() / screenScale
        let alignedWidth = (currentWidth * screenScale).rounded() / screenScale
        let originY = topY - height
        let frame = NSRect(x: alignedOriginX, y: originY, width: alignedWidth, height: height)
        let metrics = OverlayNotchSafeMetrics(
            hasNotch: hasNotch,
            centerGapWidth: centerGap,
            leftSegmentWidth: leftWidth,
            rightSegmentWidth: rightWidth,
            height: height,
            iconSize: Constants.iconSize,
            bottomCornerRadius: Constants.bottomCornerRadius
        )

        return Placement(frame: frame, metrics: metrics)
    }

    private func resolveNotchGeometry(
        for screen: NSScreen,
        screenID: NSNumber?
    ) -> CachedNotchGeometry? {
        if #available(macOS 12.0, *),
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea
        {
            let notchMinX = leftArea.maxX
            let notchMaxX = rightArea.minX
            let notchWidth = notchMaxX - notchMinX
            if notchWidth > 0 {
                let geometry = CachedNotchGeometry(
                    notchMinX: notchMinX,
                    centerGapWidth: notchWidth + (Constants.notchPadding * 2)
                )
                if let screenID {
                    cachedNotchByScreenID[screenID] = geometry
                }
                return geometry
            }
        }

        if let screenID {
            return cachedNotchByScreenID[screenID]
        }
        return nil
    }
}
