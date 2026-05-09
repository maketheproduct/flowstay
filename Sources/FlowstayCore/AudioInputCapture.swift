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

enum AudioCaptureBackendKind: String, Sendable {
    case coreAudioHAL
    case avAudioEngineFallback
}

enum AudioInputDeviceChangeReason: String, Codable, Sendable {
    case appStart
    case defaultInputChanged
    case devicesChanged
    case serviceRestarted
    case deviceAliveChanged
    case sampleRateChanged
    case postRecordingPending
}

struct AudioInputDeviceChangeEvent: Sendable {
    let reason: AudioInputDeviceChangeReason
    let snapshot: AudioInputDeviceSnapshot?
}

struct AudioInputDeviceSnapshot: Equatable, Sendable {
    let deviceID: AudioDeviceID
    let uid: String?
    let name: String?
    let transportType: UInt32?
    let nominalSampleRate: Double
    let inputChannelCount: UInt32
}

public struct AudioInputActivationMetrics: Codable, Sendable {
    public let reason: String
    public let deviceID: UInt32
    public let deviceUIDHash: String?
    public let deviceName: String?
    public let transportType: UInt32?
    public let nominalSampleRate: Double
    public let inputChannelCount: UInt32
    public let attemptCount: Int
    public let timeToFirstHALCallbackMs: Double?
    public let timeToFirstConvertedBufferMs: Double?
    public let succeeded: Bool
    public let errorCode: Int32?

    public init(
        reason: String,
        deviceID: UInt32,
        deviceUIDHash: String?,
        deviceName: String?,
        transportType: UInt32?,
        nominalSampleRate: Double,
        inputChannelCount: UInt32,
        attemptCount: Int,
        timeToFirstHALCallbackMs: Double?,
        timeToFirstConvertedBufferMs: Double?,
        succeeded: Bool,
        errorCode: Int32?
    ) {
        self.reason = reason
        self.deviceID = deviceID
        self.deviceUIDHash = deviceUIDHash
        self.deviceName = deviceName
        self.transportType = transportType
        self.nominalSampleRate = nominalSampleRate
        self.inputChannelCount = inputChannelCount
        self.attemptCount = attemptCount
        self.timeToFirstHALCallbackMs = timeToFirstHALCallbackMs
        self.timeToFirstConvertedBufferMs = timeToFirstConvertedBufferMs
        self.succeeded = succeeded
        self.errorCode = errorCode
    }
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

actor AudioInputDeviceMonitor {
    private let logger = Logger(subsystem: "com.flowstay.app", category: "AudioInputDeviceMonitor")
    private let queue = DispatchQueue(label: "com.flowstay.app.audio.input-device-monitor")
    private struct ListenerToken {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let listener: AudioObjectPropertyListenerBlock
    }

    private var listenerTokens: [String: ListenerToken] = [:]
    private var onChange: (@Sendable (AudioInputDeviceChangeEvent) -> Void)?
    private var defaultDeviceListenerID: AudioDeviceID?

    func currentDefaultInputSnapshot() throws -> AudioInputDeviceSnapshot {
        try AudioInputDeviceMonitor.snapshotForCurrentDefaultInput()
    }

    func startListening(onChange: @Sendable @escaping (AudioInputDeviceChangeEvent) -> Void) {
        self.onChange = onChange
        registerSystemListener(selector: kAudioHardwarePropertyDefaultInputDevice, reason: .defaultInputChanged)
        registerSystemListener(selector: kAudioHardwarePropertyDevices, reason: .devicesChanged)
        registerSystemListener(selector: kAudioHardwarePropertyServiceRestarted, reason: .serviceRestarted)

        let snapshot = try? Self.snapshotForCurrentDefaultInput()
        refreshDefaultDeviceListeners(for: snapshot?.deviceID)
        onChange(AudioInputDeviceChangeEvent(reason: .appStart, snapshot: snapshot))
    }

    func stopListening() {
        for token in listenerTokens.values {
            var mutableAddress = token.address
            AudioObjectRemovePropertyListenerBlock(token.objectID, &mutableAddress, queue, token.listener)
        }
        listenerTokens.removeAll()
        defaultDeviceListenerID = nil
        onChange = nil
    }

    nonisolated static func snapshotForCurrentDefaultInput() throws -> AudioInputDeviceSnapshot {
        let deviceID = try currentDefaultInputDeviceID()
        return try snapshot(for: deviceID)
    }

    static func systemPropertyAddress(selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func devicePropertyAddress(selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func registerSystemListener(
        selector: AudioObjectPropertySelector,
        reason: AudioInputDeviceChangeReason
    ) {
        var address = Self.systemPropertyAddress(selector: selector)
        register(objectID: AudioObjectID(kAudioObjectSystemObject), address: &address, reason: reason)
    }

    private func registerDeviceListener(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        reason: AudioInputDeviceChangeReason
    ) {
        var address = Self.devicePropertyAddress(selector: selector)
        register(objectID: AudioObjectID(deviceID), address: &address, reason: reason)
    }

    private func register(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress,
        reason: AudioInputDeviceChangeReason
    ) {
        let key = listenerKey(objectID: objectID, address: address)
        guard listenerTokens[key] == nil else { return }
        let storedAddress = address
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { [weak self] in
                guard let self else { return }
                let snapshot = try? Self.snapshotForCurrentDefaultInput()
                await refreshDefaultDeviceListeners(for: snapshot?.deviceID)
                await onChange?(AudioInputDeviceChangeEvent(reason: reason, snapshot: snapshot))
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, listener)
        guard status == noErr else {
            logger.error("[AudioInputDeviceMonitor] Failed to add listener \(storedAddress.mSelector, privacy: .public): \(status, privacy: .public)")
            return
        }
        listenerTokens[key] = ListenerToken(objectID: objectID, address: storedAddress, listener: listener)
    }

    private func listenerKey(objectID: AudioObjectID, address: AudioObjectPropertyAddress) -> String {
        "\(objectID)-\(address.mSelector)-\(address.mScope)-\(address.mElement)"
    }

    private func refreshDefaultDeviceListeners(for deviceID: AudioDeviceID?) {
        guard defaultDeviceListenerID != deviceID else { return }

        removeDefaultDeviceListeners()
        defaultDeviceListenerID = deviceID

        guard let deviceID else { return }
        registerDeviceListener(deviceID: deviceID, selector: kAudioDevicePropertyDeviceIsAlive, reason: .deviceAliveChanged)
        registerDeviceListener(deviceID: deviceID, selector: kAudioDevicePropertyNominalSampleRate, reason: .sampleRateChanged)
    }

    private func removeDefaultDeviceListeners() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let deviceTokens = listenerTokens.filter { $0.value.objectID != systemObject }

        for (key, token) in deviceTokens {
            var mutableAddress = token.address
            AudioObjectRemovePropertyListenerBlock(token.objectID, &mutableAddress, queue, token.listener)
            listenerTokens.removeValue(forKey: key)
        }

        defaultDeviceListenerID = nil
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
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
        self.audioUnit = nil
        renderBox = nil
    }
}

final actor AVAudioEngineInputCaptureBackend: AudioInputCaptureBackend {
    private var engine: AVAudioEngine?

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
    }

    func stop() async {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        self.engine = nil
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
    private let audioUnit: AudioUnit
    private let inputFormat: AVAudioFormat
    private let inputBus: UInt32
    private let converter: AudioSampleConverter
    private let onHALCallback: @Sendable () -> Void
    private let onSamples: @Sendable ([Float]) -> Void
    private let logger = Logger(subsystem: "com.flowstay.app", category: "CoreAudioHALInputCapture")
    private let diagnosticsLock = NSLock()
    private var diagnosticsLogged = 0

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
    }

    func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        onHALCallback()

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return kAudio_ParamError
        }
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
            logDiagnostic(
                "AudioUnitRender failed status=\(status) callbackBus=\(busNumber) renderBus=\(inputBus) frames=\(frameCount)"
            )
            return status
        }

        guard let samples = converter.convert(buffer: inputBuffer), !samples.isEmpty else {
            logDiagnostic(
                "Converted buffer was empty callbackBus=\(busNumber) renderBus=\(inputBus) frames=\(frameCount) format=\(inputFormat.description)"
            )
            return noErr
        }
        onSamples(samples)
        return noErr
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
    private let lock = NSLock()

    init(inputFormat: AVAudioFormat, outputSampleRate: Double = 16000) throws {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: false
        ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw AudioCaptureError.converterUnavailable
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(buffer: AVAudioPCMBuffer) -> [Float]? {
        let frameCapacity = convertedOutputFrameCapacity(
            inputFrameCount: buffer.frameLength,
            inputSampleRate: buffer.format.sampleRate,
            outputSampleRate: outputFormat.sampleRate
        )
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: frameCapacity
        ) else {
            return nil
        }

        var error: NSError?
        let status: AVAudioConverterOutputStatus = lock.withLock {
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
        }
        guard error == nil, status == .haveData || convertedBuffer.frameLength > 0,
              let channelData = convertedBuffer.floatChannelData,
              convertedBuffer.frameLength > 0
        else {
            return nil
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

actor AudioInputActivationCoordinator {
    private let backend: any AudioInputCaptureBackend
    private let logger = Logger(subsystem: "com.flowstay.app", category: "AudioInputActivationCoordinator")
    private let debounceNanoseconds: UInt64
    private let timeout: TimeInterval
    private let maximumAttempts: Int
    private let retryDelayNanoseconds: UInt64
    private let persistMetrics: Bool
    private let maxStoredMetrics = 25

    private var recordingActive = false
    private var hasPendingPostRecordingProof = false
    private var debounceTask: Task<Void, Never>?
    private var proofTask: Task<Void, Never>?
    private var scheduledWorkGeneration = 0
    private var recentActivationMetrics: [AudioInputActivationMetrics] = []

    init(
        backend: any AudioInputCaptureBackend,
        debounceNanoseconds: UInt64 = 350_000_000,
        timeout: TimeInterval = 1.5,
        maximumAttempts: Int = 2,
        retryDelayNanoseconds: UInt64 = 200_000_000,
        persistMetrics: Bool = true
    ) {
        self.backend = backend
        self.debounceNanoseconds = debounceNanoseconds
        self.timeout = timeout
        self.maximumAttempts = maximumAttempts
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.persistMetrics = persistMetrics
    }

    func requestProof(reason: AudioInputDeviceChangeReason) {
        guard !recordingActive else {
            hasPendingPostRecordingProof = true
            logger.debug("[AudioInputActivationCoordinator] Deferring idle activation proof until recording stops")
            return
        }

        scheduleProof(reason: reason)
    }

    func setRecordingActive(_ active: Bool) async {
        recordingActive = active

        if active {
            cancelScheduledWork()
            await backend.stop()
            return
        }

        guard hasPendingPostRecordingProof else { return }
        hasPendingPostRecordingProof = false
        scheduleProof(reason: .postRecordingPending)
    }

    @discardableResult
    func proveNow(reason: AudioInputDeviceChangeReason) async -> AudioInputActivationMetrics {
        cancelScheduledWork()
        await backend.stop()
        let metric = await performActivationProof(reason: reason)
        await record(metric)
        return metric
    }

    func stop() async {
        cancelScheduledWork()
        hasPendingPostRecordingProof = false
        recordingActive = false
        await backend.stop()
    }

    func recentMetrics() -> [AudioInputActivationMetrics] {
        recentActivationMetrics
    }

    func waitForScheduledWork() async {
        while true {
            let debounce = debounceTask
            let proof = proofTask

            if debounce == nil, proof == nil {
                return
            }

            await debounce?.value
            await proof?.value
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func scheduleProof(reason: AudioInputDeviceChangeReason) {
        debounceTask?.cancel()
        proofTask?.cancel()

        scheduledWorkGeneration += 1
        let generation = scheduledWorkGeneration
        let delayNanoseconds = debounceNanoseconds
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                await clearDebounceTask(generation: generation)
                return
            }

            guard !Task.isCancelled else {
                await clearDebounceTask(generation: generation)
                return
            }

            await startProofTask(reason: reason, generation: generation)
            await clearDebounceTask(generation: generation)
        }
    }

    private func startProofTask(reason: AudioInputDeviceChangeReason, generation: Int) {
        proofTask?.cancel()
        proofTask = Task { [weak self] in
            guard let self else { return }
            let metric = await performActivationProof(reason: reason)
            let isCurrentGeneration = await isCurrentGeneration(generation)
            guard isCurrentGeneration, !Task.isCancelled else {
                await clearProofTask(generation: generation)
                return
            }
            await record(metric)
            await clearProofTask(generation: generation)
        }
    }

    private func cancelScheduledWork() {
        scheduledWorkGeneration += 1
        debounceTask?.cancel()
        debounceTask = nil
        proofTask?.cancel()
        proofTask = nil
    }

    private func isCurrentGeneration(_ generation: Int) -> Bool {
        scheduledWorkGeneration == generation
    }

    private func clearDebounceTask(generation: Int) {
        guard scheduledWorkGeneration == generation else { return }
        debounceTask = nil
    }

    private func clearProofTask(generation: Int) {
        guard scheduledWorkGeneration == generation else { return }
        proofTask = nil
    }

    private func record(_ metric: AudioInputActivationMetrics) async {
        recentActivationMetrics.insert(metric, at: 0)
        if recentActivationMetrics.count > maxStoredMetrics {
            recentActivationMetrics = Array(recentActivationMetrics.prefix(maxStoredMetrics))
        }

        let status = metric.succeeded ? "succeeded" : "failed"
        logger.info(
            "[AudioInputActivationCoordinator] Idle activation \(status, privacy: .public) reason=\(metric.reason, privacy: .public) device=\(metric.deviceID, privacy: .public) attempts=\(metric.attemptCount, privacy: .public)"
        )
        if persistMetrics {
            await MetricsLogger.shared.logAudioActivation(metric)
        }
    }

    private func performActivationProof(reason: AudioInputDeviceChangeReason) async -> AudioInputActivationMetrics {
        var lastSnapshot: AudioInputDeviceSnapshot?
        var lastErrorCode: Int32?
        var lastObservation = AudioInputSampleObservation()
        var lastStartedAt = Date()

        for attempt in 1 ... maximumAttempts {
            if Task.isCancelled {
                break
            }

            let snapshot: AudioInputDeviceSnapshot
            do {
                snapshot = try backend.currentDefaultInputSnapshot()
            } catch {
                lastErrorCode = audioCaptureErrorCode(error)
                return makeActivationMetrics(
                    reason: reason,
                    snapshot: lastSnapshot,
                    attemptCount: attempt,
                    startedAt: lastStartedAt,
                    observation: lastObservation,
                    succeeded: false,
                    errorCode: lastErrorCode
                )
            }

            lastSnapshot = snapshot
            let observation = AudioInputSampleObservation()
            lastObservation = observation
            lastStartedAt = Date()

            do {
                try await backend.start(
                    snapshot: snapshot,
                    onHALCallback: {
                        observation.markHALCallback()
                    },
                    onSamples: { samples in
                        guard !samples.isEmpty else { return }
                        observation.markReceived()
                    }
                )
            } catch {
                lastErrorCode = audioCaptureErrorCode(error)
                await backend.stop()
                if attempt < maximumAttempts {
                    try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
                    continue
                }
                break
            }

            let receivedSamples = await waitForSamples(
                observation: observation,
                timeout: timeout
            )

            await backend.stop()

            if Task.isCancelled {
                break
            }

            guard receivedSamples else {
                if attempt < maximumAttempts {
                    try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
                    continue
                }
                break
            }

            let currentSnapshot = try? backend.currentDefaultInputSnapshot()
            if let currentSnapshot, currentSnapshot.deviceID != snapshot.deviceID {
                lastSnapshot = currentSnapshot
                if attempt < maximumAttempts {
                    try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
                    continue
                }
                break
            }

            return makeActivationMetrics(
                reason: reason,
                snapshot: snapshot,
                attemptCount: attempt,
                startedAt: lastStartedAt,
                observation: lastObservation,
                succeeded: true,
                errorCode: nil
            )
        }

        return makeActivationMetrics(
            reason: reason,
            snapshot: lastSnapshot,
            attemptCount: maximumAttempts,
            startedAt: lastStartedAt,
            observation: lastObservation,
            succeeded: false,
            errorCode: lastErrorCode
        )
    }

    private func waitForSamples(observation: AudioInputSampleObservation, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled {
                return false
            }

            if observation.hasReceivedConvertedBuffer {
                return true
            }

            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        return observation.hasReceivedConvertedBuffer
    }

    private func makeActivationMetrics(
        reason: AudioInputDeviceChangeReason,
        snapshot: AudioInputDeviceSnapshot?,
        attemptCount: Int,
        startedAt: Date,
        observation: AudioInputSampleObservation,
        succeeded: Bool,
        errorCode: Int32?
    ) -> AudioInputActivationMetrics {
        let halCallbackMs = observation.firstHALCallbackAt.map { $0.timeIntervalSince(startedAt) * 1000 }
        let convertedBufferMs = observation.firstConvertedBufferAt.map { $0.timeIntervalSince(startedAt) * 1000 }

        return AudioInputActivationMetrics(
            reason: reason.rawValue,
            deviceID: UInt32(snapshot?.deviceID ?? 0),
            deviceUIDHash: hashAudioDeviceUID(snapshot?.uid),
            deviceName: snapshot?.name,
            transportType: snapshot?.transportType,
            nominalSampleRate: snapshot?.nominalSampleRate ?? 0,
            inputChannelCount: snapshot?.inputChannelCount ?? 0,
            attemptCount: attemptCount,
            timeToFirstHALCallbackMs: halCallbackMs,
            timeToFirstConvertedBufferMs: convertedBufferMs,
            succeeded: succeeded,
            errorCode: errorCode
        )
    }
}

actor AudioInputActivationProof {
    private let backend: any AudioInputCaptureBackend
    private let timeout: TimeInterval
    private let maximumAttempts: Int
    private let retryDelayNanoseconds: UInt64
    private var isActive = false

    init(
        backend: any AudioInputCaptureBackend,
        timeout: TimeInterval = 1.5,
        maximumAttempts: Int = 2,
        retryDelayNanoseconds: UInt64 = 200_000_000
    ) {
        self.backend = backend
        self.timeout = timeout
        self.maximumAttempts = maximumAttempts
        self.retryDelayNanoseconds = retryDelayNanoseconds
    }

    func start(
        onActivated: @escaping @Sendable () -> Void = {},
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) async throws -> AudioInputDeviceSnapshot {
        for attempt in 1 ... maximumAttempts {
            let snapshot = try backend.currentDefaultInputSnapshot()
            let observation = AudioInputSampleObservation()

            try await backend.start(snapshot: snapshot, onHALCallback: observation.markHALCallback) { samples in
                guard !samples.isEmpty else { return }
                observation.markReceived()
                onSamples(samples)
            }

            let didReceiveSamples = await waitForSamples(observation: observation, timeout: timeout)
            guard didReceiveSamples else {
                await backend.stop()
                if attempt < maximumAttempts {
                    try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
                    continue
                }
                throw AudioInputActivationProofError.startupTimedOut
            }

            let postActivationSnapshot = try? backend.currentDefaultInputSnapshot()
            if let postActivationSnapshot, postActivationSnapshot.deviceID != snapshot.deviceID {
                await backend.stop()
                if attempt < maximumAttempts {
                    try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
                    continue
                }
                throw AudioInputActivationProofError.startupTimedOut
            }

            isActive = true
            onActivated()
            return snapshot
        }

        throw AudioInputActivationProofError.startupTimedOut
    }

    func stop() async {
        isActive = false
        await backend.stop()
    }

    func activeState() -> Bool {
        isActive
    }

    private func waitForSamples(observation: AudioInputSampleObservation, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled {
                return false
            }

            if observation.hasReceivedConvertedBuffer {
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return observation.hasReceivedConvertedBuffer
    }
}

enum AudioInputActivationProofError: LocalizedError {
    case startupTimedOut

    var errorDescription: String? {
        "Timed out waiting for audio samples from the selected input device."
    }
}

func audioCaptureErrorCode(_ error: Error) -> Int32? {
    if let audioCaptureError = error as? AudioCaptureError {
        switch audioCaptureError {
        case let .osStatus(status, _):
            return Int32(status)
        case .audioComponentUnavailable, .unsupportedStreamFormat, .converterUnavailable:
            return nil
        }
    }

    let nsError = error as NSError
    guard nsError.code >= Int(Int32.min), nsError.code <= Int(Int32.max) else {
        return nil
    }
    return Int32(nsError.code)
}

private final class AudioInputSampleObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedSamples = false
    private var firstCallbackAt: Date?
    private var firstReceivedAt: Date?

    func markHALCallback() {
        lock.withLock {
            if firstCallbackAt == nil {
                firstCallbackAt = Date()
            }
        }
    }

    func markReceived() {
        lock.withLock {
            if firstReceivedAt == nil {
                firstReceivedAt = Date()
            }
            receivedSamples = true
        }
    }

    var hasReceivedConvertedBuffer: Bool {
        lock.withLock { receivedSamples }
    }

    var firstHALCallbackAt: Date? {
        lock.withLock { firstCallbackAt }
    }

    var firstConvertedBufferAt: Date? {
        lock.withLock { firstReceivedAt }
    }
}
