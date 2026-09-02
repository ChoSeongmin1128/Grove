@preconcurrency import AVFoundation
@preconcurrency import AudioToolbox
import CoreAudio
import Foundation

struct CaptureChannelStats: Codable, Sendable {
    var path: String
    var firstPresentationSeconds: Double?
    var lastPresentationSeconds: Double?
    var bufferCount: Int
    var detectedGapCount: Int
    var writtenFrameCount: Int64
}

struct CaptureSessionManifest: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case recording
        case finished
        case failed
    }

    var sessionID: UUID
    var status: Status
    var createdAt: Date
    var startedAt: Date?
    var endedAt: Date?
    var selectedContentDescription: String
    var systemAudio: CaptureChannelStats
    var microphone: CaptureChannelStats
    var errorMessage: String?
}

struct SystemAudioCaptureResult: Sendable {
    let systemAudioURL: URL
    let microphoneURL: URL
    let manifestURL: URL
    let duration: TimeInterval
    let systemBufferCount: Int
    let microphoneFrameCount: Int64
}

enum SystemAudioTapError: LocalizedError, Sendable {
    case alreadyRunning
    case coreAudio(String, OSStatus)
    case invalidFormat
    case noSystemAudio

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "이미 시스템 오디오 녹음이 진행 중입니다."
        case .coreAudio(let operation, let status):
            "\(operation)에 실패했습니다. Core Audio 상태: \(status.fourCharacterCode)"
        case .invalidFormat:
            "시스템 오디오 tap 형식을 읽지 못했습니다."
        case .noSystemAudio:
            "저장된 시스템 오디오 sample이 없습니다. 회의 앱에서 소리가 재생됐는지 확인해 주세요."
        }
    }
}

private final class TapFileWriter: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private let file: AVAudioFile
    private var firstSampleTime: Double?
    private var lastSampleTime: Double?
    private var previousEndSampleTime: Double?
    private var bufferCount = 0
    private var gapCount = 0
    private var frameCount: Int64 = 0
    private var capturedError: Error?

    init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: format.isInterleaved
        )
    }

    func append(_ buffer: AVAudioPCMBuffer, sampleTime: Double?) -> Double {
        lock.lock()
        defer { lock.unlock() }
        do {
            try file.write(from: buffer)
            bufferCount += 1
            frameCount += Int64(buffer.frameLength)
            if let sampleTime {
                if firstSampleTime == nil { firstSampleTime = sampleTime }
                if let previousEndSampleTime,
                   sampleTime - previousEndSampleTime > Double(buffer.frameLength) * 0.25 {
                    gapCount += 1
                }
                lastSampleTime = sampleTime
                previousEndSampleTime = sampleTime + Double(buffer.frameLength)
            }
            return Self.rootMeanSquare(buffer)
        } catch {
            capturedError = error
            return 0
        }
    }

    func snapshot(sampleRate: Double) -> CaptureChannelStats {
        lock.lock()
        defer { lock.unlock() }
        return CaptureChannelStats(
            path: url.path,
            firstPresentationSeconds: firstSampleTime.map { $0 / sampleRate },
            lastPresentationSeconds: lastSampleTime.map { $0 / sampleRate },
            bufferCount: bufferCount,
            detectedGapCount: gapCount,
            writtenFrameCount: frameCount
        )
    }

    func error() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return capturedError
    }

    private static func rootMeanSquare(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var sum = 0.0
        for channel in 0..<channelCount {
            for frame in 0..<frames {
                let value = Double(channels[channel][frame])
                sum += value * value
            }
        }
        return min(1, sqrt(sum / Double(max(1, frames * channelCount))) * 4)
    }
}

private final class TapLevelSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0.0

    func store(_ value: Double) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    func load() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

private func makeTapIOBlock(
    format: AVAudioFormat,
    writer: TapFileWriter,
    levelSink: TapLevelSink
) -> AudioDeviceIOBlock {
    { _, inputData, inputTime, _, _ in
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: inputData,
            deallocator: nil
        ) else { return }
        let sampleTime = inputTime.pointee.mFlags.contains(.sampleTimeValid)
            ? inputTime.pointee.mSampleTime
            : nil
        levelSink.store(writer.append(buffer, sampleTime: sampleTime))
    }
}

@MainActor
final class SystemAudioTapService: ObservableObject, @unchecked Sendable {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Double = 0

    private let queue = DispatchQueue(label: "grove.core-audio-tap", qos: .userInitiated)
    private var tapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private nonisolated(unsafe) var writer: TapFileWriter?
    private var streamFormat: AVAudioFormat?
    private var manifestURL: URL?
    private var microphoneURL: URL?
    private var sessionID: UUID?
    private var createdAt: Date?
    private var startedAt: Date?
    private var timer: Timer?
    private let levelSink = TapLevelSink()

    func start(sessionID: UUID, directory: URL, microphoneURL: URL) throws {
        guard !isRecording, !tapID.isValid else { throw SystemAudioTapError.alreadyRunning }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let systemURL = directory.appendingPathComponent("system-audio.caf")
        manifestURL = directory.appendingPathComponent("capture-manifest.json")
        self.microphoneURL = microphoneURL
        self.sessionID = sessionID
        createdAt = Date()

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Grove System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.bundleIDs = [Bundle.main.bundleIdentifier ?? "io.github.ChoSeongmin1128.Grove"]
        description.isProcessRestoreEnabled = true

        var newTapID = AudioObjectID.unknown
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else {
            throw SystemAudioTapError.coreAudio("시스템 오디오 tap 생성", status)
        }
        tapID = newTapID

        do {
            var basicDescription = try tapID.readTapStreamDescription()
            guard let format = AVAudioFormat(streamDescription: &basicDescription) else {
                throw SystemAudioTapError.invalidFormat
            }
            streamFormat = format

            let outputDeviceID = try AudioObjectID.readDefaultSystemOutputDevice()
            let outputUID = try outputDeviceID.readDeviceUID()
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Grove Audio Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[
                    kAudioSubDeviceUIDKey: outputUID,
                ]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            var aggregateID = AudioObjectID.unknown
            status = AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &aggregateID
            )
            guard status == noErr else {
                throw SystemAudioTapError.coreAudio("aggregate audio device 생성", status)
            }
            aggregateDeviceID = aggregateID

            let writer = try TapFileWriter(url: systemURL, format: format)
            self.writer = writer
            var procID: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(
                &procID,
                aggregateID,
                queue,
                makeTapIOBlock(format: format, writer: writer, levelSink: levelSink)
            )
            guard status == noErr, let procID else {
                throw SystemAudioTapError.coreAudio("audio IO callback 생성", status)
            }
            deviceProcID = procID

            startedAt = Date()
            try writeManifest(status: .recording)
            status = AudioDeviceStart(aggregateID, procID)
            guard status == noErr else {
                throw SystemAudioTapError.coreAudio("시스템 오디오 녹음 시작", status)
            }
            isRecording = true
            elapsed = 0
            let timer = Timer(
                timeInterval: 1,
                target: self,
                selector: #selector(updateElapsedAndManifest),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } catch {
            teardown()
            try? writeManifest(status: .failed, errorMessage: error.localizedDescription)
            throw error
        }
    }

    func stop() throws -> SystemAudioCaptureResult {
        guard isRecording,
              let writer,
              let streamFormat,
              let manifestURL,
              let microphoneURL else {
            throw SystemAudioTapError.noSystemAudio
        }
        elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? elapsed
        teardown()
        if let error = writer.error() {
            try? writeManifest(status: .failed, errorMessage: error.localizedDescription)
            throw error
        }
        let system = writer.snapshot(sampleRate: streamFormat.sampleRate)
        let microphone = Self.microphoneStats(url: microphoneURL)
        try writeManifest(status: .finished, system: system, microphone: microphone)
        guard system.bufferCount > 0 else { throw SystemAudioTapError.noSystemAudio }
        return SystemAudioCaptureResult(
            systemAudioURL: writer.url,
            microphoneURL: microphoneURL,
            manifestURL: manifestURL,
            duration: elapsed,
            systemBufferCount: system.bufferCount,
            microphoneFrameCount: microphone.writtenFrameCount
        )
    }

    func cancel(errorMessage: String) {
        guard tapID.isValid || aggregateDeviceID.isValid || isRecording else { return }
        teardown()
        try? writeManifest(status: .failed, errorMessage: errorMessage)
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        if aggregateDeviceID.isValid {
            _ = AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if let deviceProcID {
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if tapID.isValid { _ = AudioHardwareDestroyProcessTap(tapID) }
        deviceProcID = nil
        aggregateDeviceID = .unknown
        tapID = .unknown
        isRecording = false
        level = 0
    }

    @objc private func updateElapsedAndManifest() {
        if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
        level = levelSink.load()
        try? writeManifest(status: .recording)
    }

    private func writeManifest(
        status: CaptureSessionManifest.Status,
        errorMessage: String? = nil,
        system: CaptureChannelStats? = nil,
        microphone: CaptureChannelStats? = nil
    ) throws {
        guard let manifestURL,
              let microphoneURL,
              let sessionID,
              let createdAt else { return }
        let systemStats = system ?? writer?.snapshot(sampleRate: streamFormat?.sampleRate ?? 48_000)
            ?? CaptureChannelStats.empty(path: "")
        let microphoneStats = microphone ?? Self.microphoneStats(url: microphoneURL)
        let manifest = CaptureSessionManifest(
            sessionID: sessionID,
            status: status,
            createdAt: createdAt,
            startedAt: startedAt,
            endedAt: status == .finished || status == .failed ? Date() : nil,
            selectedContentDescription: "Core Audio global output tap",
            systemAudio: systemStats,
            microphone: microphoneStats,
            errorMessage: errorMessage
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    private static func microphoneStats(url: URL) -> CaptureChannelStats {
        guard let file = try? AVAudioFile(forReading: url) else {
            return .empty(path: url.path)
        }
        return CaptureChannelStats(
            path: url.path,
            firstPresentationSeconds: 0,
            lastPresentationSeconds: Double(file.length) / file.processingFormat.sampleRate,
            bufferCount: file.length > 0 ? 1 : 0,
            detectedGapCount: 0,
            writtenFrameCount: file.length
        )
    }
}

private extension CaptureChannelStats {
    static func empty(path: String) -> Self {
        .init(
            path: path,
            firstPresentationSeconds: nil,
            lastPresentationSeconds: nil,
            bufferCount: 0,
            detectedGapCount: 0,
            writtenFrameCount: 0
        )
    }
}

private extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)
    var isValid: Bool { self != .unknown }

    static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        try system.read(
            kAudioHardwarePropertyDefaultSystemOutputDevice,
            defaultValue: AudioDeviceID.unknown
        )
    }

    func readDeviceUID() throws -> String {
        try read(kAudioDevicePropertyDeviceUID, defaultValue: "" as CFString) as String
    }

    func readTapStreamDescription() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }

    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        defaultValue: T
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard status == noErr else {
            throw SystemAudioTapError.coreAudio("Core Audio property 크기 읽기", status)
        }
        var value = defaultValue
        status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw SystemAudioTapError.coreAudio("Core Audio property 읽기", status)
        }
        return value
    }
}

private extension OSStatus {
    var fourCharacterCode: String {
        let value = UInt32(bitPattern: self)
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return "'\(String(bytes: bytes, encoding: .ascii) ?? "????")'"
        }
        return String(self)
    }
}
