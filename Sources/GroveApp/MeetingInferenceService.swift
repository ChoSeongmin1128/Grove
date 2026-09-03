import Foundation
import GroveInference

protocol MeetingInferenceRunning: Sendable {
    func run(source: URL, configuration: InferenceConfiguration, directory: URL,
             progress: @Sendable (String) async -> Void) async throws -> InferenceResult
}

struct BundledMeetingInferenceService: MeetingInferenceRunning {
    let appBundle: URL
    let applicationSupport: URL

    func run(source: URL, configuration: InferenceConfiguration, directory: URL,
             progress: @Sendable (String) async -> Void) async throws -> InferenceResult {
        let backend = try backend(configuration: configuration)
        return try await NativeInferencePipeline(backend: backend).runRecording(
            source: source, configuration: configuration, directory: directory, progress: progress)
    }

    func backend(configuration: InferenceConfiguration) throws -> NativeInferenceBackend {
        let helpers = appBundle.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let moss = helpers.appendingPathComponent("Moss.bundle/Contents/MacOS/MossHarness")
        let sortformer = helpers.appendingPathComponent("fluidaudiocli")
        let community = helpers.appendingPathComponent("speech")
        let ultra = helpers.appendingPathComponent("grove-ultra8")
        let engine = try configuration.resolvedEngine()
        let diarizer: URL
        switch engine {
        case .sortformerStreaming: diarizer = sortformer
        case .community1: diarizer = community
        case .ultra8: diarizer = ultra
        }
        for executable in [moss, diarizer] {
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw InferenceError.missingExecutable(executable.lastPathComponent)
            }
        }
        let ultraModel = Ultra8Model.url(in: applicationSupport)
        if engine == .ultra8 && !FileManager.default.isReadableFile(atPath: ultraModel.path) {
            throw InferenceError.invalidOutput("Ultra8 로컬 모델이 준비되지 않았습니다. 다른 엔진으로 자동 변경하지 않습니다.")
        }
        let model = applicationSupport.appendingPathComponent(
            "Models/hub/models--OpenMOSS-Team--MOSS-Transcribe-Diarize/snapshots/704aa4a9c304e8520be88901e0d1960158ef5b15", isDirectory: true)
        for file in ["config.json", "tokenizer.json", "tokenizer_config.json", "processor_config.json", "model-00000-of-00001.safetensors"] {
            guard FileManager.default.isReadableFile(atPath: model.appendingPathComponent(file).path) else {
                throw InferenceError.invalidOutput("로컬 전사 모델이 준비되지 않았습니다. 이 베타는 미리 설치한 MOSS 모델을 사용합니다.")
            }
        }
        return NativeInferenceBackend(mossExecutable: moss, mossModelDirectory: model,
            sortformerExecutable: sortformer, communityExecutable: community,
            ultra8Executable: ultra, ultra8Model: ultraModel)
    }
}

enum MeetingProcessingMode: String, Codable, CaseIterable, Identifiable {
    case automatic
    case manualCount

    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "자동 추정"
        case .manualCount: "인원 입력"
        }
    }
    func configuration(speakerCount: Int? = nil) throws -> InferenceConfiguration {
        switch self {
        case .automatic: return .init(diarizationPreference: .automatic)
        case .manualCount:
            guard let speakerCount, speakerCount > 0 else { throw InferenceError.invalidSpeakerCount }
            return .init(expectedSpeakerCount: speakerCount, diarizationPreference: .automatic,
                         speakerCountPolicy: speakerCount <= 8 ? .advisory : .exact)
        }
    }
    init(configuration: InferenceConfiguration?) {
        if configuration?.expectedSpeakerCount != nil {
            self = .manualCount
        } else { self = .automatic }
    }
}

struct ChannelInference: Codable, Sendable {
    let sourceID: String
    let result: InferenceResult

    var speakerCountWarning: String? {
        guard let expected = result.configuration.expectedSpeakerCount else { return nil }
        let detected = Set(result.rawDiarization.map(\.clusterID)).count
        guard expected != detected else { return nil }
        let prefix = sourceID == "system" ? "컴퓨터 소리: " : sourceID == "microphone" ? "마이크: " : ""
        return "\(prefix)입력한 인원은 \(expected)명이지만 감지된 화자는 \(detected)명입니다. 화자 배정을 확인해 주세요."
    }
}

struct MeetingInferenceArchive: Codable {
    let revisionID: UUID
    let channels: [ChannelInference]
}

extension TranscriptDocument {
    static func preservingChannels(_ channels: [ChannelInference]) throws -> TranscriptDocument {
        guard !channels.isEmpty, Set(channels.map(\.sourceID)).count == channels.count else {
            throw TranscriptEditError.invalidDocument
        }
        if channels.count == 1, let channel = channels.first {
            return try preservingInference(channel.result, sourceChannelID: channel.sourceID)
        }
        var speakers: [MeetingSpeaker] = []
        var utterances: [DocumentUtterance] = []
        for channel in channels {
            let document = try preservingInference(channel.result, sourceChannelID: channel.sourceID)
            // Channel-local clusters do not identify the same person across recordings.
            // Keep separate IDs even when both workers label a cluster "Speaker 0".
            for var speaker in document.speakers {
                speaker.order = speakers.count
                speaker.name = "화자 \(speakers.count + 1)"
                speakers.append(speaker)
            }
            utterances.append(contentsOf: document.utterances)
        }
        return try TranscriptDocument(speakers: speakers, utterances: utterances.sorted { $0.startTime < $1.startTime },
            sourceDiarizationEngines: Dictionary(uniqueKeysWithValues: channels.map { ($0.sourceID, $0.result.diarizationEngine) }))
    }
}
