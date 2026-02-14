import AppKit
import FlowstayCore
import FlowstayUI
import os
import SwiftUI

@MainActor
final class OverlayWindowController: NSObject, NSWindowDelegate {
    private let logger = Logger(subsystem: "com.flowstay.app", category: "OverlayWindow")
    private final class OverlayPanel: NSPanel {
        weak var controller: OverlayWindowController?

        override var canBecomeKey: Bool {
            false
        }

        override var canBecomeMain: Bool {
            false
        }

        override func keyDown(with event: NSEvent) {
            if controller?.handleKeyDown(event) == true {
                return
            }
            super.keyDown(with: event)
        }
    }

    private let window: OverlayPanel

    private var currentPosition: CGPoint
    private var velocityTimer: Timer?
    private var velocity: CGPoint = .zero
    private let friction: CGFloat = 0.88
    private var dragStartOrigin: CGPoint?

    private let positionKey = "overlayWindowPosition"

    init(engineCoordinator: EngineCoordinatorViewModel) {
        currentPosition = OverlayWindowController.loadSavedPosition()

        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 52, height: 52),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        window = panel
        super.init()
        panel.controller = self

        let rootView = FlowstayUI.OverlayBubbleView(
            engineCoordinator: engineCoordinator,
            onDragStart: { [weak self] in
                self?.beginDrag()
            },
            onDragChange: { [weak self] translation in
                self?.applyDragChange(translation: translation)
            },
            onDragEnd: { [weak self] translation, predicted in
                self?.applyDragEnd(translation: translation, predicted: predicted)
            }
        )

        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting
        panel.contentView?.wantsLayer = true
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 26
        hosting.layer?.masksToBounds = true

        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
        ])

        panel.delegate = self
        setPosition(currentPosition)
    }

    func show() {
        if window.isVisible { return }
        window.alphaValue = 0
        window.orderFrontRegardless()
        animateAlpha(to: 1)
        #if DEBUG
            logger.debug("Overlay show triggered")
        #endif
    }

    func hide() {
        if !window.isVisible { return }
        animateAlpha(to: 0) { [weak self] in
            Task { @MainActor [weak self] in
                self?.window.orderOut(nil)
            }
        }
        #if DEBUG
            logger.debug("Overlay hide triggered")
        #endif
    }

    func setPosition(_ position: CGPoint) {
        let clamped = clampToVisibleFrame(position)
        currentPosition = clamped
        window.setFrameOrigin(clamped)
        savePosition(clamped)
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        let impulse: CGFloat = event.isARepeat ? 28 : 20
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "w":
            applyThrowImpulse(CGPoint(x: 0, y: impulse))
            return true
        case "a":
            applyThrowImpulse(CGPoint(x: -impulse, y: 0))
            return true
        case "s":
            applyThrowImpulse(CGPoint(x: 0, y: -impulse))
            return true
        case "d":
            applyThrowImpulse(CGPoint(x: impulse, y: 0))
            return true
        default:
            return false
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window.acceptsMouseMovedEvents = true
    }

    func windowDidResignKey(_ notification: Notification) {
        window.acceptsMouseMovedEvents = false
    }

    private func beginDrag() {
        stopThrowAnimation(snap: false)
        dragStartOrigin = currentPosition
    }

    private func applyDragChange(translation: CGSize) {
        let origin = dragStartOrigin ?? currentPosition
        let next = CGPoint(x: origin.x + translation.width, y: origin.y - translation.height)
        setPosition(next)
    }

    private func applyDragEnd(translation: CGSize, predicted: CGSize) {
        dragStartOrigin = nil

        let dx = predicted.width - translation.width
        let dy = predicted.height - translation.height
        let nextVelocity = CGPoint(x: dx * 0.35, y: -dy * 0.35)
        velocity = nextVelocity

        let speed = hypot(nextVelocity.x, nextVelocity.y)

        if speed > 0.2 {
            startThrowAnimation()
        } else {
            snapToNearestEdgeOrCorner()
            window.orderFrontRegardless()
        }
    }

    private func startThrowAnimation() {
        guard velocity != .zero else { return }

        velocityTimer?.invalidate()
        velocityTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }

                let next = CGPoint(
                    x: currentPosition.x + velocity.x,
                    y: currentPosition.y + velocity.y
                )
                setPosition(next)

                velocity = CGPoint(
                    x: velocity.x * friction,
                    y: velocity.y * friction
                )

                if abs(velocity.x) < 0.2, abs(velocity.y) < 0.2 {
                    stopThrowAnimation(snap: true)
                }
            }
        }
        RunLoop.main.add(velocityTimer!, forMode: .common)
    }

    private func stopThrowAnimation(snap: Bool) {
        velocityTimer?.invalidate()
        velocityTimer = nil
        velocity = .zero

        if snap {
            snapToNearestEdgeOrCorner()
            window.orderFrontRegardless()
        }
    }

    private func animateAlpha(to value: CGFloat, completion: (@Sendable () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = value > window.alphaValue ? 0.2 : 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = value
        }, completionHandler: completion)
    }

    private func applyThrowImpulse(_ impulse: CGPoint) {
        stopThrowAnimation(snap: false)
        velocity = CGPoint(x: velocity.x + impulse.x, y: velocity.y + impulse.y)
        startThrowAnimation()
    }

    private func clampToVisibleFrame(_ origin: CGPoint) -> CGPoint {
        guard let screen = window.screen ?? NSScreen.main else { return origin }
        let frame = screen.visibleFrame

        let width = window.frame.width
        let height = window.frame.height

        let minX = frame.minX
        let maxX = frame.maxX - width
        let minY = frame.minY
        let maxY = frame.maxY - height

        return CGPoint(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY)
        )
    }

    private func snapToNearestEdgeOrCorner() {
        let origin = currentPosition
        let target = snapTarget(from: origin)
        setPosition(target)
    }

    private func snapTarget(from origin: CGPoint) -> CGPoint {
        guard let screen = window.screen ?? NSScreen.main else { return origin }
        let frame = screen.visibleFrame
        let width = window.frame.width
        let height = window.frame.height

        let inset: CGFloat = 10
        let left = frame.minX + inset
        let right = frame.maxX - width - inset
        let bottom = frame.minY + inset
        let top = frame.maxY - height - inset

        let edges: [CGPoint] = [
            CGPoint(x: left, y: origin.y),
            CGPoint(x: right, y: origin.y),
            CGPoint(x: origin.x, y: bottom),
            CGPoint(x: origin.x, y: top),
        ]

        let corners: [CGPoint] = [
            CGPoint(x: left, y: bottom),
            CGPoint(x: left, y: top),
            CGPoint(x: right, y: bottom),
            CGPoint(x: right, y: top),
        ]

        let edgeThreshold: CGFloat = 22
        let cornerThreshold: CGFloat = 28

        let nearestCorner = corners.min { distance(origin, $0) < distance(origin, $1) }
        if let nearestCorner, distance(origin, nearestCorner) <= cornerThreshold {
            return nearestCorner
        }

        let nearestEdge = edges.min { distance(origin, $0) < distance(origin, $1) }
        if let nearestEdge, distance(origin, nearestEdge) <= edgeThreshold {
            return nearestEdge
        }

        return origin
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func savePosition(_ position: CGPoint) {
        let data = ["x": position.x, "y": position.y]
        UserDefaults.standard.set(data, forKey: positionKey)
    }

    private static func loadSavedPosition() -> CGPoint {
        guard let dict = UserDefaults.standard.dictionary(forKey: "overlayWindowPosition"),
              let x = dict["x"] as? Double,
              let y = dict["y"] as? Double
        else {
            return CGPoint(x: 80, y: 220)
        }
        return CGPoint(x: x, y: y)
    }
}
