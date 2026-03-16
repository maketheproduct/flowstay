import AppKit
import Foundation
import os

/// Utility to paste text into the currently focused application
public class TextPaster {
    private static let logger = Logger(subsystem: "com.flowstay.core", category: "TextPaster")

    /// Paste text to the currently focused application
    /// This is an async method to avoid blocking the main thread during paste operations
    @MainActor
    public static func pasteText(_ text: String) async {
        guard !text.isEmpty else { return }

        logger.debug("[TextPaster] Attempting to paste text (\(text.count) chars)")

        // Check accessibility permission first
        let hasAccessibility = AXIsProcessTrusted()
        logger.debug("[TextPaster] Accessibility permission: \(hasAccessibility ? "GRANTED" : "NOT GRANTED")")

        if !hasAccessibility {
            logger.warning("[TextPaster] Cannot paste - accessibility permission not granted. Add app to System Preferences > Privacy & Security > Accessibility")
            return
        }

        // Save current clipboard content
        let pasteboard = NSPasteboard.general
        let originalClipboard = PasteboardSnapshot.capture(from: pasteboard)

        // Put our text on the clipboard
        pasteboard.clearContents()
        let clipboardSuccess = pasteboard.setString(text, forType: .string)
        logger.debug("[TextPaster] Clipboard set success: \(clipboardSuccess)")

        guard clipboardSuccess else {
            originalClipboard.restore(to: pasteboard)
            logger.warning("[TextPaster] Failed to stage clipboard text for paste")
            return
        }

        let insertedChangeCount = pasteboard.changeCount

        // Verify clipboard content
        let clipboardSet = pasteboard.string(forType: .string) == text
        logger.debug("[TextPaster] Clipboard verification: \(clipboardSet ? "SUCCESS" : "FAILED")")

        // Small delay to ensure clipboard is registered by the system before pasting
        // Using async sleep instead of Thread.sleep to avoid blocking main thread
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Simulate Cmd+V to paste (run on background queue to avoid main thread blocking)
        let pasteSuccess = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = simulatePasteKeyPress()
                continuation.resume(returning: result)
            }
        }
        logger.debug("[TextPaster] Paste simulation: \(pasteSuccess ? "SUCCESS" : "FAILED")")

        // Restore original clipboard after sufficient delay for paste to complete
        // We await this task to ensure clipboard is restored before method returns
        await Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms - increased to ensure paste completes
            await MainActor.run {
                guard pasteboard.changeCount == insertedChangeCount else {
                    logger.debug("[TextPaster] Clipboard changed after paste; skipping restore")
                    return
                }

                originalClipboard.restore(to: pasteboard)
                logger.debug("[TextPaster] Clipboard restored")
            }
        }.value
    }

    /// Synchronous paste key simulation - runs on background thread
    /// Uses usleep instead of Thread.sleep since this is called from a background queue
    private nonisolated static func simulatePasteKeyPress() -> Bool {
        // Create key down event for Cmd+V
        let source = CGEventSource(stateID: .combinedSessionState)
        var success = false

        // Key down for 'v'
        if let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(0x09), // 'v' key
            keyDown: true
        ) {
            keyDown.flags = [.maskCommand]
            keyDown.post(tap: .cghidEventTap) // Use HID tap for better compatibility
            success = true
        }

        // Small delay between key down and key up for reliable paste
        // Using usleep (microseconds) since we're on a background thread
        usleep(20000) // 20ms

        // Key up for 'v'
        if let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(0x09), // 'v' key
            keyDown: false
        ) {
            keyUp.flags = [.maskCommand]
            keyUp.post(tap: .cghidEventTap) // Use HID tap for better compatibility
        } else {
            success = false
        }

        return success
    }

    /// Type text character by character (alternative method)
    @MainActor
    public static func typeText(_ text: String) {
        guard !text.isEmpty else { return }

        logger.debug("[TextPaster] Typing text character by character (\(text.count) chars)")

        let source = CGEventSource(stateID: .combinedSessionState)

        for char in text {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                let utf16Chars = Array(String(char).utf16)
                event.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
                event.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }
}

private struct PasteboardSnapshot {
    /// Each captured item stores its data keyed by pasteboard type.
    let itemData: [[(NSPasteboard.PasteboardType, Data)]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let captured = pasteboard.pasteboardItems?.map { item -> [(NSPasteboard.PasteboardType, Data)] in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                if let data = item.data(forType: type) {
                    return (type, data)
                }
                // Fallback: some representations use lazy/on-demand providers where
                // data(forType:) returns nil. Try string(forType:) for text-based types.
                if let string = item.string(forType: type),
                   let data = string.data(using: .utf8)
                {
                    return (type, data)
                }
                return nil
            }
        } ?? []
        return PasteboardSnapshot(itemData: captured)
    }

    @MainActor
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        for itemEntries in itemData {
            guard !itemEntries.isEmpty else { continue }
            let item = NSPasteboardItem()
            for (type, data) in itemEntries {
                item.setData(data, forType: type)
            }
            pasteboard.writeObjects([item])
        }
    }
}
