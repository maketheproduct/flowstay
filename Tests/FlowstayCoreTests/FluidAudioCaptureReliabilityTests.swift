import AVFoundation
import CoreAudio
@testable import FlowstayCore
import XCTest

final class FluidAudioCaptureReliabilityTests: XCTestCase {
    func testConvertedOutputFrameCapacityUsesCeilFor48kTo16k() {
        let capacity = convertedOutputFrameCapacity(
            inputFrameCount: 1024,
            inputSampleRate: 48000,
            outputSampleRate: 16000
        )

        XCTAssertEqual(capacity, 342)
    }

    func testConvertedOutputFrameCapacityUsesCeilFor44100To16k() {
        let capacity = convertedOutputFrameCapacity(
            inputFrameCount: 1024,
            inputSampleRate: 44100,
            outputSampleRate: 16000
        )

        XCTAssertEqual(capacity, 372)
    }

    func testWarmStateIsValidOnlyWhenSnapshotMatchesAndBufferWasReceived() {
        let snapshot = DefaultInputSnapshot(
            deviceID: AudioDeviceID(101),
            sampleRate: 48000,
            channelCount: 1
        )
        let warmState = RecordingPipelineWarmState(
            snapshot: snapshot,
            didReceiveConvertedBuffer: true,
            completedAt: Date()
        )

        XCTAssertTrue(warmState.isValid(for: snapshot))
        XCTAssertFalse(
            warmState.isValid(
                for: DefaultInputSnapshot(
                    deviceID: snapshot.deviceID,
                    sampleRate: 44100,
                    channelCount: snapshot.channelCount
                )
            )
        )
        XCTAssertFalse(
            warmState.isValid(
                for: DefaultInputSnapshot(
                    deviceID: AudioDeviceID(202),
                    sampleRate: snapshot.sampleRate,
                    channelCount: snapshot.channelCount
                )
            )
        )
        XCTAssertFalse(
            warmState.isValid(
                for: DefaultInputSnapshot(
                    deviceID: snapshot.deviceID,
                    sampleRate: snapshot.sampleRate,
                    channelCount: 2
                )
            )
        )

        let invalidWarmState = RecordingPipelineWarmState(
            snapshot: snapshot,
            didReceiveConvertedBuffer: false,
            completedAt: Date()
        )
        XCTAssertFalse(invalidWarmState.isValid(for: snapshot))
    }

    func testShouldForceRecordingPipelinePrewarmWhenWarmStateIsMissingOrInvalid() {
        let snapshot = DefaultInputSnapshot(
            deviceID: AudioDeviceID(303),
            sampleRate: 48000,
            channelCount: 1
        )

        XCTAssertTrue(
            shouldForceRecordingPipelinePrewarm(
                currentSnapshot: snapshot,
                warmState: nil
            )
        )

        let validWarmState = RecordingPipelineWarmState(
            snapshot: snapshot,
            didReceiveConvertedBuffer: true,
            completedAt: Date()
        )
        XCTAssertFalse(
            shouldForceRecordingPipelinePrewarm(
                currentSnapshot: snapshot,
                warmState: validWarmState
            )
        )

        let invalidWarmState = RecordingPipelineWarmState(
            snapshot: snapshot,
            didReceiveConvertedBuffer: false,
            completedAt: Date()
        )
        XCTAssertTrue(
            shouldForceRecordingPipelinePrewarm(
                currentSnapshot: snapshot,
                warmState: invalidWarmState
            )
        )
    }

    func testShouldForceRecordingPipelinePrewarmWhenWarmStateHasExpired() {
        let snapshot = DefaultInputSnapshot(
            deviceID: AudioDeviceID(404),
            sampleRate: 48000,
            channelCount: 1
        )
        let staleWarmState = RecordingPipelineWarmState(
            snapshot: snapshot,
            didReceiveConvertedBuffer: true,
            completedAt: Date(timeIntervalSinceNow: -301)
        )

        XCTAssertTrue(
            shouldForceRecordingPipelinePrewarm(
                currentSnapshot: snapshot,
                warmState: staleWarmState,
                now: Date()
            )
        )
    }

    func testRecordingStartupRetryPolicyAllowsOneRecoveryAttempt() {
        XCTAssertTrue(
            shouldRetryRecordingStartupAfterInitialBufferTimeout(
                completedAttempts: 1,
                maximumAttempts: 2
            )
        )

        XCTAssertFalse(
            shouldRetryRecordingStartupAfterInitialBufferTimeout(
                completedAttempts: 2,
                maximumAttempts: 2
            )
        )
    }
}
