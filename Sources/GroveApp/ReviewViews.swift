import SwiftUI

struct ReviewInboxView: View {
    @ObservedObject var store: GroveStore

    private var items: [(MeetingRecord, TranscriptSegment)] {
        store.meetings.flatMap { meeting in
            meeting.transcript
                .filter { ($0.confidence ?? 1) < 0.72 || $0.isRevised }
                .map { (meeting, $0) }
        }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("검토할 구간이 없습니다", systemImage: "checkmark.circle")
                } description: {
                    Text("낮은 confidence, 교정 이력, 근거가 없는 항목만 여기에 모입니다.")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("다시 들어볼 구간")
                            .font(GroveTypography.title)
                        Text("전체 전사를 읽는 대신 판단이 필요한 부분만 확인합니다.")
                            .foregroundStyle(.secondary)
                        ForEach(items, id: \.1.id) { meeting, segment in
                            Button {
                                store.selection = .meeting(meeting.id)
                                store.selectedTab = .review
                            } label: {
                                ReviewCard(meeting: meeting, segment: segment)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(34)
                    .frame(maxWidth: 820, alignment: .leading)
                }
            }
        }
        .navigationTitle("검토함")
    }
}

struct MeetingReviewView: View {
    let meeting: MeetingRecord

    var body: some View {
        let segments = meeting.transcript.filter { ($0.confidence ?? 1) < 0.72 || $0.isRevised }
        if segments.isEmpty {
            ContentUnavailableView("확인이 필요한 구간이 없습니다", systemImage: "checkmark.circle")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(segments) { segment in
                        ReviewCard(meeting: meeting, segment: segment)
                    }
                }
                .padding(34)
                .frame(maxWidth: 820, alignment: .leading)
            }
        }
    }
}

private struct ReviewCard: View {
    let meeting: MeetingRecord
    let segment: TranscriptSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(meeting.title).font(.caption.weight(.semibold))
                Text(segment.startTime.clockString).font(.caption.monospacedDigit())
                Spacer()
                if let confidence = segment.confidence {
                    Text("confidence \(Int(confidence * 100))%")
                        .font(.caption2.monospaced())
                        .foregroundStyle(GroveTheme.evidence)
                }
            }
            Text(segment.displayedText)
                .foregroundStyle(GroveTheme.ink)
            if segment.isRevised {
                Text("원문: \(segment.text)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(GroveTheme.evidence.opacity(0.28))
        }
    }
}
