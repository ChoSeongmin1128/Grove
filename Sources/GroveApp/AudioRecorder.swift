@preconcurrency import AVFoundation
import Foundation

@MainActor
protocol AudioRecordingDevice: AnyObject {
    var isRecording: Bool { get }
    var currentTime: TimeInterval { get }
    var isMeteringEnabled: Bool { get set }
    func prepareToRecord() -> Bool
    func record() -> Bool
    func pause()
    func stop()
    func updateMeters()
    func averagePower(forChannel channelNumber: Int) -> Float
}

extension AVAudioRecorder: AudioRecordingDevice {}

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Double = 0

    private var recorder: (any AudioRecordingDevice)?
    private var meterTimer: Timer?
    private let makeRecorder: (URL, [String: Any]) throws -> any AudioRecordingDevice

    init(makeRecorder: @escaping (URL, [String: Any]) throws -> any AudioRecordingDevice = { try AVAudioRecorder(url: $0, settings: $1) }) {
        self.makeRecorder = makeRecorder
        super.init()
    }

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default:
            return false
        }
    }

    func start(to url: URL) throws {
        guard !isRecording else { throw RecordingError.couldNotStart }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128_000,
        ]
        let recorder = try makeRecorder(url, settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            throw RecordingError.couldNotStart
        }
        self.recorder = recorder
        isPaused = false
        elapsed = 0
        level = 0
        isRecording = true
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(
            timeInterval: 0.08,
            target: self,
            selector: #selector(updateMeter),
            userInfo: nil,
            repeats: true
        )
    }

    @discardableResult
    func stop() -> TimeInterval {
        let finalDuration = recorder?.currentTime ?? elapsed
        recorder?.stop()
        recorder = nil
        meterTimer?.invalidate()
        meterTimer = nil
        isRecording = false
        isPaused = false
        elapsed = finalDuration
        level = 0
        return finalDuration
    }

    func pause() {
        guard isRecording, !isPaused, let recorder else { return }
        recorder.pause()
        elapsed = recorder.currentTime
        isPaused = true
        level = 0
    }

    func resume() throws {
        guard isRecording, isPaused, let recorder else { return }
        guard recorder.record() else { throw RecordingError.couldNotStart }
        isPaused = false
    }

    @objc private func updateMeter() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        level = max(0, min(1, pow(10, Double(decibels) / 28)))
        elapsed = recorder.currentTime
    }
}

enum RecordingError: LocalizedError {
    case permissionDenied
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "마이크 접근이 꺼져 있습니다. 시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 Grove를 허용해 주세요."
        case .couldNotStart:
            "선택한 마이크로 녹음을 시작하지 못했습니다. 입력 장치 연결 상태를 확인해 주세요."
        }
    }
}
