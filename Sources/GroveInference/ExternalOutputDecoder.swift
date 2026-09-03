import Foundation

public enum ExternalOutputDecoder {
    private struct ClusterLabel: Decodable {
        let value: String
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) { value = text }
            else { value = String(try container.decode(Int.self)) }
        }
    }

    private struct MossEnvelope: Decodable {
        struct Segment: Decodable {
            let start: Double
            let end: Double
            let text: String
            let speaker_id: ClusterLabel?
            let asr_chunk: Int?
        }
        let segments: [Segment]
        let hitTokenLimit: Bool?
        let hasUnparsedText: Bool?
        let processedAudioFrames: Int64?
        let inputAudioFrames: Int64?
    }

    private struct SortformerEnvelope: Decodable {
        struct Segment: Decodable {
            let startTimeSeconds: Double
            let endTimeSeconds: Double
            let speaker: ClusterLabel
        }
        let segments: [Segment]
    }

    private struct CommunityEnvelope: Decodable {
        struct Segment: Decodable {
            let start: Double
            let end: Double
            let speaker: ClusterLabel
        }
        let segments: [Segment]
    }

    private struct UltraEnvelope: Decodable {
        let schemaVersion: Int
        let engine: String
        let maxSpeakers: Int
        let speakerCountConstraint: Int?
        let modelRevision: String
        let modelSHA256: String
        let postprocessing: String
        let durationSeconds: Double
        let segments: [CommunityEnvelope.Segment]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, engine, maxSpeakers, speakerCountConstraint, modelRevision
            case modelSHA256, postprocessing, durationSeconds, segments
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard values.contains(.speakerCountConstraint), try values.decodeNil(forKey: .speakerCountConstraint) else {
                throw InferenceError.invalidOutput("Ultra8의 인원수 제약 메타데이터가 올바르지 않습니다.")
            }
            speakerCountConstraint = nil
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            engine = try values.decode(String.self, forKey: .engine)
            maxSpeakers = try values.decode(Int.self, forKey: .maxSpeakers)
            modelRevision = try values.decode(String.self, forKey: .modelRevision)
            modelSHA256 = try values.decode(String.self, forKey: .modelSHA256)
            postprocessing = try values.decode(String.self, forKey: .postprocessing)
            durationSeconds = try values.decode(Double.self, forKey: .durationSeconds)
            segments = try values.decode([CommunityEnvelope.Segment].self, forKey: .segments)
        }
    }

    public static func moss(_ data: Data, duration: Double) throws -> RawTranscription {
        let decoded = try JSONDecoder().decode(MossEnvelope.self, from: data)
        guard decoded.hasUnparsedText != true else { throw InferenceError.incompleteTranscription }
        if let processed = decoded.processedAudioFrames, let total = decoded.inputAudioFrames {
            guard total > 0, processed == total else { throw InferenceError.incompleteTranscription }
        } else if decoded.processedAudioFrames != nil || decoded.inputAudioFrames != nil {
            throw InferenceError.invalidOutput("전체 녹음 처리 여부를 확인할 수 없습니다.")
        }
        if decoded.segments.isEmpty, decoded.hitTokenLimit == false, decoded.hasUnparsedText == false,
           decoded.processedAudioFrames != nil {
            throw InferenceError.noSpeech
        }
        let result = RawTranscription(utterances: decoded.segments.map {
            RecognizedUtterance(start: $0.start, end: $0.end, text: mossBody($0.text, cluster: $0.speaker_id?.value),
                asrClusterID: $0.speaker_id?.value, asrChunkIndex: $0.asr_chunk)
        }, hitTokenLimit: decoded.hitTokenLimit ?? false)
        try result.validate(duration: duration)
        return result
    }

    private static func mossBody(_ text: String, cluster: String?) -> String {
        // MLXAudio 0.1.3 prepends this redundant formatting label in parseSegments.
        // Remove only the matching leading label, never bracketed words in the body.
        // The exact upstream text remains preserved in the worker's raw moss.json.
        guard let cluster, cluster.range(of: #"^S[0-9]+$"#, options: .regularExpression) != nil else { return text }
        let prefix = "[\(cluster)] "
        guard text.hasPrefix(prefix) else { return text }
        return String(text.dropFirst(prefix.count))
    }

    public static func diarization(_ data: Data, engine: DiarizationEngine, duration: Double) throws -> [DiarizationTurn] {
        let turns: [DiarizationTurn]
        switch engine {
        case .sortformerStreaming:
            let decoded = try JSONDecoder().decode(SortformerEnvelope.self, from: data)
            turns = decoded.segments.map { .init(start: $0.startTimeSeconds, end: $0.endTimeSeconds, clusterID: $0.speaker.value) }
        case .community1:
            let decoded = try JSONDecoder().decode(CommunityEnvelope.self, from: data)
            turns = decoded.segments.map { .init(start: $0.start, end: $0.end, clusterID: $0.speaker.value) }
        case .ultra8:
            let decoded = try JSONDecoder().decode(UltraEnvelope.self, from: data)
            guard decoded.schemaVersion == 1, decoded.engine == "ultra8", decoded.maxSpeakers == 8,
                  decoded.speakerCountConstraint == nil, decoded.modelRevision == Ultra8Model.revision,
                  decoded.modelSHA256 == Ultra8Model.sha256, decoded.postprocessing == Ultra8Model.postprocessing,
                  decoded.durationSeconds.isFinite, abs(decoded.durationSeconds - duration) < 0.02,
                  decoded.segments.allSatisfy({ segment in
                      guard let index = Int(segment.speaker.value) else { return false }
                      return (0..<8).contains(index) && segment.speaker.value == String(index)
                  }) else { throw InferenceError.invalidOutput("Ultra8 모델·후처리·전체 처리 길이가 일치하지 않습니다.") }
            turns = decoded.segments.map { .init(start: $0.start, end: $0.end, clusterID: $0.speaker.value) }
        }
        try SpeakerProjection.validate(turns, duration: duration, engine: engine)
        return turns
    }

    /// Some upstream CLIs print progress before/after their JSON result. Scan complete
    /// top-level objects, respecting braces inside quoted transcript strings.
    public static func segmentsObject(from output: Data) throws -> Data {
        guard output.count <= 64 * 1024 * 1024 else { throw InferenceError.invalidOutput("결과 파일이 너무 큽니다.") }
        let bytes = [UInt8](output)
        var depth = 0
        var start: Int?
        var quoted = false
        var escaped = false
        for (index, byte) in bytes.enumerated() {
            if start == nil {
                if byte == 123 { start = index; depth = 1; quoted = false; escaped = false }
                continue
            }
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            if byte == 34 { quoted = true }
            else if byte == 123 { depth += 1 }
            else if byte == 125 {
                depth -= 1
                if depth == 0, let begin = start {
                    let candidate = Data(bytes[begin...index])
                    if let object = try? JSONSerialization.jsonObject(with: candidate) as? [String: Any], object["segments"] is [Any] {
                        return candidate
                    }
                    start = nil
                }
            }
        }
        throw InferenceError.invalidOutput("구간이 포함된 JSON 결과가 없습니다.")
    }
}
