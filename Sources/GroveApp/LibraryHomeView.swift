import SwiftUI

struct LibraryHomeView: View {
    @ObservedObject var store: GroveStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if store.meetings.isEmpty {
                    emptyState
                } else {
                    recentMeetings
                }
            }
            .padding(36)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle("회의")
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("기억보다 근거를 남깁니다")
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                    .foregroundStyle(GroveTheme.ink)
                Text("녹음, 한국어 전사, 검토가 이 Mac 안에서 이어집니다.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("녹음 시작") {
                store.isPresentingNewMeeting = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            SignalMark()
                .frame(width: 88, height: 64)
            Text("첫 회의를 기록해 보세요")
                .font(.title2.weight(.semibold))
            Text("마이크로 바로 녹음하거나 기존 음성·영상 파일을 가져올 수 있습니다.")
                .foregroundStyle(.secondary)
            HStack {
                Button("새 회의") { store.isPresentingNewMeeting = true }
                    .buttonStyle(.borderedProminent)
                Button("파일 가져오기") { store.isPresentingImporter = true }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(GroveTheme.divider)
        }
    }

    private var recentMeetings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("최근 기록")
                .font(.headline)
            ForEach(store.meetings.prefix(8)) { meeting in
                Button {
                    store.selection = .meeting(meeting.id)
                } label: {
                    HStack(spacing: 16) {
                        StatusGlyph(status: meeting.status)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(meeting.title)
                                .font(.headline)
                                .foregroundStyle(GroveTheme.ink)
                            Text(meeting.startedAt, format: .dateTime.year().month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if meeting.reviewCount > 0 {
                            Label("\(meeting.reviewCount)개 검토", systemImage: "checklist")
                                .font(.caption)
                                .foregroundStyle(GroveTheme.evidence)
                        }
                        Text(meeting.duration.clockString)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .background(GroveTheme.surface)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
        .padding(20)
        .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).stroke(GroveTheme.divider)
        }
    }
}

private struct StatusGlyph: View {
    let status: MeetingStatus

    var body: some View {
        Image(systemName: status.symbol)
            .font(.title2)
            .foregroundStyle(status == .needsReview ? GroveTheme.evidence : GroveTheme.grove)
            .frame(width: 34, height: 34)
    }
}

private struct SignalMark: View {
    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach([18.0, 36, 54, 31, 45, 22], id: \.self) { height in
                Capsule()
                    .fill(GroveTheme.grove.opacity(0.82))
                    .frame(width: 7, height: height)
            }
        }
    }
}
