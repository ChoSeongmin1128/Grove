import Foundation
@preconcurrency import AVFoundation
import Testing
@testable import GroveApp

@MainActor
private final class FakeRecordingDevice: AudioRecordingDevice {
    var isRecording = false
    var currentTime: TimeInterval = 0
    var isMeteringEnabled = false
    var canResume = true
    var termination: (@Sendable () -> Void)?
    func prepareToRecord() -> Bool { true }
    func record() -> Bool { isRecording = canResume; return canResume }
    func pause() { isRecording = false }
    func stop() { isRecording = false; currentTime = 0 }
    func updateMeters() {}
    func averagePower(forChannel channelNumber: Int) -> Float { -20 }
    func observeTermination(_ handler: @escaping @Sendable () -> Void) { termination = handler }
}

@MainActor
struct RecordingPauseTests {
    @Test func stoppedDeviceFinalizesOnceAndPausedDeviceDoesNotFail() throws {
        let device = FakeRecordingDevice()
        let recorder = AudioRecorder(makeRecorder: { _, _ in device })
        var stops: [Double] = []
        recorder.onUnexpectedStop = { stops.append($0) }
        try recorder.start(to: URL(fileURLWithPath: "/tmp/unused.m4a"))
        device.currentTime = 4
        recorder.pause()
        recorder.updateMeter()
        #expect(stops.isEmpty && recorder.isRecording && recorder.isPaused)
        try recorder.resume()
        device.currentTime = 6
        recorder.updateMeter()
        device.stop()
        recorder.updateMeter()
        recorder.updateMeter()
        #expect(stops == [6])
        #expect(!recorder.isRecording && !recorder.isPaused && recorder.elapsed == 6)
    }

    @Test func backgroundCompletionAndOldCallbacksCannotStopANewerCapture() async throws {
        let device = FakeRecordingDevice()
        let recorder = AudioRecorder(makeRecorder: { _, _ in device })
        var stops = 0
        recorder.onUnexpectedStop = { _ in stops += 1 }
        try recorder.start(to: URL(fileURLWithPath: "/tmp/first.m4a"))
        let old = try #require(device.termination)
        recorder.stop()
        try recorder.start(to: URL(fileURLWithPath: "/tmp/second.m4a"))
        await Task.detached { old() }.value
        await Task.yield()
        #expect(recorder.isRecording && stops == 0)
        let current = try #require(device.termination)
        await Task.detached { current() }.value
        while recorder.isRecording { await Task.yield() }
        #expect(stops == 1)
        current()
        await Task.yield()
        #expect(stops == 1)
    }

    @Test func actualDelegateMayCompleteFromABackgroundQueue() async {
        let notified = await withCheckedContinuation { continuation in
            let delegate = RecordingDelegate(onTermination: { continuation.resume(returning: true) })
            DispatchQueue.global().async {
                delegate.audioRecorderDidFinishRecording(AVAudioRecorder(), successfully: false)
            }
        }
        #expect(notified)
    }
    @Test func pauseKeepsSessionAndUsesRecordedTimeRatherThanWallClock() throws {
        let device = FakeRecordingDevice()
        let recorder = AudioRecorder(makeRecorder: { _, _ in device })
        try recorder.start(to: URL(fileURLWithPath: "/tmp/unused.m4a"))
        device.currentTime = 12.5
        recorder.pause()
        #expect(recorder.isRecording)
        #expect(recorder.isPaused)
        #expect(!device.isRecording)
        #expect(recorder.elapsed == 12.5)
        #expect(recorder.level == 0)
        recorder.pause()
        try recorder.resume()
        #expect(!recorder.isPaused)
        device.currentTime = 16
        #expect(recorder.stop() == 16)
        #expect(!recorder.isRecording)
        #expect(!recorder.isPaused)
    }

    @Test func failedResumeAndStopWhilePausedPreserveDuration() throws {
        let device = FakeRecordingDevice()
        let recorder = AudioRecorder(makeRecorder: { _, _ in device })
        try recorder.start(to: URL(fileURLWithPath: "/tmp/unused.m4a"))
        device.currentTime = 7
        recorder.pause()
        device.canResume = false
        #expect(throws: RecordingError.self) { try recorder.resume() }
        #expect(recorder.isRecording && recorder.isPaused)
        #expect(recorder.stop() == 7)
        #expect(recorder.elapsed == 7)
    }
}
