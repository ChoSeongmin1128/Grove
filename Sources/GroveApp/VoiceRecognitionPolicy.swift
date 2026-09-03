import Foundation
import GroveInference

/// Conservative, uncalibrated beta guardrails. Passing is a name suggestion, not
/// verified identity. The coordinator owns folder scope, consent, source integrity,
/// clean-span selection and exclusion of enrollment audio from query samples.
enum VoiceRecognitionPolicy {
    static let version = "voice-recognition-sample-v1"
    static let minimumEnrollmentSamples = 3
    static let minimumEnrollmentDuration: Double = 10
    static let minimumQuerySamples = 2
    static let minimumPairwiseSimilarity: Float = 0.80
    static let minimumSimilarity: Float = 0.85
    static let minimumMargin: Float = 0.15

    enum Reason: String, Codable, Equatable, Sendable {
        case insufficientSamples, insufficientDuration, invalidSample, mixedModels
        case duplicateOrOverlappingSamples, inconsistentSamples
        case noCompatibleProfiles, invalidEnrollment, belowSimilarity, ambiguousProfiles, conflictingVotes

        var message: String {
            switch self {
            case .insufficientSamples: "서로 다른 발화 구간이 부족합니다."
            case .insufficientDuration: "목소리를 등록하려면 합계 10초 이상의 발화가 필요합니다."
            case .invalidSample: "음성 특징이나 구간 정보가 유효하지 않습니다. 다시 선택해 주세요."
            case .mixedModels: "서로 다른 모델로 추출한 목소리는 함께 비교할 수 없습니다."
            case .duplicateOrOverlappingSamples: "같거나 겹친 음성을 별개의 등록 자료로 사용할 수 없습니다."
            case .inconsistentSamples: "선택한 구간의 목소리가 일관되지 않습니다. 다른 사람의 발화나 소음이 섞이지 않았는지 확인해 주세요."
            case .noCompatibleProfiles: "비교할 수 있는 등록된 목소리가 없습니다."
            case .invalidEnrollment: "등록된 목소리의 품질이나 구성을 확인해야 합니다."
            case .belowSimilarity: "등록된 목소리와 충분히 비슷하지 않아 이름을 추정하지 않았습니다."
            case .ambiguousProfiles: "여러 등록 화자의 목소리가 비슷하여 이름을 추정하지 않았습니다."
            case .conflictingVotes: "발화마다 추정되는 사람이 달라 이름을 붙이지 않았습니다."
            }
        }
    }

    struct PolicyError: LocalizedError, Equatable {
        let reason: Reason
        var errorDescription: String? { reason.message }
    }

    struct Decision: Codable, Equatable, Sendable {
        let profileID: UUID?
        let similarity: Float?
        let runnerUpMargin: Float?
        let supportingSamples: Int
        let reason: Reason?
        let policyVersion: String

        static func unknown(_ reason: Reason) -> Self {
            Self(profileID: nil, similarity: nil, runnerUpMargin: nil,
                 supportingSamples: 0, reason: reason, policyVersion: version)
        }
    }

    static func validateEnrollment(samples: [VoiceEnrollmentSample]) throws {
        guard (minimumEnrollmentSamples...5).contains(samples.count) else {
            throw PolicyError(reason: .insufficientSamples)
        }
        let voices = samples.map(\.voice)
        try validateVoices(voices)
        guard samples.allSatisfy({ sample in
            sample.start.isFinite && sample.end.isFinite && sample.start >= 0 && sample.end > sample.start
                && abs(sample.end - sample.start - sample.voice.speechDuration) <= 0.001
                && sample.audioSHA256.count == 64 && sample.audioSHA256.allSatisfy(\.isHexDigit)
        }) else { throw PolicyError(reason: .invalidSample) }
        guard voices.reduce(0, { $0 + $1.speechDuration }) >= minimumEnrollmentDuration - 1e-9 else {
            throw PolicyError(reason: .insufficientDuration)
        }
        // Equal source bytes count as the same recording even if imported under a new ID.
        for group in Dictionary(grouping: samples, by: { $0.audioSHA256.lowercased() }).values {
            guard Set(group.map(\.utteranceID)).count == group.count else {
                throw PolicyError(reason: .duplicateOrOverlappingSamples)
            }
            let ordered = group.sorted { $0.start < $1.start }
            guard zip(ordered, ordered.dropFirst()).allSatisfy({ $0.0.end <= $0.1.start }) else {
                throw PolicyError(reason: .duplicateOrOverlappingSamples)
            }
        }
        guard try isConsistent(voices) else { throw PolicyError(reason: .inconsistentSamples) }
    }

    /// The caller must supply independent clean spans and remove any candidate's
    /// enrollment audio from these queries. This pure policy never enrolls samples.
    static func evaluate(samples: [SpeakerVoicePrint], enrollments: [VoiceEnrollmentRecord]) -> Decision {
        guard (minimumQuerySamples...5).contains(samples.count) else { return .unknown(.insufficientSamples) }
        do {
            try validateVoices(samples)
            guard try isConsistent(samples) else { return .unknown(.inconsistentSamples) }
        } catch let error as PolicyError { return .unknown(error.reason) }
        catch { return .unknown(.invalidSample) }
        let model = samples[0].modelIdentifier
        let compatible = enrollments.filter { $0.modelIdentifier == model }
        guard !compatible.isEmpty else { return .unknown(.noCompatibleProfiles) }
        guard Set(compatible.map(\.profileID)).count == compatible.count else { return .unknown(.invalidEnrollment) }
        for record in compatible {
            guard record.samples.allSatisfy({ $0.voice.modelIdentifier == record.modelIdentifier }) else {
                return .unknown(.invalidEnrollment)
            }
            do { try validateEnrollment(samples: record.samples) }
            catch { return .unknown(.invalidEnrollment) }
        }

        var selected: UUID?
        var minimumScore: Float = 1
        var narrowestMargin: Float?
        for query in samples {
            var scored: [(UUID, Float)] = []
            for record in compatible {
                guard let score = medianSimilarity(query: query, enrollment: record.samples) else {
                    return .unknown(.invalidSample)
                }
                scored.append((record.profileID, score))
            }
            scored.sort { left, right in
                if left.1 == right.1 { return left.0.uuidString < right.0.uuidString }
                return left.1 > right.1
            }
            guard let winner = scored.first, winner.1.isFinite, winner.1 >= minimumSimilarity else {
                return .unknown(.belowSimilarity)
            }
            if scored.count > 1 {
                let margin = winner.1 - scored[1].1
                guard margin >= minimumMargin else { return .unknown(.ambiguousProfiles) }
                narrowestMargin = min(narrowestMargin ?? margin, margin)
            }
            guard selected == nil || selected == winner.0 else { return .unknown(.conflictingVotes) }
            selected = winner.0
            minimumScore = min(minimumScore, winner.1)
        }
        return Decision(profileID: selected, similarity: minimumScore, runnerUpMargin: narrowestMargin,
                        supportingSamples: samples.count, reason: nil, policyVersion: version)
    }

    private static func medianSimilarity(query: SpeakerVoicePrint, enrollment: [VoiceEnrollmentSample]) -> Float? {
        // Compare individual enrollment samples; never hide spread in a centroid.
        var values: [Float] = []
        for sample in enrollment {
            guard let similarity = try? query.cosineSimilarity(to: sample.voice) else { return nil }
            values.append(Float(similarity))
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) { return (values[middle - 1] + values[middle]) / 2 }
        return values[middle]
    }

    private static func validateVoices(_ voices: [SpeakerVoicePrint]) throws {
        guard let first = voices.first, !first.modelIdentifier.isEmpty,
              voices.allSatisfy({ voice in
                  voice.sampleCount == 1 && voice.speechDuration.isFinite
                      && voice.speechDuration >= 2 && voice.speechDuration <= 10
                      && voice.embedding.count == 256 && voice.embedding.allSatisfy(\.isFinite)
                      && voice.embedding.contains(where: { $0 != 0 })
              }) else { throw PolicyError(reason: .invalidSample) }
        guard voices.allSatisfy({ $0.modelIdentifier == first.modelIdentifier }) else {
            throw PolicyError(reason: .mixedModels)
        }
    }

    private static func isConsistent(_ samples: [SpeakerVoicePrint]) throws -> Bool {
        for left in samples.indices {
            for right in samples.indices where right > left {
                guard try samples[left].cosineSimilarity(to: samples[right]) >= Double(minimumPairwiseSimilarity) else { return false }
            }
        }
        return true
    }
}
