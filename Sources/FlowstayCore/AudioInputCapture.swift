@preconcurrency import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import CryptoKit
import Foundation
import os

protocol AudioInputCaptureBackend: Sendable {
    func currentDefaultInputSnapshot() throws -> AudioInputDeviceSnapshot
    func start(
        snapshot: AudioInputDeviceSnapshot,
        onHALCallback: @escaping @Sendable () -> Void,
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) async throws
    func stop() async
}

extension AudioInputCaptureBackend {
    func start(
        snapshot: AudioInputDeviceSnapshot,
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) async throws {
        try await start(snapshot: snapshot, onHALCallback: {}, onSamples: onSamples)
    }
}

enum AudioCaptureBackendKind: String {
    case coreAudioHAL
    case avAudioEngineFallback
}

struct AudioInputDeviceSnapshot: Equatable {
    let deviceID: AudioDeviceID
    let uid: String?
    let name: String?
    let transportType: UInt32?
    let nominalSampleRate: Double
    let inputChannelCount: UInt32
}

public struct AudioStartupMetrics: Codable, Sendable {
    public let backend: String
    public let deviceID: UInt32
    public let deviceUIDHash: String?
    public let deviceName: String?
    public let transportType: UInt32?
    public let nominalSampleRate: Double
    public let inputChannelCount: UInt32
    public let startupAttemptCount: Int
    public let timeToFirstHALCallbackMs: Double?
    public let timeToFirstConvertedBufferMs: Double?
    public let fallbackUsed: Bool
    public let errorCode: Int32?

    public init(
        backend: String,
        deviceID: UInt32,
        deviceUIDHash: String?,
        deviceName: String?,
        transportType: UInt32?,
        nominalSampleRate: Double,
        inputChannelCount: UInt32,
        startupAttemptCount: Int,
        timeToFirstHALCallbackMs: Double?,
        timeToFirstConvertedBufferMs: Double?,
        fallbackUsed: Bool,
        errorCode: Int32?
    ) {
        self.backend = backend
        self.deviceID = deviceID
        self.deviceUIDHash = deviceUIDHash
        self.deviceName = deviceName
        self.transportType = transportType
        self.nominalSampleRate = nominalSampleRate
        self.inputChannelCount = inputChannelCount
        self.startupAttemptCount = startupAttemptCount
        self.timeToFirstHALCallbackMs = timeToFirstHALCallbackMs
        self.timeToFirstConvertedBufferMs = timeToFirstConvertedBufferMs
        self.fallbackUsed = fallbackUsed
        self.errorCode = errorCode
    }
}

enum AudioInputDeviceMonitor {
    static func snapshotForCurrentDefaultInput() throws -> AudioInputDeviceSnapshot {
        let deviceID = try currentDefaultInputDeviceID()
        return try snapshot(for: deviceID)
    }
}

final actor CoreAudioHALInputCapture: AudioInputCaptureBackend {
    private static let inputBus: UInt32 = 1
    private let logger = Logger(subsystem: "com.flowstay.app", category: "CoreAudioHALInputCapture")
    private var audioUnit: AudioUnit?
    private var renderBox: CoreAudioHALRenderBox?

    nonisolated func currentDefaultInputSnapshot() throws -> AudioInputDeviceSnapshot {
        try AudioInputDeviceMonitor.snapshotForCurrentDefaultInput()
    }

    func start(
        snapshot: AudioInputDeviceSnapshot,
        onHALCallback: @escaping @Sendable () -> Void,
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) async throws {
        await stop()

        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &componentDescription) else {
            throw AudioCaptureError.audioComponentUnavailable
        }

        var newAudioUnit: AudioUnit?
        try checkOSStatus(AudioComponentInstanceNew(component, &newAudioUnit), context: "AudioComponentInstanceNew")
        guard let newAudioUnit else {
            throw AudioCaptureError.audioComponentUnavailable
        }

        do {
            var enable: UInt32 = 1
            try checkOSStatus(AudioUnitSetProperty(
                newAudioUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                Self.inputBus,
                &enable,
                UInt32(MemoryLayout<UInt32>.size)
            ), context: "Enable input")

            var disable: UInt32 = 0
            try checkOSStatus(AudioUnitSetProperty(
                newAudioUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &disable,
                UInt32(MemoryLayout<UInt32>.size)
            ), context: "Disable output")

            var deviceID = snapshot.deviceID
            try checkOSStatus(AudioUnitSetProperty(
                newAudioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ), context: "Bind current input device")

            var deviceStreamDescription = AudioStreamBasicDescription()
            var streamDescriptionSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try checkOSStatus(AudioUnitGetProperty(
                newAudioUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                Self.inputBus,
                &deviceStreamDescription,
                &streamDescriptionSize
            ), context: "Get device input stream format")

            var inputStreamDescription = makeHALClientStreamDescription(
                deviceStreamDescription: deviceStreamDescription,
                snapshot: snapshot
            )
            try checkOSStatus(AudioUnitSetProperty(
                newAudioUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                Self.inputBus,
                &inputStreamDescription,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ), context: "Set input client stream format")

            guard let inputFormat = AVAudioFormat(streamDescription: &inputStreamDescription) else {
                throw AudioCaptureError.unsupportedStreamFormat
            }

            let box = try CoreAudioHALRenderBox(
                audioUnit: newAudioUnit,
                inputFormat: inputFormat,
                inputBus: Self.inputBus,
                onHALCallback: onHALCallback,
                onSamples: onSamples
            )
            var callback = AURenderCallbackStruct(
                inputProc: coreAudioHALInputRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(box).toOpaque()
            )
            try checkOSStatus(AudioUnitSetProperty(
                newAudioUnit,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0,
                &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ), context: "Set input callback")

            try checkOSStatus(AudioUnitInitialize(newAudioUnit), context: "AudioUnitInitialize")
            try checkOSStatus(AudioOutputUnitStart(newAudioUnit), context: "AudioOutputUnitStart")

            audioUnit = newAudioUnit
            renderBox = box
            logger.info("[CoreAudioHALInputCapture] Started device \(snapshot.deviceID, privacy: .public)")
        } catch {
            AudioComponentInstanceDispose(newAudioUnit)
            throw error
        }
    }

    func stop() async {
        guard let audioUnit else {
            renderBox = nil
            return
        }
        AudioOutputUnitStop(audioUnit)
        renderBox?.stopAndFlush()
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
        self.audioUnit = nil
        renderBox = nil
    }
}

final actor AVAudioEngineInputCaptureBackend: AudioInputCaptureBackend {
    private var engine: AVAudioEngine?
    private var converter: AudioSampleConverter?
    private var onSamples: (@Sendable ([Float]) -> Void)?

    nonisolated func currentDefaultInputSnapshot() throws -> AudioInputDeviceSnapshot {
        try AudioInputDeviceMonitor.snapshotForCurrentDefaultInput()
    }

    func start(
        snapshot _: AudioInputDeviceSnapshot,
        onHALCallback: @escaping @Sendable () -> Void,
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) async throws {
        await stop()
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let converter = try AudioSampleConverter(inputFormat: inputFormat)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            onHALCallback()
            guard let samples = converter.convert(buffer: buffer), !samples.isEmpty else { return }
            onSamples(samples)
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
        self.converter = converter
        self.onSamples = onSamples
    }

    func stop() async {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        if let converter, let onSamples {
            let samples = converter.flushEndOfStream()
            if !samples.isEmpty {
                onSamples(samples)
            }
        }
        self.engine = nil
        converter = nil
        onSamples = nil
    }
}

enum AudioCaptureError: LocalizedError {
    case audioComponentUnavailable
    case unsupportedStreamFormat
    case converterUnavailable
    case osStatus(OSStatus, String)

    var errorDescription: String? {
        switch self {
        case .audioComponentUnavailable:
            "CoreAudio HAL input unit is unavailable."
        case .unsupportedStreamFormat:
            "The input device stream format is unsupported."
        case .converterUnavailable:
            "Could not create input audio converter."
        case let .osStatus(status, context):
            "\(context) failed with OSStatus \(status)."
        }
    }
}

private func checkOSStatus(_ status: OSStatus, context: String) throws {
    guard status == noErr else {
        throw AudioCaptureError.osStatus(status, context)
    }
}

private func makeHALClientStreamDescription(
    deviceStreamDescription: AudioStreamBasicDescription,
    snapshot: AudioInputDeviceSnapshot
) -> AudioStreamBasicDescription {
    let fallbackSampleRate = snapshot.nominalSampleRate > 0 ? snapshot.nominalSampleRate : 48000
    let sampleRate = deviceStreamDescription.mSampleRate > 0
        ? deviceStreamDescription.mSampleRate
        : fallbackSampleRate
    let fallbackChannelCount = snapshot.inputChannelCount > 0 ? snapshot.inputChannelCount : 1
    let channelCount = deviceStreamDescription.mChannelsPerFrame > 0
        ? deviceStreamDescription.mChannelsPerFrame
        : fallbackChannelCount

    return AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat
            | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
        mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
        mChannelsPerFrame: channelCount,
        mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
        mReserved: 0
    )
}

private final class CoreAudioHALRenderBox: @unchecked Sendable {
    private final class BufferSlot: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var inUse = false

        init?(format: AVAudioFormat, frameCapacity: AVAudioFrameCount) {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
                return nil
            }
            self.buffer = buffer
        }
    }

    private let audioUnit: AudioUnit
    private let inputFormat: AVAudioFormat
    private let inputBus: UInt32
    private let converter: AudioSampleConverter
    private let onHALCallback: @Sendable () -> Void
    private let onSamples: @Sendable ([Float]) -> Void
    private let logger = Logger(subsystem: "com.flowstay.app", category: "CoreAudioHALInputCapture")
    private let diagnosticsLock = NSLock()
    private let bufferPoolLock = NSLock()
    private let conversionQueue = DispatchQueue(label: "com.flowstay.app.core-audio-hal.conversion", qos: .userInitiated)
    private let bufferPool: [BufferSlot]
    private var diagnosticsLogged = 0
    private var droppedBuffers = 0

    init(
        audioUnit: AudioUnit,
        inputFormat: AVAudioFormat,
        inputBus: UInt32,
        onHALCallback: @escaping @Sendable () -> Void,
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) throws {
        self.audioUnit = audioUnit
        self.inputFormat = inputFormat
        self.inputBus = inputBus
        converter = try AudioSampleConverter(inputFormat: inputFormat)
        self.onHALCallback = onHALCallback
        self.onSamples = onSamples

        let maxRenderFrames = AVAudioFrameCount(8192)
        var slots: [BufferSlot] = []
        slots.reserveCapacity(8)
        for _ in 0 ..< 8 {
            guard let slot = BufferSlot(format: inputFormat, frameCapacity: maxRenderFrames) else {
                throw AudioCaptureError.converterUnavailable
            }
            slots.append(slot)
        }
        bufferPool = slots
    }

    func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        onHALCallback()

        guard let slot = checkoutBuffer(frameCount: frameCount) else {
            logDiagnostic(
                "No free preallocated buffer callbackBus=\(busNumber) renderBus=\(inputBus) frames=\(frameCount)"
            )
            return noErr
        }
        let inputBuffer = slot.buffer
        inputBuffer.frameLength = AVAudioFrameCount(frameCount)

        let status = AudioUnitRender(
            audioUnit,
            flags,
            timeStamp,
            inputBus,
            frameCount,
            inputBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            releaseBuffer(slot)
            logDiagnostic(
                "AudioUnitRender failed status=\(status) callbackBus=\(busNumber) renderBus=\(inputBus) frames=\(frameCount)"
            )
            return status
        }

        conversionQueue.async { [weak self, slot] in
            guard let self else { return }
            defer { self.releaseBuffer(slot) }
            guard let samples = converter.convert(buffer: inputBuffer), !samples.isEmpty else {
                logDiagnostic(
                    "Converted buffer was empty callbackBus=\(busNumber) renderBus=\(inputBus) frames=\(frameCount) format=\(inputFormat.description)"
                )
                return
            }
            onSamples(samples)
        }
        return noErr
    }

    /// Call after the audio unit has stopped: converts buffers still queued, then
    /// flushes the converter so the end of the recording is not dropped.
    func stopAndFlush() {
        conversionQueue.sync {
            let samples = converter.flushEndOfStream()
            if !samples.isEmpty {
                onSamples(samples)
            }
        }
    }

    private func checkoutBuffer(frameCount: UInt32) -> BufferSlot? {
        bufferPoolLock.withLock {
            guard let slot = bufferPool.first(where: { !$0.inUse && frameCount <= $0.buffer.frameCapacity }) else {
                droppedBuffers += 1
                return nil
            }
            slot.inUse = true
            return slot
        }
    }

    private func releaseBuffer(_ slot: BufferSlot) {
        bufferPoolLock.withLock {
            slot.inUse = false
        }
    }

    private func logDiagnostic(_ message: String) {
        let shouldLog = diagnosticsLock.withLock {
            guard diagnosticsLogged < 5 else { return false }
            diagnosticsLogged += 1
            return true
        }
        guard shouldLog else { return }
        logger.warning("[CoreAudioHALInputCapture] \(message, privacy: .public)")
    }
}

private let coreAudioHALInputRenderCallback: AURenderCallback = { refCon, flags, timeStamp, busNumber, frameCount, _ in
    let box = Unmanaged<CoreAudioHALRenderBox>.fromOpaque(refCon).takeUnretainedValue()
    return box.render(flags: flags, timeStamp: timeStamp, busNumber: busNumber, frameCount: frameCount)
}

private final class AudioSampleConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let preferredOutputFrameCapacity: AVAudioFrameCount
    private let lock = NSLock()

    init(inputFormat: AVAudioFormat, outputSampleRate: Double = 16000) throws {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: false
        ),
            let converter = makeASRTapConverter(from: inputFormat, to: outputFormat)
        else {
            throw AudioCaptureError.converterUnavailable
        }
        self.converter = converter
        self.outputFormat = outputFormat
        preferredOutputFrameCapacity = convertedOutputFrameCapacity(
            inputFrameCount: 1024,
            inputSampleRate: inputFormat.sampleRate,
            outputSampleRate: outputSampleRate
        )
    }

    func convert(buffer: AVAudioPCMBuffer) -> [Float]? {
        let convertedBuffer = lock.withLock {
            convertTapBufferToASRMono(buffer, converter: converter, outputFormat: outputFormat)
        }
        guard let convertedBuffer else {
            return nil
        }
        guard let channelData = convertedBuffer.floatChannelData, convertedBuffer.frameLength > 0 else {
            return []
        }

        return Array(UnsafeBufferPointer(
            start: channelData.pointee,
            count: Int(convertedBuffer.frameLength)
        ))
    }

    func flushEndOfStream(maxIterations: Int = 100) -> [Float] {
        var flushedSamples: [Float] = []
        for _ in 0 ..< maxIterations {
            guard let samples = convert(frameCapacity: preferredOutputFrameCapacity, inputBlock: { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }) else {
                return flushedSamples
            }
            guard !samples.isEmpty else {
                return flushedSamples
            }
            flushedSamples.append(contentsOf: samples)
        }
        return flushedSamples
    }

    private func convert(
        frameCapacity: AVAudioFrameCount,
        inputBlock: @escaping AVAudioConverterInputBlock
    ) -> [Float]? {
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: frameCapacity
        ) else {
            return nil
        }

        var error: NSError?
        let status: AVAudioConverterOutputStatus = lock.withLock {
            converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
        }
        guard error == nil, status == .haveData || convertedBuffer.frameLength > 0,
              let channelData = convertedBuffer.floatChannelData,
              convertedBuffer.frameLength > 0
        else {
            return []
        }

        return Array(UnsafeBufferPointer(
            start: channelData.pointee,
            count: Int(convertedBuffer.frameLength)
        ))
    }
}

private func currentDefaultInputDeviceID() throws -> AudioDeviceID {
    var deviceID = AudioDeviceID(bitPattern: 0)
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    try checkOSStatus(AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &propertySize,
        &deviceID
    ), context: "Read default input device")

    guard deviceID != AudioDeviceID(bitPattern: 0), deviceID != kAudioObjectUnknown else {
        throw FluidAudioError.noInputDeviceAvailable
    }
    return deviceID
}

private func snapshot(for deviceID: AudioDeviceID) throws -> AudioInputDeviceSnapshot {
    AudioInputDeviceSnapshot(
        deviceID: deviceID,
        uid: readStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID),
        name: readStringProperty(deviceID: deviceID, selector: kAudioObjectPropertyName),
        transportType: readUInt32Property(deviceID: deviceID, selector: kAudioDevicePropertyTransportType),
        nominalSampleRate: readDoubleProperty(deviceID: deviceID, selector: kAudioDevicePropertyNominalSampleRate) ?? 0,
        inputChannelCount: readInputChannelCount(deviceID: deviceID)
    )
}

private func readStringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            UnsafeMutableRawPointer(pointer)
        )
    }
    guard status == noErr, let value else { return nil }
    return value as String
}

private func readUInt32Property(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

private func readDoubleProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> Double? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Double = 0
    var size = UInt32(MemoryLayout<Double>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

private func readInputChannelCount(deviceID: AudioDeviceID) -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
        return 0
    }

    let rawBuffer = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawBuffer.deallocate() }

    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, rawBuffer) == noErr else {
        return 0
    }

    let bufferList = rawBuffer.assumingMemoryBound(to: AudioBufferList.self)
    let unsafeBufferList = UnsafeMutableAudioBufferListPointer(bufferList)
    return unsafeBufferList.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
}

func hashAudioDeviceUID(_ uid: String?) -> String? {
    guard let uid else { return nil }
    let digest = SHA256.hash(data: Data(uid.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}
