import Foundation
import GroveInference

enum MeetingEngineChoice: String, Codable, CaseIterable, Identifiable {
    case automatic, sortformerStreaming, ultra8, community1

    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "자동 선택"
        case .sortformerStreaming: "Sortformer (최대 4명)"
        case .ultra8: "Ultra8 (최대 8명)"
        case .community1: "Community-1 (인원 지정 지원)"
        }
    }

    func configuration(mode: MeetingProcessingMode, count: Int?) throws -> InferenceConfiguration {
        let result: InferenceConfiguration
        switch self {
        case .automatic: result = try mode.configuration(speakerCount: count)
        case .sortformerStreaming:
            result = .init(expectedSpeakerCount: count, diarizationPreference: .sortformerStreaming)
        case .ultra8:
            result = .init(expectedSpeakerCount: count, diarizationPreference: .ultra8)
        case .community1:
            result = .init(expectedSpeakerCount: count, diarizationPreference: .community1,
                           speakerCountPolicy: count == nil ? .advisory : .exact)
        }
        _ = try result.resolvedEngine()
        return result
    }
}

struct MeetingInferencePlan: Equatable, Sendable {
    let configuration: InferenceConfiguration
    var channelConfigurations: [String: InferenceConfiguration]? = nil

    func configurations(for sourceIDs: [String]) throws -> [String: InferenceConfiguration] {
        guard !sourceIDs.isEmpty, Set(sourceIDs).count == sourceIDs.count else { throw TranscriptEditError.invalidDocument }
        _ = try configuration.resolvedEngine()
        if let channelConfigurations {
            guard Set(channelConfigurations.keys) == Set(sourceIDs) else {
                throw InferenceError.invalidOutput("각 녹음 채널의 화자 수를 지정해 주세요.")
            }
            for value in channelConfigurations.values { _ = try value.resolvedEngine() }
            return channelConfigurations
        }
        guard sourceIDs.count == 1 || configuration.expectedSpeakerCount == nil else {
            throw InferenceError.invalidOutput("전체 인원수를 두 채널에 중복 적용할 수 없습니다. 채널별로 지정해 주세요.")
        }
        return Dictionary(uniqueKeysWithValues: sourceIDs.map { ($0, configuration) })
    }
}

struct MeetingSpeakerOptions: Codable, Equatable {
    var mode: MeetingProcessingMode = .automatic
    var engineChoice: MeetingEngineChoice = .automatic
    var countText = ""
    var systemCountText = ""
    var microphoneCountText = ""

    init() {}

    private enum CodingKeys: String, CodingKey { case mode, engineChoice, countText, systemCountText, microphoneCountText }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(MeetingProcessingMode.self, forKey: .mode) ?? .automatic
        engineChoice = try values.decodeIfPresent(MeetingEngineChoice.self, forKey: .engineChoice) ?? .automatic
        countText = try values.decodeIfPresent(String.self, forKey: .countText) ?? ""
        systemCountText = try values.decodeIfPresent(String.self, forKey: .systemCountText) ?? ""
        microphoneCountText = try values.decodeIfPresent(String.self, forKey: .microphoneCountText) ?? ""
    }

    init(configuration: InferenceConfiguration?, channels: [String: InferenceConfiguration]? = nil) {
        mode = .init(configuration: configuration)
        if let preference = configuration?.diarizationPreference {
            engineChoice = MeetingEngineChoice(rawValue: preference.rawValue) ?? .automatic
        }
        if let count = configuration?.expectedSpeakerCount { countText = String(count) }
        if let channels {
            let preferences = Set(channels.values.map(\.diarizationPreference))
            if preferences.count == 1, let preference = preferences.first {
                engineChoice = MeetingEngineChoice(rawValue: preference.rawValue) ?? .automatic
            }
            if channels.values.contains(where: { $0.expectedSpeakerCount != nil }) { mode = .manualCount }
            if let count = channels["system"]?.expectedSpeakerCount { systemCountText = String(count) }
            if let count = channels["microphone"]?.expectedSpeakerCount { microphoneCountText = String(count) }
        }
    }

    var summary: String {
        guard mode == .manualCount else { return mode.label }
        if let count = try? Self.parseCount(countText) { return "\(count)명 지정" }
        return "인원 입력 필요"
    }

    func plan(isDual: Bool) throws -> MeetingInferencePlan {
        if mode == .manualCount, isDual {
            let system = try engineChoice.configuration(mode: mode, count: Self.parseCount(systemCountText))
            let microphone = try engineChoice.configuration(mode: mode, count: Self.parseCount(microphoneCountText))
            let base = try engineChoice.configuration(mode: .automatic, count: nil)
            return MeetingInferencePlan(configuration: base,
                channelConfigurations: ["system": system, "microphone": microphone])
        }
        return MeetingInferencePlan(configuration: try engineChoice.configuration(mode: mode,
            count: mode == .manualCount ? Self.parseCount(countText) : nil))
    }

    func validationMessage(isDual: Bool) -> String? {
        do { _ = try plan(isDual: isDual); return nil }
        catch { return error.localizedDescription }
    }

    private static func parseCount(_ input: String) throws -> Int {
        let normalized = input.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.allSatisfy({ $0.isASCII && $0.isNumber }),
              let count = Int(normalized), count > 0 else { throw InferenceError.invalidSpeakerCount }
        return count
    }
}
