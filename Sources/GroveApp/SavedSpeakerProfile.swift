import Foundation
import GroveInference

struct SavedSpeakerProfile: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    let folderID: UUID
    var name: String
    var voice: SpeakerVoicePrint? = nil
    let sourceMeetingID: UUID
    let sourceRevisionID: UUID
    let sourceSpeakerID: UUID
    let createdAt: Date
}

struct SpeakerProfileMatch: Codable, Hashable, Sendable {
    let folderID: UUID
    let profileID: UUID
    let similarity: Float?
    let isConfirmed: Bool
}

enum VoiceProfileError: LocalizedError {
    case insufficientSpeech
    case recordingChanged
    case folderRequired
    var errorDescription: String? {
        switch self {
        case .insufficientSpeech: "겹치지 않는 발화가 2개 이상, 합계 6초 이상 필요합니다. 짧거나 화자가 섞인 구간은 목소리 저장에 사용하지 않습니다."
        case .recordingChanged: "처리 중 녹음이나 화자 정보가 바뀌었습니다. 변경 내용을 확인하고 다시 시도해 주세요."
        case .folderRequired: "녹음을 폴더에 먼저 옮겨 주세요. 저장한 목소리는 같은 폴더에서만 사용합니다."
        }
    }
}

enum VoiceProfileSelection {
    static func ranges(in document: TranscriptDocument, speakerID: UUID) throws -> [VoiceSampleRange] {
        var chosen: [VoiceSampleRange] = []
        let candidates = document.utterances.filter {
            $0.speakerID == speakerID && $0.endTime - $0.startTime >= 2.3
                && ($0.assignmentReviewReasons?.isEmpty ?? true)
        }.sorted { ($0.endTime - $0.startTime) > ($1.endTime - $1.startTime) }
        for utterance in candidates {
            let start = utterance.startTime + 0.15
            let end = min(utterance.endTime - 0.15, start + 10)
            guard !document.utterances.contains(where: {
                $0.id != utterance.id && $0.speakerID != speakerID
                    && $0.startTime < end && $0.endTime > start
            }), !chosen.contains(where: { $0.start < end && $0.end > start }) else { continue }
            chosen.append(VoiceSampleRange(start: start, end: end))
            if chosen.count == 5 { break }
        }
        guard chosen.count >= 2, chosen.reduce(0, { $0 + $1.end - $1.start }) >= 6 else {
            throw VoiceProfileError.insufficientSpeech
        }
        return chosen.sorted { $0.start < $1.start }
    }
}

enum SpeakerProfileMatcher {
    struct Match: Sendable {
        let speakerID: UUID
        let profile: SavedSpeakerProfile
        let similarity: Float
    }

    // Conservative beta thresholds, not a calibrated probability. Unknown/ambiguous
    // speakers stay anonymous; attendance counts never select a person's identity.
    static func matches(voices: [UUID: SpeakerVoicePrint], profiles: [SavedSpeakerProfile],
                        minimumSimilarity: Float = 0.75, minimumMargin: Float = 0.15) -> [Match] {
        var proposed: [Match] = []
        for (speakerID, voice) in voices {
            let ranked = profiles.compactMap { profile -> (SavedSpeakerProfile, Float)? in
                guard let savedVoice = profile.voice, voice.modelIdentifier == savedVoice.modelIdentifier,
                      let score = cosine(voice.embedding, savedVoice.embedding) else { return nil }
                return (profile, score)
            }.sorted { $0.1 > $1.1 }
            guard let first = ranked.first, first.1 >= minimumSimilarity,
                  ranked.count == 1 || first.1 - ranked[1].1 >= minimumMargin else { continue }
            proposed.append(Match(speakerID: speakerID, profile: first.0, similarity: first.1))
        }
        let uses = Dictionary(grouping: proposed, by: { $0.profile.id })
        return proposed.filter { uses[$0.profile.id]?.count == 1 }
    }

    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard !lhs.isEmpty, lhs.count == rhs.count, lhs.allSatisfy(\.isFinite), rhs.allSatisfy(\.isFinite) else { return nil }
        let a = sqrt(lhs.reduce(0) { $0 + $1 * $1 })
        let b = sqrt(rhs.reduce(0) { $0 + $1 * $1 })
        guard a > 0, b > 0 else { return nil }
        return max(-1, min(1, zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 } / (a * b)))
    }
}
