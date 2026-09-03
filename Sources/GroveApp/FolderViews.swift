import SwiftUI

struct RecordingFolderPicker: View {
    @ObservedObject var store: GroveStore
    @Binding var folderID: UUID?

    var body: some View {
        Picker("폴더", selection: $folderID) {
            Text("미분류").tag(nil as UUID?)
            ForEach(store.library.folders) { folder in
                Text(folder.name).tag(Optional(folder.id))
            }
        }
    }
}

struct MeetingMoveMenu: View {
    @ObservedObject var store: GroveStore
    let meeting: MeetingRecord

    var body: some View {
        Menu("폴더로 이동") {
            Button("미분류") { store.moveMeeting(id: meeting.id, to: nil) }
                .disabled(meeting.folderID == nil)
            ForEach(store.library.folders) { folder in
                Button(folder.name) { store.moveMeeting(id: meeting.id, to: folder.id) }
                    .disabled(meeting.folderID == folder.id)
            }
        }
        .disabled(!store.canMoveMeeting(id: meeting.id))
    }
}

struct MeetingDragSource: ViewModifier {
    @ObservedObject var store: GroveStore
    let meeting: MeetingRecord

    @ViewBuilder
    func body(content: Content) -> some View {
        if store.canMoveMeeting(id: meeting.id) {
            content.draggable(store.folderTransfer(for: meeting.id)) {
                Label(meeting.title, systemImage: "waveform")
                    .font(GroveTypography.label).lineLimit(1)
                    .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        } else { content }
    }
}

struct MeetingFolderDropZone: ViewModifier {
    @ObservedObject var store: GroveStore
    let folderID: UUID?
    var isEnabled = true
    @State private var isTargeted = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .contentShape(Rectangle())
                .background(isTargeted ? GroveTheme.grove.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isTargeted ? GroveTheme.grove : .clear, lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
                .dropDestination(for: MeetingFolderTransfer.self) { items, _ in
                    store.acceptFolderDrop(items, to: folderID)
                } isTargeted: { isTargeted = $0 }
                .accessibilityHint("이 위치로 녹음을 끌어 옮길 수 있습니다. 녹음의 폴더로 이동 메뉴도 사용할 수 있습니다.")
        } else { content }
    }
}

struct FolderMoveFeedbackView: View {
    @ObservedObject var store: GroveStore

    var body: some View {
        if let feedback = store.folderMoveFeedback {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(GroveTheme.grove)
                Text(feedback.message).font(GroveTypography.label)
                Button { store.dismissFolderMoveFeedback(id: feedback.id) } label: {
                    Image(systemName: "xmark").font(.caption)
                }.buttonStyle(.plain).accessibilityLabel("이동 알림 닫기")
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(GroveTheme.divider) }
            .frame(maxWidth: 560)
            .padding(12)
            .task(id: feedback.id) {
                do { try await Task.sleep(for: .seconds(4)) }
                catch { return }
                store.dismissFolderMoveFeedback(id: feedback.id)
            }
        }
    }
}

struct FolderNameEditor: View {
    let title: String
    let save: (String) -> Bool
    @State var name: String
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(GroveTypography.heading)
            TextField("폴더 이름", text: $name).textFieldStyle(.roundedBorder)
            if failed { Text("저장하지 못했습니다. 입력한 이름은 유지됩니다.").foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("저장") { if save(name) { dismiss() } else { failed = true } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 380)
    }
}

struct FolderSpeakerLibraryView: View {
    @ObservedObject var store: GroveStore
    let folderID: UUID
    @State private var removingProfile: SavedSpeakerProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("저장한 화자").font(GroveTypography.heading)
            let profiles = store.speakerProfiles(in: folderID)
            if profiles.isEmpty {
                Text("녹음의 화자 목록에서 이름을 저장하고, 다음 녹음의 화자에 직접 연결할 수 있습니다.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(profiles) { profile in
                    HStack {
                        Image(systemName: "person.wave.2").foregroundStyle(.secondary)
                        Text(profile.name)
                        Spacer()
                        Button("삭제") { removingProfile = profile }.disabled(store.isBusy)
                    }
                }
                Text("같은 폴더에서만 사용할 수 있습니다. 목소리를 이용한 자동 연결은 아직 제공하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .alert("저장한 화자를 삭제할까요?", isPresented: Binding(get: { removingProfile != nil }, set: { if !$0 { removingProfile = nil } })) {
            Button("취소", role: .cancel) { removingProfile = nil }
            Button("화자 삭제", role: .destructive) {
                if let profile = removingProfile { _ = store.removeSpeakerProfile(id: profile.id) }
                removingProfile = nil
            }
        } message: {
            Text("이 폴더에서 재사용할 화자 정보를 삭제합니다. 기존 녹음과 전사의 화자 이름은 바뀌지 않습니다.")
        }
    }
}

struct SaveSpeakerProfileSheet: View {
    @ObservedObject var store: GroveStore
    let meeting: MeetingRecord
    let speaker: MeetingSpeaker
    @State private var name: String
    @State private var confirmed = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(store: GroveStore, meeting: MeetingRecord, speaker: MeetingSpeaker) {
        self.store = store
        self.meeting = meeting
        self.speaker = speaker
        _name = State(initialValue: speaker.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("폴더에 화자 저장").font(GroveTypography.heading)
            Text("‘\(store.folderName(meeting.folderID))’ 안의 다음 녹음에서 같은 사람에게 이 이름을 연결할 수 있습니다.")
                .foregroundStyle(.secondary)
            TextField("화자 이름", text: $name).textFieldStyle(.roundedBorder)
            Toggle("이 화자의 이름과 발화를 확인했습니다", isOn: $confirmed)
                .toggleStyle(.checkbox)
            Text("이름만 이 Mac에 저장합니다. 이번 베타는 목소리를 자동으로 연결하지 않으며, 음성 특징도 저장하지 않습니다.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if store.isSavingSpeakerProfile { ProgressView().controlSize(.small); Text("화자 저장 중").font(.caption) }
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.isSavingSpeakerProfile)
                Button("화자 저장") {
                    Task {
                        if await store.saveSpeakerProfile(meetingID: meeting.id, speakerID: speaker.id, name: name) { dismiss() }
                        else { error = store.alertMessage ?? "화자를 저장하지 못했습니다."; store.alertMessage = nil }
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(!confirmed || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isBusy)
            }
        }.padding(24).frame(width: 480).interactiveDismissDisabled(store.isSavingSpeakerProfile)
    }
}
