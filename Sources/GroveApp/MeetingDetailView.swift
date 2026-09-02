import SwiftUI

struct MeetingDetailView: View {
    @ObservedObject var store: GroveStore
    let meeting: MeetingRecord

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch store.selectedTab {
                case .minutes:
                    MinutesView(meeting: meeting)
                case .transcript:
                    TranscriptView(meeting: meeting)
                case .review:
                    MeetingReviewView(meeting: meeting)
                }
            }
        }
        .navigationTitle(meeting.title)
        .inspector(isPresented: .constant(true)) {
            MeetingInspector(meeting: meeting, processingStage: store.processingStage)
                .inspectorColumnWidth(min: 220, ideal: 260, max: 320)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(meeting.title)
                    .font(.system(size: 27, weight: .semibold, design: .serif))
                    .foregroundStyle(GroveTheme.ink)
                HStack(spacing: 10) {
                    Label(meeting.status.label, systemImage: meeting.status.symbol)
                    Text(meeting.startedAt, format: .dateTime.year().month().day().hour().minute())
                    Text(meeting.duration.clockString).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("보기", selection: $store.selectedTab) {
                ForEach(MeetingTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(GroveTheme.surface)
    }
}

private struct MeetingInspector: View {
    let meeting: MeetingRecord
    let processingStage: String?

    var body: some View {
        Form {
            Section("처리") {
                LabeledContent("상태", value: meeting.status.label)
                LabeledContent("전사", value: "Apple ko-KR")
                LabeledContent(
                    "입력",
                    value: (meeting.captureMode ?? .microphone).rawValue
                )
                if let processingStage {
                    Label(processingStage, systemImage: "gearshape.2")
                        .foregroundStyle(GroveTheme.revision)
                }
            }
            Section("근거") {
                LabeledContent("대화 구간", value: "\(meeting.transcript.count)")
                LabeledContent("회의록 항목", value: "\(meeting.claims.count)")
                LabeledContent("검토 필요", value: "\(meeting.reviewCount)")
            }
            Section("사전 snapshot") {
                Text(meeting.glossaryProfile)
                Text("회의 시작 시점의 승인 용어만 적용")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = meeting.errorMessage {
                Section("오류") {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("세부 정보")
    }
}
