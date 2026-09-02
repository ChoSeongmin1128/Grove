import Foundation

enum MeetingStatus: String, Codable, CaseIterable, Sendable {
    case recording
    case processing
    case ready
    case needsReview
    case failed

    var label: String {
        switch self {
        case .recording: "녹음 중"
        case .processing: "정확 전사 중"
        case .ready: "완료"
        case .needsReview: "확인 필요"
        case .failed: "처리 실패"
        }
    }

    var symbol: String {
        switch self {
        case .recording: "record.circle.fill"
        case .processing: "waveform.badge.magnifyingglass"
        case .ready: "checkmark.circle.fill"
        case .needsReview: "exclamationmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }
}

enum CaptureMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case microphone = "마이크"
    case systemAndMicrophone = "시스템 + 마이크"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .microphone: "mic.fill"
        case .systemAndMicrophone: "rectangle.on.rectangle.and.waveform"
        }
    }
}

struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var startTime: TimeInterval
    var endTime: TimeInterval
    var speaker: String
    var text: String
    var confidence: Double?
    var revisedText: String?

    var displayedText: String { revisedText ?? text }
    var isRevised: Bool { revisedText != nil && revisedText != text }
}

struct EvidenceClaim: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case decision
        case action
        case summary
    }

    var id: UUID = UUID()
    var kind: Kind
    var text: String
    var owner: String?
    var sourceSegmentIDs: [UUID]
    var isReviewed: Bool
}

struct MeetingRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var startedAt: Date
    var duration: TimeInterval
    var status: MeetingStatus
    var audioPath: String?
    var systemAudioPath: String? = nil
    var microphoneAudioPath: String? = nil
    var captureManifestPath: String? = nil
    var captureMode: CaptureMode? = nil
    var glossaryProfile: String
    var transcript: [TranscriptSegment]
    var claims: [EvidenceClaim]
    var errorMessage: String?

    var reviewCount: Int {
        transcript.filter { ($0.confidence ?? 1) < 0.72 || $0.isRevised }.count
            + claims.filter { !$0.isReviewed }.count
    }
}

struct GlossaryTerm: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var canonical: String
    var observedForms: [String]
    var isEnabled: Bool
}

enum SidebarDestination: Hashable {
    case library
    case review
    case glossary
    case meeting(UUID)
}

enum MeetingTab: String, CaseIterable, Identifiable {
    case minutes = "회의록"
    case transcript = "대화"
    case review = "검토"

    var id: String { rawValue }
}
