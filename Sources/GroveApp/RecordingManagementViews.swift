import SwiftUI
import UniformTypeIdentifiers

enum RecordingManagementError: Error, LocalizedError {
    case missingSource
    case recordingInProgress
    case exportInProgress
    case appClosing

    var errorDescription: String? {
        switch self {
        case .missingSource: "저장할 원본 파일을 찾을 수 없습니다."
        case .recordingInProgress: "녹음을 종료한 뒤 원본 파일을 저장해 주세요."
        case .exportInProgress: "다른 원본 파일을 저장하고 있습니다. 완료한 뒤 다시 시도해 주세요."
        case .appClosing: "앱을 종료하고 있습니다. 원본 파일 저장을 시작할 수 없습니다."
        }
    }
}

struct RecordingManagementActions: View {
    @ObservedObject var store: GroveStore
    let meeting: MeetingRecord

    var body: some View {
        Button("이름 변경…") { store.meetingToRename = meeting }
        Button("원본 파일…") { store.meetingForOriginalFiles = meeting }
    }
}

struct RecordingNameEditor: View {
    @ObservedObject var store: GroveStore
    let meeting: MeetingRecord
    @State private var title: String
    @State private var error: String?
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(store: GroveStore, meeting: MeetingRecord) {
        self.store = store
        self.meeting = meeting
        _title = State(initialValue: meeting.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("녹음 이름 변경").font(GroveTypography.heading)
            TextField("녹음 이름", text: $title)
                .textFieldStyle(.roundedBorder).focused($isFocused)
            Text("앱에 표시되는 이름만 변경합니다. 원본 파일과 전사는 그대로 유지됩니다.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("이름 변경") {
                    if store.renameMeeting(id: meeting.id, title: title) { dismiss() }
                    else {
                        error = store.alertMessage ?? "이름을 저장하지 못했습니다. 입력한 이름은 유지됩니다."
                        store.alertMessage = nil
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 420)
        .onAppear { isFocused = true }
    }
}

struct OriginalRecordingFilesSheet: View {
    @ObservedObject var store: GroveStore
    let meetingID: UUID
    @State private var error: String?
    @State private var notice: String?
    @State private var exportTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    private var meeting: MeetingRecord? { store.meetings.first { $0.id == meetingID } }
    private var sources: [OriginalRecordingFile] { meeting?.originalRecordingFiles ?? [] }
    private var isRecording: Bool { meeting?.status == .recording || store.activeMeetingID == meetingID }
    private var isExporting: Bool { store.exportingOriginalMeetingID == meetingID }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("원본 파일").font(GroveTypography.heading)
            Text(meeting?.title ?? "녹음을 찾을 수 없습니다")
                .font(.headline).lineLimit(2)
            Text("가져온 파일 또는 녹음한 파일을 원래 형식 그대로 저장합니다. 앱에 보관된 원본은 이동하거나 변경하지 않습니다.")
                .font(.callout).foregroundStyle(.secondary)
            if sources.isEmpty {
                Text("이 녹음에는 연결된 원본 파일이 없습니다.").foregroundStyle(.secondary)
            } else {
                ForEach(sources) { source in
                    VStack(alignment: .leading, spacing: 10) {
                        if sources.count > 1 { Text(source.label).font(.headline) }
                        Text(source.url.lastPathComponent).font(.callout).textSelection(.enabled)
                        Text(source.url.path).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if !isReadable(source.url) {
                            Text("현재 경로에서 원본 파일을 읽을 수 없습니다. 이동되거나 삭제되었는지 확인해 주세요.")
                                .font(.caption).foregroundStyle(.red)
                        }
                        HStack {
                            Button("Finder에서 보기") { reveal(source) }.disabled(!isReadable(source.url))
                            Button("경로 복사") { copyPath(source) }
                            Spacer()
                            Button("원본 파일 저장…") { save(source) }
                                .buttonStyle(.borderedProminent)
                                .disabled(!store.canExportOriginal(meetingID: meetingID) || !isReadable(source.url))
                        }
                    }
                    if source.id != sources.last?.id { Divider() }
                }
            }
            if isRecording {
                Text("녹음 중에는 경로만 확인할 수 있습니다. 원본 파일 저장은 녹음을 종료한 뒤 가능합니다.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let notice { Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                if isExporting {
                    ProgressView().controlSize(.small)
                    Text("원본 파일 저장 중…").font(.callout)
                    Button("저장 취소") { exportTask?.cancel() }
                }
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isExporting)
            }
        }
        .padding(24).frame(width: 580)
        .interactiveDismissDisabled(isExporting)
        .onDisappear { exportTask?.cancel() }
    }

    private func isReadable(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    private func reveal(_ source: OriginalRecordingFile) {
        guard isReadable(source.url) else { error = "현재 경로에서 원본 파일을 찾을 수 없습니다."; return }
        NSWorkspace.shared.activateFileViewerSelecting([source.url])
    }

    private func copyPath(_ source: OriginalRecordingFile) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(source.url.path, forType: .string) {
            error = nil
            notice = "원본 파일 경로를 복사했습니다."
        } else { error = "경로를 클립보드에 복사하지 못했습니다." }
    }

    private func save(_ source: OriginalRecordingFile) {
        guard let meeting, store.canExportOriginal(meetingID: meetingID) else { return }
        let panel = NSSavePanel()
        panel.title = "원본 파일 저장"
        panel.prompt = "저장"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        if let type = UTType(filenameExtension: source.url.pathExtension) { panel.allowedContentTypes = [type] }
        let title = sources.count > 1 ? "\(meeting.title) - \(source.label)" : meeting.title
        panel.nameFieldStringValue = OriginalRecordingExporter.suggestedFilename(title: title, source: source)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let replacingExisting = FileManager.default.fileExists(atPath: destination.path)
        error = nil
        notice = nil
        exportTask = Task {
            let access = destination.startAccessingSecurityScopedResource()
            defer { if access { destination.stopAccessingSecurityScopedResource() } }
            do {
                try await store.exportOriginal(meetingID: meetingID, sourceID: source.id,
                    to: destination, replacingExisting: replacingExisting)
                notice = "저장했습니다: \(destination.path)"
            } catch is CancellationError {
                notice = "저장을 취소했습니다. 원본 파일은 그대로 유지됩니다."
            } catch {
                self.error = "원본 파일을 저장하지 못했습니다. \(error.localizedDescription)"
            }
            exportTask = nil
        }
    }
}
