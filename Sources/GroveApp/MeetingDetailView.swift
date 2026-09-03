import SwiftUI

struct MeetingDetailView: View {
    @ObservedObject var store: GroveStore
    let meeting: MeetingRecord
    @State private var showsTranscriptionOptions = false
    @State private var speakerOptions = MeetingSpeakerOptions()
    @State private var reviewOnly = false
    @State private var showsSpeakers = false
    private var isDual: Bool { meeting.audioPath == nil && meeting.systemAudioPath != nil && meeting.microphoneAudioPath != nil }
    private var document: TranscriptDocument? { store.transcriptDocuments[meeting.id] }
    private var presentation: MeetingPresentationStatus { .init(meeting: meeting, document: document) }
    private var currentCounts: [MeetingSpeakerCount] {
        guard let result = meeting.completedResult, result.revisionID == document?.revisionID else { return [] }
        return result.speakerCounts
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if meeting.captureMode == .systemAndMicrophone {
                Text("베타: 두 채널은 각각 전사합니다. 시각은 각 파일 기준이며 채널 간 화자는 자동 병합하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.bottom, 10)
            }
            if let detail = presentation.detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.bottom, 10)
            }
            Divider()
            TranscriptView(store: store, meeting: meeting, reviewOnly: $reviewOnly, showsSpeakers: $showsSpeakers)
                .id(meeting.id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(meeting.title)
        .onChange(of: meeting.id) { _, _ in reviewOnly = false; showsSpeakers = false }
        .sheet(isPresented: $showsTranscriptionOptions) {
            VStack(alignment: .leading, spacing: 18) {
                Text("다시 전사").font(GroveTypography.title)
                Text("원본 녹음으로 새 전사를 만듭니다. 현재 수정 내용은 이전 전사에 보관됩니다.")
                    .foregroundStyle(.secondary)
                MeetingSpeakerOptionsView(options: $speakerOptions, isDual: isDual)
                HStack {
                    Spacer()
                    Button("취소") { showsTranscriptionOptions = false }.keyboardShortcut(.cancelAction)
                    Button("전사 시작") {
                        guard let plan = try? speakerOptions.plan(isDual: isDual) else { return }
                        showsTranscriptionOptions = false
                        Task { await store.transcribeMeeting(id: meeting.id, plan: plan) }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(store.isBusy || (try? speakerOptions.plan(isDual: isDual)) == nil)
                }
            }.padding(24).frame(width: 440)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(meeting.title)
                        .font(GroveTypography.title)
                        .foregroundStyle(GroveTheme.ink)
                        .lineLimit(2)
                    Button { store.meetingToRename = meeting } label: {
                        Image(systemName: "pencil").font(.body)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("녹음 이름 변경")
                    .help("녹음 이름 변경")
                }
                Spacer(minLength: 8)
                Button("원본 파일…") { store.meetingForOriginalFiles = meeting }
                MeetingMoveMenu(store: store, meeting: meeting)
                processingControls
            }
            HStack(spacing: 10) {
                Text(store.folderName(meeting.folderID))
                Label(presentation.label, systemImage: presentation.symbol)
                if let engines = store.transcriptDocuments[meeting.id]?.sourceDiarizationEngines, !engines.isEmpty {
                    Text(Set(engines.values.map { $0 == .ultra8 ? "Ultra8" : $0 == .sortformerStreaming ? "Sortformer" : "Community-1" }).sorted().joined(separator: ", "))
                }
                Text(meeting.startedAt, format: .dateTime.year().month().day().hour().minute())
                if meeting.duration > 0 { Text(meeting.duration.clockString).monospacedDigit() }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let document {
                HStack(spacing: 12) {
                    Button("배정된 화자 \(Set(document.utterances.compactMap(\.speakerID)).count)명") { showsSpeakers = true }
                    ForEach(currentCounts.filter(\.isMismatch)) { count in
                        Button(count.label) { showsSpeakers = true }
                            .help("이번 전사의 입력 인원과 모델 감지 인원입니다. 화자 목록에서 확인할 수 있습니다.")
                    }
                    if document.speakerReviewCount > 0 {
                        Button("화자 확인 \(document.speakerReviewCount)곳") { reviewOnly = true }
                    }
                }
                .font(.callout)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(GroveTheme.surface)
    }

    @ViewBuilder
    private var processingControls: some View {
        if store.processingMeetingID == meeting.id {
            VStack(alignment: .trailing, spacing: 7) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(store.processingStage ?? "처리 중").font(.caption)
                }
                Button("처리 중단") { store.cancelProcessing() }
            }
        } else if meeting.audioPath != nil || meeting.systemAudioPath != nil || meeting.microphoneAudioPath != nil {
            Button(presentation.canRetry ? "전사 다시 시도…" : "다시 전사…") {
                speakerOptions = .init(configuration: meeting.inferenceConfiguration, channels: meeting.channelInferenceConfigurations)
                showsTranscriptionOptions = true
            }.disabled(store.isBusy)
        }
    }
}
