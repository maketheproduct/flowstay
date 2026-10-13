@preconcurrency import AVFoundation
@testable import FlowstayCore
import FluidAudio
import XCTest

/// Local-only: FLOWSTAY_E2E_AUDIO=/path/to/speech.aiff swift test --filter LocalASRPipelineE2ETests
/// Feeds real speech through the live capture conversion + chunk pipeline at several device formats.
final class LocalASRPipelineE2ETests: XCTestCase {
    private func sourcePath() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["FLOWSTAY_E2E_AUDIO"] else {
            throw XCTSkip("FLOWSTAY_E2E_AUDIO not set")
        }
        return path
    }

    private func loadMono(_ path: String) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return buffer
    }

    /// Resample mono source to `rate` and place it on `speechChannel` of a `channels`-wide buffer.
    private func makeDeviceBuffer(from mono: AVAudioPCMBuffer, rate: Double, channels: AVAudioChannelCount, speechChannel: Int) throws -> AVAudioPCMBuffer {
        let monoAtRate = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let converter = try XCTUnwrap(AVAudioConverter(from: mono.format, to: monoAtRate))
        let capacity = AVAudioFrameCount(Double(mono.frameLength) * rate / mono.format.sampleRate) + 4096
        let resampled = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: monoAtRate, frameCapacity: capacity))
        var fed = false
        _ = converter.convert(to: resampled, error: nil) { _, status in
            if fed {
                status.pointee = .endOfStream; return nil
            }
            fed = true; status.pointee = .haveData; return mono
        }
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)))
        let deviceFormat = channels <= 2
            ? try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false))
            : AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
        let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: deviceFormat, frameCapacity: resampled.frameLength))
        out.frameLength = resampled.frameLength
        for channel in 0 ..< Int(channels) {
            let dst = out.floatChannelData![channel]
            for frame in 0 ..< Int(resampled.frameLength) {
                dst[frame] = (channel == speechChannel || channels <= 2) ? resampled.floatChannelData![0][frame] : 0
            }
        }
        return out
    }

    private func transcribe(device: AVAudioPCMBuffer, forceBoundaryAtFraction: Double?) async throws -> String {
        try await transcribe(device: device, forceBoundariesAt: forceBoundaryAtFraction.map { [$0] } ?? [])
    }

    private func transcribe(device: AVAudioPCMBuffer, forceBoundariesAt fractions: [Double]) async throws -> String {
        let models = try await AsrModels.loadFromCache()
        let asr = AsrManager(config: ASRConfig(sampleRate: 16000))
        try await asr.loadModels(models)
        let manager = ChunkedRecordingManager()
        await manager.configure(asrManager: asr)
        await manager.startRecording()

        let output = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let converter = try XCTUnwrap(makeASRTapConverter(from: device.format, to: output))
        let slice: AVAudioFrameCount = 1024
        var offset: AVAudioFrameCount = 0
        var pendingBoundaries = fractions.sorted()
        while offset < device.frameLength {
            let count = min(slice, device.frameLength - offset)
            let piece = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: device.format, frameCapacity: count))
            piece.frameLength = count
            for channel in 0 ..< Int(device.format.channelCount) {
                piece.floatChannelData![channel].update(from: device.floatChannelData![channel] + Int(offset), count: Int(count))
            }
            let converted = try XCTUnwrap(convertTapBufferToASRMono(piece, converter: converter, outputFormat: output))
            let samples = Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
            await manager.appendSamples(samples, hasAudioActivity: true)
            offset += count
            if let fraction = pendingBoundaries.first, Double(offset) >= Double(device.frameLength) * fraction {
                pendingBoundaries.removeFirst()
                await manager.forceChunkBoundary()
            }
        }
        await manager.forceChunkBoundary()
        let (text, _) = await manager.finalize()
        return text
    }

    private func assertTranscript(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let lowered = text.lowercased()
        print("E2E TRANSCRIPT: \(text)")
        for word in ["quick", "brown", "fox", "lazy", "dog", "flow", "release", "listening"] {
            XCTAssertTrue(lowered.contains(word), "missing '\(word)' in: \(text)", file: file, line: line)
        }
    }

    func testFormats() async throws {
        let mono = try loadMono(sourcePath())
        let cases: [(String, Double, AVAudioChannelCount, Int)] = [
            ("48k stereo", 48000, 2, 0),
            ("44.1k mono", 44100, 1, 0),
            ("24k mono (Bluetooth HFP)", 24000, 1, 0),
            ("16k mono (Bluetooth HFP)", 16000, 1, 0),
            ("48k 8ch, speech on input 3", 48000, 8, 2),
        ]
        for (name, rate, channels, speechChannel) in cases {
            let device = try makeDeviceBuffer(from: mono, rate: rate, channels: channels, speechChannel: speechChannel)
            let text = try await transcribe(device: device, forceBoundaryAtFraction: nil)
            print("CASE \(name)")
            assertTranscript(text)
        }
    }

    func testForcedChunkBoundaryStitchesWithoutDuplicates() async throws {
        let mono = try loadMono(sourcePath())
        let device = try makeDeviceBuffer(from: mono, rate: 48000, channels: 1, speechChannel: 0)
        let text = try await transcribe(device: device, forceBoundaryAtFraction: 0.5)
        assertTranscript(text)
        let words = text.lowercased().split(separator: " ")
        XCTAssertEqual(words.filter { $0.hasPrefix("fox") }.count, 1, "duplicated overlap: \(text)")
    }

    /// FLOWSTAY_E2E_MARKER_AUDIO: speech of "Marker one. <same sentence>" … "Marker seventy-two. …".
    func testRepetitiveSpeechAcrossChunkBoundariesKeepsEveryMarkerOnce() async throws {
        guard let path = ProcessInfo.processInfo.environment["FLOWSTAY_E2E_MARKER_AUDIO"] else {
            throw XCTSkip("FLOWSTAY_E2E_MARKER_AUDIO not set")
        }
        let device = try makeDeviceBuffer(from: loadMono(path), rate: 48000, channels: 1, speechChannel: 0)
        let text = try await transcribe(device: device, forceBoundariesAt: [0.34, 0.67]).lowercased()
        print("E2E MARKER TRANSCRIPT: \(text)")

        let units = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        let teens = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy"]
        func spoken(_ number: Int) -> [String] {
            let word: String = if number < 10 {
                units[number - 1]
            } else if number < 20 {
                teens[number - 10]
            } else {
                tens[number / 10 - 2] + (number % 10 == 0 ? "" : "-" + units[number % 10 - 1])
            }
            return ["marker \(word)", "marker \(number)", "marker \(word.replacingOccurrences(of: "-", with: " "))"]
        }
        for number in 1 ... 72 {
            let hits = spoken(number).map { form in
                text.components(separatedBy: form + ".").count - 1 + text.components(separatedBy: form + ",").count - 1
            }.max() ?? 0
            XCTAssertEqual(hits, 1, "marker \(number) appears \(hits) times")
        }
    }
}
