import SwiftUI

struct LibraryHomeView: View {
    @ObservedObject var store: GroveStore
    var folderID: UUID? = nil
    var showsUnfiled = false
    @State private var searchText = ""

    private var title: String { folderID.map { store.folderName($0) } ?? (showsUnfiled ? "미분류" : "모든 녹음") }
    private var isFolderLocation: Bool { folderID != nil || showsUnfiled }
    private var locationRecordings: [MeetingRecord] { isFolderLocation ? store.recordings(in: folderID) : store.meetings }
    private var recordings: [MeetingRecord] { MeetingFolderListing.search(locationRecordings, title: searchText) }
    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                searchField
                if let folderID { FolderSpeakerLibraryView(store: store, folderID: folderID) }
                if recordings.isEmpty {
                    emptyState
                } else {
                    recentMeetings
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
        .modifier(MeetingFolderDropZone(store: store, folderID: folderID, isEnabled: isFolderLocation))
        .onChange(of: folderID) { _, _ in searchText = "" }
        .onChange(of: showsUnfiled) { _, _ in searchText = "" }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(GroveTypography.title)
                    .foregroundStyle(GroveTheme.ink)
                Text(isFolderLocation ? "녹음을 끌어 옮기거나 ‘폴더로 이동’ 메뉴를 사용하세요." : "모든 폴더의 녹음을 모아 봅니다.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("녹음 시작") {
                store.isPresentingNewMeeting = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.isBusy)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("녹음 제목 검색", text: $searchText).textFieldStyle(.plain)
                .accessibilityLabel("현재 목록에서 녹음 제목 검색")
            if !searchText.isEmpty {
                Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("검색어 지우기")
            }
        }
        .padding(11)
        .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(GroveTheme.divider) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: isSearching ? "magnifyingglass" : (isFolderLocation ? (showsUnfiled ? "tray" : "folder") : "waveform"))
                .font(.system(size: 32)).foregroundStyle(.tertiary)
            Text(isSearching ? "검색 결과가 없습니다" : (isFolderLocation ? "이 위치에 녹음이 없습니다" : "저장한 녹음이 없습니다"))
                .font(GroveTypography.heading)
            if isSearching {
                Text("다른 제목으로 검색하거나 검색어를 지워 보세요.").foregroundStyle(.secondary)
                Button("검색어 지우기") { searchText = "" }
            } else {
                Text(isFolderLocation ? "최근 녹음을 이곳으로 끌어오거나 새 녹음을 저장할 수 있습니다." : "마이크로 녹음하거나 기존 음성·영상 파일을 가져오세요.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("녹음 시작") { store.isPresentingNewMeeting = true }.buttonStyle(.borderedProminent)
                    Button("파일 가져오기") { store.isPresentingImporter = true }
                }.disabled(store.isBusy)
            }
        }
        .multilineTextAlignment(.center).padding(24)
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private var recentMeetings: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Text(isSearching ? "검색 결과 \(recordings.count)개" : "녹음 \(recordings.count)개")
                .font(GroveTypography.label).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 14)
            ForEach(recordings) { meeting in
                let document = store.transcriptDocuments[meeting.id]
                let status = MeetingPresentationStatus(meeting: meeting, document: document)
                let reviewCount = document?.speakerReviewCount ?? 0
                Button {
                    store.selection = .meeting(meeting.id)
                } label: {
                    HStack(spacing: 16) {
                        StatusGlyph(status: status, isRecording: meeting.status == .recording, isProcessing: meeting.status == .processing)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(meeting.title)
                                .font(GroveTypography.body.weight(.medium)).lineLimit(2)
                                .foregroundStyle(GroveTheme.ink)
                            HStack(spacing: 12) {
                                Label(store.folderName(meeting.folderID), systemImage: store.library.folders.contains(where: { $0.id == meeting.folderID }) ? "folder" : "tray").lineLimit(1)
                                Text(meeting.startedAt, format: .dateTime.year().month().day().hour().minute())
                            }.font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                Text(status.label).foregroundStyle(status.isFailure ? Color.red : Color.secondary)
                                if reviewCount > 0 { Text("화자 확인 \(reviewCount)곳").foregroundStyle(GroveTheme.evidence) }
                            }.font(.caption)
                        }
                        Spacer()
                        if meeting.duration > 0 {
                            Text(meeting.duration.clockString).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .background(GroveTheme.surface)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(MeetingDragSource(store: store, meeting: meeting))
                .contextMenu {
                    RecordingManagementActions(store: store, meeting: meeting)
                    Divider()
                    MeetingMoveMenu(store: store, meeting: meeting)
                }
                Divider()
            }
        }
        .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(GroveTheme.divider)
        }
    }
}

private struct StatusGlyph: View {
    let status: MeetingPresentationStatus
    let isRecording: Bool
    let isProcessing: Bool

    var body: some View {
        Image(systemName: status.symbol)
            .font(.title2)
            .foregroundStyle(status.isFailure || isRecording ? Color.red : (isProcessing ? GroveTheme.revision : .secondary))
            .frame(width: 34, height: 34)
    }
}
