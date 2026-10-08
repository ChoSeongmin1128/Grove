import SwiftUI

struct NewMeetingSheet: View {
    @ObservedObject var store: GroveStore
    @State private var title = ""
    @State private var options: MeetingSpeakerOptions
    @State private var folderID: UUID?
    @State private var showsOptions = false

    init(store: GroveStore) {
        self.store = store
        _options = State(initialValue: store.defaultSpeakerOptions)
        _folderID = State(initialValue: store.selectedFolderID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("새 회의")
                .font(GroveTypography.title)

            Form {
                TextField("회의 제목", text: $title, prompt: Text("회의 제목 입력"))
                RecordingFolderPicker(store: store, folderID: $folderID)
                LabeledContent("입력", value: "마이크")
                DisclosureGroup("전사 옵션", isExpanded: $showsOptions) {
                    MeetingSpeakerOptionsView(options: $options)
                }
            }
            .formStyle(.grouped)

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text("녹음을 마치면 전사가 시작됩니다.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("취소") { store.isPresentingNewMeeting = false }
                    .keyboardShortcut(.cancelAction)
                Button("녹음 시작") {
                    Task {
                        await store.beginRecording(
                            title: title,
                            glossaryProfile: "사전 없음",
                            plan: try? options.plan(isDual: false), folderID: folderID
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(store.isBusy || (try? options.plan(isDual: false)) == nil)
            }
        }
        .padding(28)
        .frame(width: 520)
    }
}
