import SwiftUI

struct TranscriptView: View {
    let meeting: MeetingRecord
    @StateObject private var player = AudioPlayerController()

    var body: some View {
        if meeting.transcript.isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: emptySymbol)
            } description: {
                Text(emptyDescription)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(meeting.transcript) { segment in
                        TranscriptSegmentRow(
                            meeting: meeting,
                            segment: segment,
                            isPlaying: player.playingSegmentID == segment.id,
                            play: { player.play(meeting: meeting, segment: segment) }
                        )
                    }
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 24)
                .frame(maxWidth: 860, alignment: .leading)
            }
        }
    }

    private var emptyTitle: String {
        meeting.status == .recording ? "녹음을 안전하게 저장하고 있습니다" : "대화가 아직 없습니다"
    }

    private var emptySymbol: String {
        meeting.status == .recording ? "record.circle" : "waveform"
    }

    private var emptyDescription: String {
        meeting.status == .recording
            ? "회의를 종료하면 Apple 한국어 모델로 정확 전사를 시작합니다."
            : "음성 파일을 가져오거나 새 회의를 녹음해 주세요."
    }
}

private struct TranscriptSegmentRow: View {
    let meeting: MeetingRecord
    let segment: TranscriptSegment
    let isPlaying: Bool
    let play: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            evidenceSpine
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(segment.speaker)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(GroveTheme.grove.opacity(0.12), in: Capsule())
                    Button(segment.startTime.clockString, action: play)
                        .buttonStyle(.plain)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isPlaying ? GroveTheme.grove : .secondary)
                    if let confidence = segment.confidence {
                        Text("\(Int(confidence * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(confidence < 0.72 ? GroveTheme.evidence : .secondary)
                    }
                    if segment.isRevised {
                        Label("교정", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(GroveTheme.revision)
                    }
                }
                Text(segment.displayedText)
                    .font(.body)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                if segment.isRevised {
                    Text("원문: \(segment.text)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .strikethrough()
                }
            }
            .padding(.bottom, 26)
        }
    }

    private var evidenceSpine: some View {
        VStack(spacing: 0) {
            Button(action: play) {
                Circle()
                    .fill(isPlaying ? GroveTheme.grove : GroveTheme.evidence)
                    .frame(width: 10, height: 10)
            }
            .buttonStyle(.plain)
            Rectangle()
                .fill(GroveTheme.evidence.opacity(0.22))
                .frame(width: 1)
                .frame(minHeight: 78)
        }
        .padding(.top, 7)
    }
}
