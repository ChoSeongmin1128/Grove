import SwiftUI

struct GroveSidebar: View {
    @ObservedObject var store: GroveStore

    var body: some View {
        List(selection: $store.selection) {
            Section {
                Label("회의", systemImage: "waveform")
                    .tag(SidebarDestination.library)
                Label("검토함", systemImage: "checklist")
                    .badge(totalReviewCount)
                    .tag(SidebarDestination.review)
                Label("사전", systemImage: "text.book.closed")
                    .tag(SidebarDestination.glossary)
            }

            Section("최근 회의") {
                ForEach(store.meetings) { meeting in
                    MeetingSidebarRow(meeting: meeting)
                        .tag(SidebarDestination.meeting(meeting.id))
                        .contextMenu {
                            Button("삭제", role: .destructive) {
                                store.deleteMeeting(meeting)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Grove")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(GroveTheme.grove)
                Text("이 Mac에서 처리")
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private var totalReviewCount: Int {
        store.meetings.reduce(0) { $0 + $1.reviewCount }
    }
}

private struct MeetingSidebarRow: View {
    let meeting: MeetingRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: meeting.status.symbol)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                Text(meeting.title)
                    .lineLimit(1)
                    .fontWeight(.medium)
            }
            HStack {
                Text(meeting.startedAt, format: .dateTime.month().day().hour().minute())
                Spacer()
                Text(meeting.duration.clockString)
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch meeting.status {
        case .recording: .red
        case .processing: GroveTheme.revision
        case .ready: GroveTheme.grove
        case .needsReview: GroveTheme.evidence
        case .failed: .red
        }
    }
}

extension TimeInterval {
    var clockString: String {
        let total = max(0, Int(self.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
