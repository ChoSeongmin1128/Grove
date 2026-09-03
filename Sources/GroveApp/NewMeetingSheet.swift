import SwiftUI

struct NewMeetingSheet: View {
    @ObservedObject var store: GroveStore
    @State private var title = ""
    @State private var options: MeetingSpeakerOptions
    @State private var folderID: UUID?

    init(store: GroveStore) {
        self.store = store
        _options = State(initialValue: store.defaultSpeakerOptions)
        _folderID = State(initialValue: store.selectedFolderID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("새 회의")
                    .font(GroveTypography.title)
                Text("녹음 파일을 먼저 안전하게 저장한 뒤 전사를 시작합니다.")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("회의 제목", text: $title, prompt: Text("회의 제목 입력"))
                RecordingFolderPicker(store: store, folderID: $folderID)
                LabeledContent("입력", value: "마이크")
                MeetingSpeakerOptionsView(options: $options)
                LabeledContent("저장", value: "이 Mac에 녹음 파일 보관")
            }
            .formStyle(.grouped)

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text("마이크만 녹음하고 회의 종료 후 한국어로 전사합니다.")
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
