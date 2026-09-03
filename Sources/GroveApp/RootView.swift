import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @ObservedObject var store: GroveStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var pendingImport: PendingImport?

    private struct PendingImport: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            GroveSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 310)
        } detail: {
            detail
                .background(GroveTheme.canvas)
        }
        .tint(GroveTheme.grove)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.isPresentingImporter = true
                } label: {
                    Label("파일 가져오기", systemImage: "square.and.arrow.down")
                }
                .disabled(store.isBusy)

                Button {
                    store.isPresentingNewMeeting = true
                } label: {
                    Label("새 회의", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isBusy)
            }
        }
        .sheet(isPresented: $store.isPresentingNewMeeting) {
            NewMeetingSheet(store: store)
        }
        .sheet(item: $pendingImport) { request in
            ImportRecordingOptionsSheet(store: store, source: request.url)
        }
        .sheet(item: $store.meetingToRename) { meeting in
            RecordingNameEditor(store: store, meeting: meeting)
        }
        .sheet(item: $store.meetingForOriginalFiles) { meeting in
            OriginalRecordingFilesSheet(store: store, meetingID: meeting.id)
        }
        .fileImporter(
            isPresented: $store.isPresentingImporter,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    pendingImport = PendingImport(url: url)
                }
            case .failure(let error):
                store.alertMessage = error.localizedDescription
            }
        }
        .alert(
            "Grove",
            isPresented: Binding(
                get: { store.alertMessage != nil },
                set: { if !$0 { store.alertMessage = nil } }
            )
        ) {
            Button("확인", role: .cancel) { store.alertMessage = nil }
        } message: {
            Text(store.alertMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                FolderMoveFeedbackView(store: store)
                if store.isRecording, let meeting = store.activeMeeting {
                    RecordingHUD(store: store, meeting: meeting)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 18)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.selection {
        case .library, .none:
            LibraryHomeView(store: store)
        case .unfiled:
            LibraryHomeView(store: store, showsUnfiled: true)
        case .folder(let id):
            LibraryHomeView(store: store, folderID: id)
        case .review:
            ReviewInboxView(store: store)
        case .glossary:
            GlossaryView(store: store)
        case .meeting(let id):
            if let meeting = store.meetings.first(where: { $0.id == id }) {
                MeetingDetailView(store: store, meeting: meeting)
            } else {
                ContentUnavailableView("회의를 찾을 수 없습니다", systemImage: "waveform.slash")
            }
        }
    }
}
