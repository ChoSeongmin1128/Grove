import Foundation
import Testing
@testable import GroveApp

@MainActor
private final class FakeRecordingDevice: AudioRecordingDevice {
    var isRecording = false
    var currentTime: TimeInterval = 0
    var isMeteringEnabled = false
    var canResume = true
    func prepareToRecord() -> Bool { true }
    func record() -> Bool { isRecording = canResume; return canResume }
    func pause() { isRecording = false }
    func stop() { isRecording = false; currentTime = 0 }
    func updateMeters() {}
    func averagePower(forChannel channelNumber: Int) -> Float { -20 }
}

@MainActor
struct RecordingPauseTests {
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
