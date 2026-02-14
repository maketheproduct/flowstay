import AppKit
import Foundation

/// Manages audio feedback for app events
@MainActor
public class SoundManager: NSObject, NSSoundDelegate {
    public static let shared = SoundManager()

    /// Keep strong references to playing sounds to prevent deallocation
    private var playingSounds = Set<NSSound>()

    override private init() {}

    /// Play a system sound by name
    private func playSound(_ name: String) {
        if let sound = NSSound(named: name) {
            sound.delegate = self
            playingSounds.insert(sound)
            sound.play()
        }
    }

    /// NSSoundDelegate method to clean up finished sounds
    public nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        Task { @MainActor in
            playingSounds.remove(sound)
        }
    }

    /// Play sound indicating recording started
    public func playStartRecording() {
        // "Purr" is a soft, inviting sound to prompt speaking
        playSound("Purr")
    }

    /// Play sound indicating recording stopped
    public func playStopRecording() {
        // "Pop" for something lighter
        playSound("Pop")
    }

    /// Play sound indicating processing complete / ready to paste
    public func playTranscriptionComplete() {
        // "Glass" is a pleasant completion sound
        playSound("Glass")
    }

    /// Play sound indicating an error
    public func playError() {
        // "Basso" or standard beep
        playSound("Basso")
    }
}
