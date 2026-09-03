import Foundation
import GroveInference

@MainActor
final class GroveStore: ObservableObject {
    @Published var meetings: [MeetingRecord] = []
    @Published var glossaryTerms: [GlossaryTerm] = []
    @Published var selection: SidebarDestination? = .library
    @Published var selectedTab: MeetingTab = .transcript
    @Published var isPresentingNewMeeting = false
    @Published var isPresentingImporter = false
    @Published var alertMessage: String?
    @Published var meetingToRename: MeetingRecord?
    @Published var meetingForOriginalFiles: MeetingRecord?
    @Published private(set) var exportingOriginalMeetingID: UUID?
    @Published private(set) var isPreparingToQuit = false
    @Published var activeMeetingID: UUID?
    @Published var processingStage: String?
    @Published private(set) var processingMeetingID: UUID?
    @Published private(set) var isStartingCapture = false
    @Published private(set) var isSavingSpeakerProfile = false
    @Published private(set) var isRecognizingVoices = false
    @Published private(set) var isCommittingVoiceEnrollment = false
    @Published private(set) var registeredVoiceProfileIDs: Set<UUID> = []
    @Published private(set) var voiceIdentificationMessages: [UUID: String] = [:]
    @Published private(set) var library = MeetingLibrary()
    @Published private(set) var folderMoveFeedback: MeetingFolderMoveFeedback?
    @Published private(set) var transcriptDocuments: [UUID: TranscriptDocument] = [:]
    @Published private(set) var transcriptDocumentErrors: [UUID: String] = [:]

    let recorder = AudioRecorder()
    let voiceIdentificationAvailable: Bool

    private let storageURL: URL
    private let audioDirectory: URL
    private let isDemoMode: Bool
    private let transcriptStorage: TranscriptDocumentStorage
    private var meetingIndexError: String?
    private var libraryError: String?
    private let libraryStorage: MeetingLibraryStorage
    private let inferenceService: any MeetingInferenceRunning
    private var processingTask: Task<Void, Never>?
    private let voiceVault: SpeakerVoiceVault
    private let voiceExtractor: any SpeakerVoiceExtracting
    private var voiceTask: Task<Bool, Never>?
    private var voiceRegistryLoaded = false
    private let folderTransferScopeID = UUID()

    init(baseDirectory: URL? = nil, inferenceService: (any MeetingInferenceRunning)? = nil,
         voiceVault: SpeakerVoiceVault? = nil, voiceExtractor: (any SpeakerVoiceExtracting)? = nil,
         voiceIdentificationAvailable: Bool = VoiceIdentityReleaseGate.isEnabled) {
        self.voiceIdentificationAvailable = voiceIdentificationAvailable
        let base = baseDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Grove", isDirectory: true)
        storageURL = base.appendingPathComponent("meetings.json")
        libraryStorage = MeetingLibraryStorage(url: base.appendingPathComponent("library.json"))
        audioDirectory = base.appendingPathComponent("Audio", isDirectory: true)
        transcriptStorage = TranscriptDocumentStorage(directory: base.appendingPathComponent("Documents", isDirectory: true))
        self.inferenceService = inferenceService ?? BundledMeetingInferenceService(appBundle: Bundle.main.bundleURL, applicationSupport: base)
        self.voiceVault = voiceVault ?? SpeakerVoiceVault(directory: base.appendingPathComponent("VoiceRegistry", isDirectory: true),
            keyStore: KeychainSpeakerVoiceKeyStore(storage: .login))
        self.voiceExtractor = voiceExtractor ?? LocalSpeakerVoiceService(modelDirectory: LocalSpeakerVoiceService.defaultModelDirectory())
        isDemoMode = CommandLine.arguments.contains("--demo")

        try? FileManager.default.createDirectory(
            at: audioDirectory,
            withIntermediateDirectories: true
        )
        if !isDemoMode {
            loadGlossary()
            do { library = try libraryStorage.load() }
            catch {
                libraryError = error.localizedDescription
                alertMessage = "폴더와 설정을 읽지 못했습니다. 기존 파일은 보존됩니다. \(error.localizedDescription)"
            }
        }
        if isDemoMode {
            meetings = [Self.demoMeeting]
            selection = .meeting(Self.demoMeeting.id)
        } else {
            loadMeetings()
            if meetingIndexError == nil {
                recoverInterruptedCaptures()
                recoverInterruptedProcessing()
            }
        }
        loadTranscriptDocuments()
        Task { [weak self] in await self?.refreshVoiceEnrollmentStatus() }
    }

    var activeMeeting: MeetingRecord? {
        guard let activeMeetingID else { return nil }
        return meetings.first { $0.id == activeMeetingID }
    }

    var isRecording: Bool {
        recorder.isRecording
    }

    var isProcessing: Bool { processingMeetingID != nil }
    var isExportingOriginal: Bool { exportingOriginalMeetingID != nil }
    var isBusy: Bool { isRecording || isProcessing || isStartingCapture || isSavingSpeakerProfile || isRecognizingVoices || isPreparingToQuit }

    var defaultSpeakerOptions: MeetingSpeakerOptions {
        get { library.defaultSpeakerOptions }
        set { _ = editLibrary { $0.defaultSpeakerOptions = newValue } }
    }

    var selectedFolderID: UUID? {
        let candidate: UUID?
        switch selection {
        case .folder(let id): candidate = id
        case .meeting(let id): candidate = meetings.first(where: { $0.id == id })?.folderID
        default: candidate = nil
        }
        guard let candidate, library.folders.contains(where: { $0.id == candidate }) else { return nil }
        return candidate
    }

    func folderName(_ id: UUID?) -> String {
        library.folders.first { $0.id == id }?.name ?? "미분류"
    }

    func recordings(in folderID: UUID?) -> [MeetingRecord] {
        MeetingFolderListing.recordings(meetings, in: folderID, folders: library.folders)
    }

    func folderTransfer(for meetingID: UUID) -> MeetingFolderTransfer {
        MeetingFolderTransfer(meetingID: meetingID, scopeID: folderTransferScopeID)
    }

    func canMoveMeeting(id: UUID) -> Bool {
        guard meetingIndexError == nil, libraryError == nil, !isPreparingToQuit,
              !isStartingCapture, !isSavingSpeakerProfile, !isRecognizingVoices,
              let meeting = meetings.first(where: { $0.id == id }) else { return false }
        return id != activeMeetingID && id != processingMeetingID && id != exportingOriginalMeetingID
            && meeting.status != .recording && meeting.status != .processing
    }

    @discardableResult
    func acceptFolderDrop(_ items: [MeetingFolderTransfer], to folderID: UUID?) -> Bool {
        do {
            return moveMeetings(ids: try MeetingFolderTransfer.recordingIDs(in: items, scopeID: folderTransferScopeID), to: folderID)
        } catch {
            folderMoveFeedback = nil
            alertMessage = error.localizedDescription
            return false
        }
    }

    func dismissFolderMoveFeedback(id: UUID) {
        if folderMoveFeedback?.id == id { folderMoveFeedback = nil }
    }

    @discardableResult
    func createFolder(name: String) -> UUID? {
        do {
            let folder = MeetingFolder(name: try MeetingFolderListing.folderName(name, folders: library.folders))
            guard editLibrary({ $0.folders.append(folder) }) else { return nil }
            selection = .folder(folder.id)
            return folder.id
        } catch { alertMessage = error.localizedDescription; return nil }
    }

    func renameFolder(id: UUID, name: String) -> Bool {
        guard let index = library.folders.firstIndex(where: { $0.id == id }) else {
            alertMessage = MeetingFolderMoveError.missingFolder.localizedDescription; return false
        }
        do {
            let name = try MeetingFolderListing.folderName(name, excluding: id, folders: library.folders)
            guard library.folders[index].name != name else { return true }
            return editLibrary { $0.folders[index].name = name }
        } catch { alertMessage = error.localizedDescription; return false }
    }

    @discardableResult
    func renameMeeting(id: UUID, title: String) -> Bool {
        guard canModifyMeetingIndex else { return false }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            alertMessage = "녹음 이름을 한 줄로 입력해 주세요."
            return false
        }
        guard let index = meetings.firstIndex(where: { $0.id == id }) else {
            alertMessage = "이름을 변경할 녹음을 찾을 수 없습니다."
            return false
        }
        guard meetings[index].title != cleaned else { return true }
        var updated = meetings
        updated[index].title = cleaned
        do {
            if !isDemoMode { try MeetingRecordStorage(url: storageURL).save(updated) }
            meetings = updated
            return true
        } catch {
            alertMessage = "녹음 이름을 저장하지 못했습니다. 기존 이름과 원본 파일은 유지됩니다. \(error.localizedDescription)"
            return false
        }
    }

    func canExportOriginal(meetingID: UUID) -> Bool {
        guard let meeting = meetings.first(where: { $0.id == meetingID }) else { return false }
        return meeting.status != .recording && activeMeetingID != meetingID && !isExportingOriginal && !isPreparingToQuit
    }

    func exportOriginal(meetingID: UUID, sourceID: String, to destination: URL, replacingExisting: Bool) async throws {
        guard !isPreparingToQuit else { throw RecordingManagementError.appClosing }
        guard let meeting = meetings.first(where: { $0.id == meetingID }),
              let source = meeting.originalRecordingFiles.first(where: { $0.id == sourceID }) else {
            throw RecordingManagementError.missingSource
        }
        guard meeting.status != .recording, activeMeetingID != meetingID else { throw RecordingManagementError.recordingInProgress }
        guard !isExportingOriginal else { throw RecordingManagementError.exportInProgress }
        exportingOriginalMeetingID = meetingID
        defer { exportingOriginalMeetingID = nil }
        try await OriginalRecordingExporter.export(source: source.url, to: destination,
            protectedDirectory: storageURL.deletingLastPathComponent(), replacingExisting: replacingExisting)
    }

    @discardableResult
    func moveMeeting(id: UUID, to folderID: UUID?) -> Bool {
        moveMeetings(ids: [id], to: folderID)
    }

    @discardableResult
    func moveMeetings(ids: [UUID], to folderID: UUID?) -> Bool {
        guard canModifyMeetingIndex else { return false }
        guard libraryError == nil else {
            alertMessage = "폴더 정보를 읽지 못해 이동을 중단했습니다. 기존 녹음과 폴더 배치는 보존됩니다."
            return false
        }
        do {
            guard folderID == nil || library.folders.contains(where: { $0.id == folderID }) else {
                throw MeetingFolderMoveError.missingFolder
            }
            guard !ids.isEmpty, Set(ids).count == ids.count,
                  ids.allSatisfy({ id in meetings.contains { $0.id == id } }) else {
                throw MeetingFolderMoveError.missingRecording
            }
            guard ids.allSatisfy({ canMoveMeeting(id: $0) }) else { throw MeetingFolderMoveError.processing }
            let moving = Set(ids)
            let changedCount = meetings.filter { moving.contains($0.id) && $0.folderID != folderID }.count
            guard changedCount > 0 else { return true }
            var updated = meetings
            for index in updated.indices where moving.contains(updated[index].id) { updated[index].folderID = folderID }
            do {
                if !isDemoMode { try MeetingRecordStorage(url: storageURL).save(updated) }
            } catch {
                folderMoveFeedback = nil
                alertMessage = "폴더 이동을 저장하지 못했습니다. 기존 폴더 배치와 원본 파일은 유지됩니다. \(error.localizedDescription)"
                return false
            }
            // Keep IDs, order, selection, playback and transcript identity unchanged.
            meetings = updated
            let destination = folderID == nil ? "미분류로" : "‘\(folderName(folderID))’ 폴더로"
            folderMoveFeedback = MeetingFolderMoveFeedback(message: "녹음 \(changedCount)개를 \(destination) 옮겼습니다.")
            return true
        } catch {
            folderMoveFeedback = nil
            alertMessage = error.localizedDescription
            return false
        }
    }

    func deleteFolder(id: UUID) -> Bool {
        guard canModifyMeetingIndex, libraryError == nil, !isBusy else { return false }
        let profiles = speakerProfiles(in: id)
        guard profiles.isEmpty || (voiceRegistryLoaded && profiles.allSatisfy { !voiceProfileHasStorage($0.id) }) else {
            alertMessage = "폴더의 저장한 화자에서 등록 목소리를 먼저 삭제해 주세요. 음성 정보를 남긴 채 폴더를 삭제하지 않습니다."
            return false
        }
        let previous = meetings
        for index in meetings.indices where meetings[index].folderID == id { meetings[index].folderID = nil }
        guard saveMeetings() else { meetings = previous; return false }
        // Detach the index before removing metadata; restore it if metadata fails.
        guard editLibrary({
            $0.folders.removeAll { $0.id == id }
            $0.speakerProfiles?.removeAll { $0.folderID == id }
        }) else {
            let detached = meetings
            meetings = previous
            if !saveMeetings() {
                meetings = detached
                alertMessage = "폴더 삭제를 마치지 못했습니다. 녹음은 ‘미분류’로 옮겨졌고 빈 폴더가 남아 있습니다. 원본과 전사는 보존됩니다."
            } else {
                alertMessage = "폴더를 삭제하지 못해 녹음의 원래 폴더 배치를 복원했습니다. 원본과 전사는 보존됩니다."
            }
            return false
        }
        if selection == .folder(id) { selection = .unfiled }
        return true
    }

    @discardableResult
    private func editLibrary(_ mutation: (inout MeetingLibrary) -> Void) -> Bool {
        guard libraryError == nil else {
            alertMessage = "폴더·설정 파일을 먼저 복구해야 합니다. 기존 파일은 보존됩니다."
            return false
        }
        var updated = library
        mutation(&updated)
        updated.speakerProfiles = updated.speakerProfiles?.map { profile in
            var namesOnly = profile; namesOnly.voice = nil; return namesOnly
        }
        do {
            if !isDemoMode { try libraryStorage.save(updated) }
            library = updated
            return true
        } catch {
            alertMessage = "폴더·설정을 저장하지 못했습니다. \(error.localizedDescription)"
            return false
        }
    }

    func speakerProfiles(in folderID: UUID) -> [SavedSpeakerProfile] {
        (library.speakerProfiles ?? []).filter { $0.folderID == folderID }
    }

    func removeSpeakerProfile(id: UUID) -> Bool {
        guard !isBusy else { return false }
        guard voiceRegistryLoaded, !voiceProfileHasStorage(id) else {
            alertMessage = "등록한 목소리를 먼저 삭제한 뒤 이름을 삭제해 주세요."
            return false
        }
        return editLibrary { $0.speakerProfiles?.removeAll { $0.id == id } }
    }

    func saveSpeakerProfile(meetingID: UUID, speakerID: UUID, name: String) async -> Bool {
        guard !isBusy, let meeting = meetings.first(where: { $0.id == meetingID }),
              let original = transcriptDocuments[meetingID] else { return false }
        guard let folderID = meeting.folderID, library.folders.contains(where: { $0.id == folderID }) else {
            alertMessage = VoiceProfileError.folderRequired.localizedDescription; return false
        }
        if let linked = original.speakers.first(where: { $0.id == speakerID })?.profileMatch,
           speakerProfiles(in: folderID).contains(where: { $0.id == linked.profileID }) {
            alertMessage = "이미 저장한 화자가 연결되어 있습니다. 다른 사람이라면 먼저 화자 이름을 변경해 연결을 해제해 주세요."
            return false
        }
        guard !speakerProfiles(in: folderID).contains(where: {
            $0.sourceMeetingID == meetingID && $0.sourceSpeakerID == speakerID
        }) else {
            alertMessage = "이 화자에서 저장한 이름이 이미 있습니다. 폴더의 기존 화자를 적용하거나, 등록 목소리와 이름을 먼저 삭제해 주세요."
            return false
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        isSavingSpeakerProfile = true
        defer { isSavingSpeakerProfile = false }
        do {
            guard original.speakers.contains(where: { $0.id == speakerID }) else { throw TranscriptEditError.missingSpeaker }
            guard transcriptDocuments[meetingID] == original,
                  meetings.first(where: { $0.id == meetingID })?.folderID == folderID else { throw VoiceProfileError.recordingChanged }
            let profile = SavedSpeakerProfile(folderID: folderID, name: name,
                sourceMeetingID: meetingID, sourceRevisionID: original.revisionID, sourceSpeakerID: speakerID, createdAt: Date())
            guard editLibrary({
                if $0.speakerProfiles == nil { $0.speakerProfiles = [] }
                $0.speakerProfiles?.removeAll { $0.folderID == folderID && $0.sourceMeetingID == meetingID && $0.sourceSpeakerID == speakerID }
                $0.speakerProfiles?.append(profile)
            }) else { return false }
            let applied = editDocument(meetingID: meetingID) { try $0.applySpeakerProfile(profile, to: speakerID, similarity: nil, confirmed: true) }
            if !applied { alertMessage = "화자는 폴더에 저장했지만 현재 전사에 이름을 적용하지 못했습니다. 폴더의 화자 목록에서 다시 적용할 수 있습니다." }
            return true
        } catch {
            alertMessage = "화자를 저장하지 못했습니다. \(error.localizedDescription)"
            return false
        }
    }

    func applySavedSpeaker(profileID: UUID, meetingID: UUID, speakerID: UUID) -> Bool {
        guard let meeting = meetings.first(where: { $0.id == meetingID }),
              let profile = library.speakerProfiles?.first(where: { $0.id == profileID && $0.folderID == meeting.folderID }) else { return false }
        return editDocument(meetingID: meetingID) { try $0.applySpeakerProfile(profile, to: speakerID, similarity: nil, confirmed: true) }
    }

    func automaticSpeakerIdentificationEnabled(folderID: UUID) -> Bool {
        voiceIdentificationAvailable && library.folders.first(where: { $0.id == folderID })?.automaticSpeakerIdentification == true
    }

    func setAutomaticSpeakerIdentification(folderID: UUID, enabled: Bool) -> Bool {
        guard !enabled || voiceIdentificationAvailable else { alertMessage = VoiceIdentityReleaseGate.message; return false }
        guard !isBusy, let index = library.folders.firstIndex(where: { $0.id == folderID }) else { return false }
        return editLibrary { $0.folders[index].automaticSpeakerIdentification = enabled }
    }

    func voiceProfileIsRegistered(_ profileID: UUID) -> Bool { registeredVoiceProfileIDs.contains(profileID) }
    func voiceProfileHasStorage(_ profileID: UUID) -> Bool {
        voiceProfileIsRegistered(profileID) || library.speakerProfiles?.first(where: { $0.id == profileID })?.voiceStorageReferenced == true
    }
    func voiceIdentificationMessage(for meetingID: UUID) -> String? { voiceIdentificationMessages[meetingID] }

    func refreshVoiceEnrollmentStatus() async {
        let profiles = library.speakerProfiles ?? []
        do {
            var found: Set<UUID> = []
            for profile in profiles where try await voiceVault.hasRecord(profileID: profile.id) { found.insert(profile.id) }
            guard profiles == library.speakerProfiles ?? [] else { return }
            registeredVoiceProfileIDs = found
            voiceRegistryLoaded = true
        } catch {
            voiceRegistryLoaded = false
            alertMessage = "목소리 등록 상태를 읽지 못했습니다. 기존 자료는 보존됩니다. \(error.localizedDescription)"
        }
    }

    func voiceEnrollmentCandidates(meetingID: UUID, speakerID: UUID) -> [DocumentUtterance] {
        guard let document = transcriptDocuments[meetingID] else { return [] }
        return VoiceIdentitySelection.candidates(in: document, speakerID: speakerID)
    }

    func voiceEnrollmentDuration(_ utterance: DocumentUtterance) -> Double {
        let range = VoiceIdentitySelection.range(for: utterance)
        return max(0, range.end - range.start)
    }

    func cancelVoiceWork() {
        guard !isCommittingVoiceEnrollment else { return }
        voiceTask?.cancel()
    }

    func confirmSpeakerIdentity(meetingID: UUID, speakerID: UUID) -> Bool {
        editDocument(meetingID: meetingID) { try $0.confirmSpeakerIdentity(speakerID) }
    }

    func rejectSpeakerIdentity(meetingID: UUID, speakerID: UUID) -> Bool {
        editDocument(meetingID: meetingID) { try $0.rejectSpeakerIdentity(speakerID) }
    }

    func removeVoiceEnrollment(profileID: UUID) async -> Bool {
        guard !isBusy, let profile = library.speakerProfiles?.first(where: { $0.id == profileID }) else { return false }
        isSavingSpeakerProfile = true
        defer { isSavingSpeakerProfile = false }
        do {
            try await voiceVault.remove(profileID: profileID, folderID: profile.folderID)
            guard editLibrary({ updated in
                if let index = updated.speakerProfiles?.firstIndex(where: { $0.id == profileID }) {
                    updated.speakerProfiles?[index].voiceStorageReferenced = nil
                }
            }) else { return false }
            await refreshVoiceEnrollmentStatus()
            return !registeredVoiceProfileIDs.contains(profileID)
        } catch {
            await refreshVoiceEnrollmentStatus()
            alertMessage = "목소리 삭제를 마치지 못했습니다. 이름과 기존 전사는 유지됩니다. \(error.localizedDescription)"
            return false
        }
    }

    func enrollVoice(meetingID: UUID, speakerID: UUID, name: String,
                     selectedUtteranceIDs: Set<UUID>, permissionConfirmed: Bool,
                     enableAutomaticIdentification: Bool) async -> Bool {
        guard !isBusy else { return false }
        guard voiceIdentificationAvailable else { alertMessage = VoiceIdentityReleaseGate.message; return false }
        guard permissionConfirmed else { alertMessage = VoiceIdentityError.consentRequired.localizedDescription; return false }
        isSavingSpeakerProfile = true
        let task = Task { await self.performVoiceEnrollment(meetingID: meetingID, speakerID: speakerID, name: name,
            selectedUtteranceIDs: selectedUtteranceIDs, enableAutomaticIdentification: enableAutomaticIdentification) }
        voiceTask = task
        let result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        voiceTask = nil
        isSavingSpeakerProfile = false
        return result
    }

    private func performVoiceEnrollment(meetingID: UUID, speakerID: UUID, name: String,
                                        selectedUtteranceIDs: Set<UUID>, enableAutomaticIdentification: Bool) async -> Bool {
        defer { isCommittingVoiceEnrollment = false }
        do {
            guard !isDemoMode, let meeting = meetings.first(where: { $0.id == meetingID }),
                  let document = transcriptDocuments[meetingID], transcriptDocumentErrors[meetingID] == nil,
                  let speaker = document.speakers.first(where: { $0.id == speakerID }),
                  let path = meeting.audioPath else { throw VoiceIdentityError.missingSource }
            guard let folderID = meeting.folderID, library.folders.contains(where: { $0.id == folderID }) else {
                throw VoiceProfileError.folderRequired
            }
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw TranscriptEditError.emptyName
            }
            let beforeLibrary = library
            let candidates = try VoiceIdentitySelection.selected(in: document, speakerID: speakerID, ids: selectedUtteranceIDs)
            let profiles = speakerProfiles(in: folderID)
            let existing = profiles.first(where: { $0.id == speaker.profileMatch?.profileID })
                ?? profiles.first(where: { $0.sourceMeetingID == meetingID && $0.sourceSpeakerID == speakerID })
            guard existing == nil || existing?.name == name else { throw VoiceIdentityError.namesOnlyConflict }
            var profile = existing ?? SavedSpeakerProfile(folderID: folderID, name: name, sourceMeetingID: meetingID,
                sourceRevisionID: document.revisionID, sourceSpeakerID: speakerID, createdAt: Date())
            profile.voiceStorageReferenced = true
            let source = URL(fileURLWithPath: path)
            let hash = try await VoiceIdentitySelection.audioHash(source)
            let extracted = try await extractVoiceSamples(source: source, utterances: candidates)
            let samples = zip(candidates, extracted).map { utterance, sample in
                VoiceEnrollmentSample(utteranceID: utterance.id, start: sample.range.start, end: sample.range.end,
                    voice: sample.voicePrint, sourceMeetingID: meetingID, sourceRevisionID: document.revisionID, audioSHA256: hash)
            }
            try VoiceRecognitionPolicy.validateEnrollment(samples: samples)
            guard try await VoiceIdentitySelection.audioHash(source) == hash else { throw VoiceIdentityError.changed }
            try Task.checkCancellation()
            guard transcriptDocuments[meetingID] == document, library == beforeLibrary,
                  meetings.first(where: { $0.id == meetingID })?.audioPath == path,
                  meetings.first(where: { $0.id == meetingID })?.folderID == folderID else { throw VoiceIdentityError.changed }

            // Publish names first: a crash before the encrypted commit can leave only
            // a harmless names-only entry, never a hidden/orphaned enrollment.
            isCommittingVoiceEnrollment = true
            guard editLibrary({
                if $0.speakerProfiles == nil { $0.speakerProfiles = [] }
                $0.speakerProfiles?.removeAll { $0.id == profile.id }
                $0.speakerProfiles?.append(profile)
            }) else { return false }
            var cleanupWarning: String?
            do {
                try await voiceVault.put(VoiceEnrollmentRecord(profileID: profile.id, folderID: folderID,
                    modelIdentifier: samples[0].voice.modelIdentifier, samples: samples, createdAt: Date()))
            } catch SpeakerVoiceVaultError.publishedButCleanupFailed(let reason) {
                cleanupWarning = SpeakerVoiceVaultError.publishedButCleanupFailed(reason).localizedDescription
            } catch {
                // Retaining a names-only profile keeps any failed-generation cleanup
                // addressable. Never claim the encrypted commit succeeded.
                await refreshVoiceEnrollmentStatus()
                throw error
            }
            await refreshVoiceEnrollmentStatus()
            var warnings: [String] = cleanupWarning.map { [$0] } ?? []
            if transcriptDocuments[meetingID] == document,
               meetings.first(where: { $0.id == meetingID })?.folderID == folderID {
                if !editDocument(meetingID: meetingID, mutation: {
                    try $0.applySpeakerProfile(profile, to: speakerID, similarity: nil, confirmed: true)
                }) { warnings.append("등록은 저장했지만 현재 전사에 이름을 적용하지 못했습니다.") }
            } else { warnings.append("등록은 저장했지만 처리 중 바뀐 전사에는 이름을 적용하지 않았습니다.") }
            if let index = library.folders.firstIndex(where: { $0.id == folderID }),
               !editLibrary({ $0.folders[index].automaticSpeakerIdentification = enableAutomaticIdentification }) {
                warnings.append("폴더의 자동 식별 설정은 저장하지 못했습니다.")
            }
            let message = warnings.isEmpty ? "목소리를 등록했습니다. 같은 폴더의 다른 녹음에서 이름을 추정할 수 있습니다." : warnings.joined(separator: " ")
            voiceIdentificationMessages[meetingID] = message
            if !warnings.isEmpty { alertMessage = message }
            return true
        } catch is CancellationError {
            alertMessage = "목소리 등록을 취소했습니다."
            return false
        } catch {
            alertMessage = "목소리를 등록하지 못했습니다. \(error.localizedDescription)"
            return false
        }
    }

    private func extractVoiceSamples(source: URL, utterances: [DocumentUtterance]) async throws -> [VoiceEmbeddingSample] {
        let directory = storageURL.deletingLastPathComponent().appendingPathComponent("VoiceWork/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let ranges = utterances.map { VoiceIdentitySelection.range(for: $0) }
        let samples = try await voiceExtractor.extractSamples(source: source, ranges: ranges, workingDirectory: directory)
        guard samples.count == ranges.count, zip(samples, ranges).allSatisfy({
            $0.0.range.start == $0.1.start && $0.0.range.end == $0.1.end
        }) else { throw VoiceIdentityError.invalidSelection }
        return samples
    }

    func identifySpeakers(meetingID: UUID) async {
        guard !isBusy else { return }
        guard voiceIdentificationAvailable else {
            voiceIdentificationMessages[meetingID] = VoiceIdentityReleaseGate.message
            return
        }
        await runVoiceIdentification(meetingID: meetingID, automatic: false)
    }

    private func runVoiceIdentification(meetingID: UUID, automatic: Bool) async {
        guard voiceIdentificationAvailable else { return }
        guard !isRecognizingVoices, !isSavingSpeakerProfile, !isRecording, !isPreparingToQuit else { return }
        isRecognizingVoices = true
        let task = Task { await self.performVoiceIdentification(meetingID: meetingID, automatic: automatic) }
        voiceTask = task
        _ = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        voiceTask = nil
        isRecognizingVoices = false
    }

    private func performVoiceIdentification(meetingID: UUID, automatic: Bool) async -> Bool {
        do {
            guard !isDemoMode, let meeting = meetings.first(where: { $0.id == meetingID }),
                  let document = transcriptDocuments[meetingID], transcriptDocumentErrors[meetingID] == nil,
                  let path = meeting.audioPath else { throw VoiceIdentityError.missingSource }
            guard let folderID = meeting.folderID else { throw VoiceProfileError.folderRequired }
            if automatic && !automaticSpeakerIdentificationEnabled(folderID: folderID) { return false }
            let beforeLibrary = library
            let profiles = speakerProfiles(in: folderID)
            var records: [VoiceEnrollmentRecord] = []
            for profile in profiles {
                try Task.checkCancellation()
                if let record = try await voiceVault.load(profileID: profile.id, folderID: folderID) { records.append(record) }
            }
            guard !records.isEmpty else {
                if automatic { return false }
                throw VoiceIdentityError.noEnrolledVoices
            }
            let source = URL(fileURLWithPath: path)
            let hash = try await VoiceIdentitySelection.audioHash(source)
            records.removeAll { $0.samples.contains(where: { $0.sourceMeetingID == meetingID || $0.audioSHA256.lowercased() == hash }) }
            guard !records.isEmpty else { throw VoiceIdentityError.sourceEnrollmentOnly }
            var proposals: [(UUID, SavedSpeakerProfile, Float, SpeakerIdentityEvidence)] = []
            var deferredReasons: [String] = []
            for speaker in document.speakers where VoiceIdentitySelection.permitsAutomaticName(speaker, in: document) {
                try Task.checkCancellation()
                let utterances = VoiceIdentitySelection.query(in: document, speakerID: speaker.id)
                guard utterances.count >= VoiceRecognitionPolicy.minimumQuerySamples else {
                    deferredReasons.append("\(speaker.name): 단독 발화 부족")
                    continue
                }
                let samples = try await extractVoiceSamples(source: source, utterances: utterances)
                let decision = VoiceRecognitionPolicy.evaluate(samples: samples.map(\.voicePrint), enrollments: records)
                if let id = decision.profileID, let score = decision.similarity,
                   let profile = profiles.first(where: { $0.id == id }),
                   let record = records.first(where: { $0.profileID == id }) {
                    let evidence = SpeakerIdentityEvidence(modelIdentifier: record.modelIdentifier,
                        policyVersion: decision.policyVersion, enrollmentCreatedAt: record.createdAt,
                        queryUtteranceIDs: utterances.map(\.id))
                    proposals.append((speaker.id, profile, score, evidence))
                }
                else { deferredReasons.append("\(speaker.name): \(decision.reason?.message ?? "이름 추정 보류")") }
            }
            let counts = Dictionary(grouping: proposals, by: { $0.1.id })
            let unique = proposals.filter { counts[$0.1.id]?.count == 1 }
            if unique.count != proposals.count { deferredReasons.append("여러 화자가 같은 사람으로 추정되어 해당 이름은 적용하지 않았습니다.") }
            guard try await VoiceIdentitySelection.audioHash(source) == hash else { throw VoiceIdentityError.changed }
            try Task.checkCancellation()
            guard transcriptDocuments[meetingID] == document, library == beforeLibrary,
                  meetings.first(where: { $0.id == meetingID })?.folderID == folderID,
                  meetings.first(where: { $0.id == meetingID })?.audioPath == path else { throw VoiceIdentityError.changed }
            if !unique.isEmpty {
                guard editDocument(meetingID: meetingID, mutation: { updated in
                    for (id, profile, score, evidence) in unique {
                        try updated.applySpeakerProfile(profile, to: id, similarity: score, confirmed: false, identityEvidence: evidence)
                    }
                }) else { return false }
            }
            let summary = unique.isEmpty ? "새로 추정한 이름이 없습니다. 사용자가 지정한 이름과 확인·거절한 제안은 유지합니다." : "화자 \(unique.count)명의 이름을 추정했습니다. 듣고 맞는지 확인해 주세요."
            voiceIdentificationMessages[meetingID] = ([summary] + deferredReasons).joined(separator: "\n")
            return true
        } catch is CancellationError {
            voiceIdentificationMessages[meetingID] = "이름 찾기를 취소했습니다. 전사문과 기존 이름은 유지됩니다."
            return false
        } catch {
            let message = "이름 찾기를 마치지 못했습니다. 전사문과 기존 이름은 유지됩니다. \(error.localizedDescription)"
            voiceIdentificationMessages[meetingID] = message
            if !automatic { alertMessage = message }
            return false
        }
    }

    func toggleRecordingPause() {
        guard isRecording else { return }
        if recorder.isPaused {
            do {
                try recorder.resume()
            } catch { alertMessage = "녹음을 재개하지 못했습니다. 일시정지 상태를 유지합니다. \(error.localizedDescription)" }
        } else {
            recorder.pause()
        }
        objectWillChange.send()
    }

    func cancelProcessing() {
        processingTask?.cancel()
        if processingTask != nil { processingStage = "처리를 중단하고 있습니다" }
    }

    func prepareToQuit() async -> Bool {
        guard !isPreparingToQuit else { return false }
        guard !isExportingOriginal else {
            alertMessage = "원본 파일 저장을 마치거나 취소한 뒤 앱을 닫아 주세요."
            return false
        }
        guard !isSavingSpeakerProfile else {
            alertMessage = "화자 저장을 마친 뒤 앱을 닫아 주세요."
            return false
        }
        guard !isRecording, !isStartingCapture else {
            alertMessage = "녹음을 종료한 뒤 앱을 닫아 주세요."
            return false
        }
        isPreparingToQuit = true
        defer { isPreparingToQuit = false }
        cancelProcessing()
        cancelVoiceWork()
        await processingTask?.value
        _ = await voiceTask?.value
        guard !isExportingOriginal, !isRecording, !isStartingCapture, !isSavingSpeakerProfile, !isRecognizingVoices else {
            alertMessage = "진행 중인 저장이나 녹음을 마친 뒤 앱을 닫아 주세요."
            return false
        }
        return true
    }

    var approvedContextStrings: [String] {
        glossaryTerms
            .filter(\.isEnabled)
            .flatMap { [$0.canonical] + $0.observedForms }
    }

    func updateUtteranceText(meetingID: UUID, utteranceID: UUID, text: String) -> Bool {
        editDocument(meetingID: meetingID) { try $0.editText(utteranceID, to: text) }
    }

    func confirmUtteranceSpeaker(meetingID: UUID, utteranceID: UUID) -> Bool {
        editDocument(meetingID: meetingID) { try $0.confirmUtteranceSpeaker(utteranceID) }
    }

    func speakerReview(meetingID: UUID, utteranceID: UUID) -> SpeakerReviewAssessment? {
        transcriptDocuments[meetingID]?.speakerReview(for: utteranceID)
    }

    func renameSpeaker(meetingID: UUID, speakerID: UUID, name: String) -> Bool {
        editDocument(meetingID: meetingID) { try $0.renameSpeaker(speakerID, to: name) }
    }

    func splitUtterance(meetingID: UUID, utteranceID: UUID, time: Double, firstText: String, secondText: String) -> Bool {
        editDocument(meetingID: meetingID) {
            try $0.splitUtterance(utteranceID, at: time, firstText: firstText, secondText: secondText)
        }
    }

    func reassignSpeaker(meetingID: UUID, utteranceID: UUID, target: SpeakerEditTarget, scope: SpeakerEditScope,
                         confirmingAnchor: Bool = false) -> Bool {
        editDocument(meetingID: meetingID) {
            _ = try $0.reassign(from: utteranceID, to: target, scope: scope, confirmingAnchor: confirmingAnchor)
        }
    }

    func undoTranscriptEdit(meetingID: UUID) {
        _ = editDocument(meetingID: meetingID) { try $0.undo() }
    }

    func redoTranscriptEdit(meetingID: UUID) {
        _ = editDocument(meetingID: meetingID) { try $0.redo() }
    }

    func previousTranscripts(meetingID: UUID) throws -> [ArchivedTranscript] {
        guard !isDemoMode else { return [] }
        return try transcriptStorage.archives(for: meetingID)
    }

    func restoreTranscript(_ archive: ArchivedTranscript, meetingID: UUID) -> Bool {
        guard archive.meetingID == meetingID else { return false }
        do {
            try transcriptStorage.activate(archive.document, for: meetingID)
            transcriptDocuments[meetingID] = archive.document
            transcriptDocumentErrors.removeValue(forKey: meetingID)
            return true
        } catch {
            alertMessage = "전사를 전환하지 못했습니다. 현재 내용은 보존됩니다. \(error.localizedDescription)"
            return false
        }
    }

    func acceptInferenceResult(_ result: InferenceResult, meetingID: UUID, sourceChannelID: String) throws {
        guard meetings.contains(where: { $0.id == meetingID }) else { throw TranscriptEditError.invalidDocument }
        let document = try TranscriptDocument.preservingInference(result, sourceChannelID: sourceChannelID)
        if !isDemoMode { try transcriptStorage.activate(document, for: meetingID, rawResult: result) }
        transcriptDocuments[meetingID] = document
        transcriptDocumentErrors.removeValue(forKey: meetingID)
    }

    private func editDocument(meetingID: UUID, mutation: (inout TranscriptDocument) throws -> Void) -> Bool {
        guard var document = transcriptDocuments[meetingID], transcriptDocumentErrors[meetingID] == nil else { return false }
        do {
            try mutation(&document)
            if !isDemoMode { try transcriptStorage.save(document, for: meetingID) }
            transcriptDocuments[meetingID] = document
            return true
        } catch {
            alertMessage = "변경을 저장하지 못했습니다. 기존 내용은 보존됩니다. \(error.localizedDescription)"
            return false
        }
    }

    private func loadTranscriptDocuments() {
        for meeting in meetings {
            do {
                if !isDemoMode, let document = try transcriptStorage.load(for: meeting.id) {
                    transcriptDocuments[meeting.id] = document
                } else if !meeting.transcript.isEmpty {
                    transcriptDocuments[meeting.id] = try TranscriptDocument.preservingLegacy(meeting.transcript)
                }
            } catch {
                transcriptDocumentErrors[meeting.id] = error.localizedDescription
            }
        }
    }

    private func installInitialTranscriptDocument(for meetingID: UUID) {
        guard transcriptDocuments[meetingID] == nil,
              let meeting = meetings.first(where: { $0.id == meetingID }), !meeting.transcript.isEmpty else { return }
        do {
            let document = try TranscriptDocument.preservingLegacy(meeting.transcript)
            if !isDemoMode { try transcriptStorage.save(document, for: meetingID) }
            transcriptDocuments[meetingID] = document
        } catch {
            transcriptDocumentErrors[meetingID] = error.localizedDescription
        }
    }

    func beginRecording(
        title: String,
        glossaryProfile: String,
        plan: MeetingInferencePlan? = nil,
        folderID: UUID? = nil
    ) async {
        guard canModifyMeetingIndex else { return }
        guard folderID == nil || library.folders.contains(where: { $0.id == folderID }) else {
            alertMessage = "저장할 폴더를 다시 선택해 주세요."; return
        }
        guard !isBusy else {
            alertMessage = "현재 녹음 또는 전사를 먼저 마쳐 주세요."
            return
        }
        let selectedPlan: MeetingInferencePlan
        do {
            selectedPlan = try plan ?? defaultSpeakerOptions.plan(isDual: false)
            _ = try selectedPlan.configurations(for: ["recording"])
        } catch { alertMessage = error.localizedDescription; return }
        isStartingCapture = true
        defer { isStartingCapture = false }
        guard await recorder.requestPermission() else {
            alertMessage = RecordingError.permissionDenied.localizedDescription
            return
        }

        let id = UUID()
        let audioURL = audioDirectory.appendingPathComponent("\(id.uuidString).m4a")
        var meeting = MeetingRecord(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "제목 없음"
                : title.trimmingCharacters(in: .whitespacesAndNewlines),
            startedAt: Date(),
            duration: 0,
            status: .recording,
            audioPath: audioURL.path,
            captureMode: .microphone,
            glossaryProfile: glossaryProfile,
            transcript: [],
            claims: [],
            errorMessage: nil
        )
        meeting.inferenceConfiguration = selectedPlan.configuration
        meeting.channelInferenceConfigurations = selectedPlan.channelConfigurations
        meeting.folderID = folderID

        do {
            try recorder.start(to: audioURL)
            meetings.insert(meeting, at: 0)
            activeMeetingID = id
            selection = .meeting(id)
            selectedTab = .transcript
            isPresentingNewMeeting = false
            if !saveMeetings() {
                _ = recorder.stop()
                activeMeetingID = nil
                meetings.removeAll { $0.id == id }
            }
        } catch {
            meeting.status = .failed
            meeting.errorMessage = error.localizedDescription
            alertMessage = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard let id = activeMeetingID,
              let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].duration = recorder.stop()
        meetings[index].status = .processing
        processingStage = "저장한 녹음을 준비하고 있습니다"
        activeMeetingID = nil
        saveMeetings()
        await transcribeMeeting(id: id)
    }

    func importRecording(from sourceURL: URL, plan: MeetingInferencePlan? = nil, folderID: UUID? = nil) async {
        guard canModifyMeetingIndex else { return }
        guard folderID == nil || library.folders.contains(where: { $0.id == folderID }) else {
            alertMessage = "저장할 폴더를 다시 선택해 주세요."; return
        }
        guard !isBusy else {
            alertMessage = "현재 녹음 또는 전사를 먼저 마쳐 주세요."
            return
        }
        let selectedPlan: MeetingInferencePlan
        do {
            selectedPlan = try plan ?? defaultSpeakerOptions.plan(isDual: false)
            _ = try selectedPlan.configurations(for: ["recording"])
        } catch { alertMessage = error.localizedDescription; return }
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if access { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let id = UUID()
        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let target = audioDirectory.appendingPathComponent("\(id.uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: sourceURL, to: target)
            var meeting = MeetingRecord(
                id: id,
                title: sourceURL.deletingPathExtension().lastPathComponent,
                startedAt: Date(),
                duration: 0,
                status: .processing,
                audioPath: target.path,
                captureMode: .microphone,
                glossaryProfile: "사전 없음",
                transcript: [],
                claims: [],
                errorMessage: nil
            )
            meeting.inferenceConfiguration = selectedPlan.configuration
            meeting.channelInferenceConfigurations = selectedPlan.channelConfigurations
            meeting.folderID = folderID
            meetings.insert(meeting, at: 0)
            selection = .meeting(id)
            selectedTab = .transcript
            processingStage = "가져온 녹음을 준비하고 있습니다"
            guard saveMeetings() else {
                meetings.removeAll { $0.id == id }
                processingStage = nil
                return
            }
            await transcribeMeeting(id: id)
        } catch {
            alertMessage = "파일을 가져오지 못했습니다: \(error.localizedDescription)"
        }
    }

    func addGlossaryTerm(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !glossaryTerms.contains(where: { $0.canonical.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        glossaryTerms.insert(
            GlossaryTerm(canonical: trimmed, observedForms: [], isEnabled: true),
            at: 0
        )
    }

    func updateGlossaryTerm(_ term: GlossaryTerm) {
        guard let index = glossaryTerms.firstIndex(where: { $0.id == term.id }) else { return }
        glossaryTerms[index] = term
    }

    func deleteMeeting(_ meeting: MeetingRecord) {
        guard canModifyMeetingIndex, meeting.id != activeMeetingID || !isRecording,
              meeting.id != processingMeetingID, meeting.id != exportingOriginalMeetingID else { return }
        let previousMeetings = meetings
        let previousSelection = selection
        meetings.removeAll { $0.id == meeting.id }
        if selection == .meeting(meeting.id) { selection = .library }
        // Removing a list entry never deletes audio or corrections. A separate, confirmed
        // retention workflow is required before those files can be removed.
        if !saveMeetings() {
            meetings = previousMeetings
            selection = previousSelection
        }
    }

    func transcribeMeeting(id: UUID, plan: MeetingInferencePlan? = nil) async {
        guard canModifyMeetingIndex, !isBusy,
              let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        let meeting = meetings[index]
        let sources: [(String, URL)]
        if let path = meeting.audioPath {
            sources = [("recording", URL(fileURLWithPath: path))]
        } else {
            sources = [("system", meeting.systemAudioPath), ("microphone", meeting.microphoneAudioPath)]
                .compactMap { key, path in path.map { (key, URL(fileURLWithPath: $0)) } }
        }
        guard !sources.isEmpty else { alertMessage = "전사할 원본 녹음이 없습니다."; return }
        let selectedPlan: MeetingInferencePlan
        let configurations: [String: InferenceConfiguration]
        do {
            if let plan { selectedPlan = plan }
            else if let configuration = meeting.inferenceConfiguration {
                selectedPlan = MeetingInferencePlan(configuration: configuration, channelConfigurations: meeting.channelInferenceConfigurations)
            } else { selectedPlan = try defaultSpeakerOptions.plan(isDual: sources.count > 1) }
            configurations = try selectedPlan.configurations(for: sources.map(\.0))
        } catch { alertMessage = error.localizedDescription; return }
        meetings[index].inferenceConfiguration = selectedPlan.configuration
        meetings[index].channelInferenceConfigurations = selectedPlan.channelConfigurations
        meetings[index].status = .processing
        meetings[index].errorMessage = nil
        meetings[index].processingOutcome = nil
        guard saveMeetings() else { meetings[index] = meeting; return }
        processingMeetingID = id
        processingStage = "녹음 파일을 준비하고 있습니다"
        let job = storageURL.deletingLastPathComponent().appendingPathComponent("Jobs/\(id.uuidString)/\(UUID().uuidString)", isDirectory: true)
        let task = Task { [weak self] in
            guard let self else { return }
            var previousDocument: TranscriptDocument?
            var activatedDocument: TranscriptDocument?
            defer {
                self.processingStage = nil
                self.processingMeetingID = nil
                self.processingTask = nil
            }
            do {
                var channels: [ChannelInference] = []
                for (sourceID, source) in sources {
                    try Task.checkCancellation()
                    do {
                        guard let sourceConfiguration = configurations[sourceID] else { throw TranscriptEditError.invalidDocument }
                        let result = try await self.inferenceService.run(source: source, configuration: sourceConfiguration,
                            directory: job.appendingPathComponent(sourceID)) { [weak self] stage in
                                await self?.setProcessingStage(stage, meetingID: id)
                            }
                        try Task.checkCancellation()
                        guard result.configuration == sourceConfiguration else { throw TranscriptEditError.invalidDocument }
                        if !self.isDemoMode { try self.transcriptStorage.preserveRawResult(result, for: id) }
                        channels.append(ChannelInference(sourceID: sourceID, result: result))
                    } catch InferenceError.noSpeech {
                        continue
                    }
                }
                guard !channels.isEmpty else { throw InferenceError.noSpeech }
                try Task.checkCancellation()
                let document = try TranscriptDocument.preservingChannels(channels)
                previousDocument = self.transcriptDocuments[id]
                if !self.isDemoMode {
                    try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
                    let archive = MeetingInferenceArchive(revisionID: document.revisionID, channels: channels)
                    try JSONEncoder().encode(archive).write(to: job.appendingPathComponent("result.json"), options: .withoutOverwriting)
                    // Migrate an in-memory legacy document before activating a new revision.
                    if try self.transcriptStorage.load(for: id) == nil, let old = self.transcriptDocuments[id] {
                        try self.transcriptStorage.save(old, for: id)
                    }
                    try self.transcriptStorage.activate(document, for: id)
                }
                activatedDocument = document
                guard let updated = self.meetings.firstIndex(where: { $0.id == id }) else { return }
                var completed = self.meetings[updated]
                completed.duration = max(meeting.duration, channels.map { $0.result.duration }.max() ?? 0)
                completed.status = .ready
                completed.errorMessage = nil
                completed.processingOutcome = .init(kind: .completed, retainedRevisionID: document.revisionID)
                completed.completedResult = MeetingCompletedResult(revisionID: document.revisionID, speakerCounts: channels.map {
                    MeetingSpeakerCount(sourceID: $0.sourceID, expected: $0.result.configuration.expectedSpeakerCount,
                                        detected: Set($0.result.rawDiarization.map(\.clusterID)).count)
                })
                try self.publishProcessingRecord(completed)
                self.transcriptDocuments[id] = document
                self.transcriptDocumentErrors.removeValue(forKey: id)
                if let folderID = meeting.folderID, self.automaticSpeakerIdentificationEnabled(folderID: folderID) {
                    await self.runVoiceIdentification(meetingID: id, automatic: true)
                }
            } catch {
                guard let updated = self.meetings.firstIndex(where: { $0.id == id }) else { return }
                var message = error is CancellationError ? "전사를 중단했습니다. 원본 녹음은 보존됩니다." : error.localizedDescription
                var retentionVerified = true
                if let activatedDocument {
                    do {
                        if !self.isDemoMode {
                            if let previousDocument {
                                try self.transcriptStorage.activate(previousDocument, for: id)
                            } else {
                                guard try self.transcriptStorage.load(for: id)?.revisionID == activatedDocument.revisionID else {
                                    throw TranscriptEditError.invalidDocument
                                }
                                // Roll back only this attempt's newly activated document. Raw results remain.
                                try FileManager.default.removeItem(at: self.transcriptStorage.fileURL(for: id))
                            }
                        }
                        self.transcriptDocuments[id] = previousDocument
                        message = "새 처리 결과를 저장하지 못했습니다. \(message)"
                    } catch {
                        retentionVerified = false
                        self.transcriptDocumentErrors[id] = error.localizedDescription
                        message = "새 결과 저장 및 이전 전사 복원 상태를 확인해야 합니다. 원본과 처리 출력은 보존됩니다. \(error.localizedDescription)"
                    }
                }
                let retained = self.transcriptDocuments[id]
                var failed = self.meetings[updated]
                failed.status = .failed
                failed.errorMessage = message
                failed.processingOutcome = .init(kind: error is CancellationError ? .cancelled : .failed,
                    message: message, previousResultRetained: retentionVerified && retained != nil,
                    retainedRevisionID: retentionVerified ? retained?.revisionID : nil)
                do { try self.publishProcessingRecord(failed) }
                catch {
                    failed.processingOutcome?.message = "\(message) 처리 상태도 저장하지 못했습니다: \(error.localizedDescription)"
                    self.meetings[updated] = failed
                    self.alertMessage = failed.processingOutcome?.message
                }
                if !(error is CancellationError) { self.alertMessage = failed.processingOutcome?.message ?? message }
            }
        }
        processingTask = task
        await task.value
    }

    private func setProcessingStage(_ stage: String, meetingID: UUID) {
        if processingMeetingID == meetingID { processingStage = stage }
    }

    private func publishProcessingRecord(_ record: MeetingRecord) throws {
        guard let index = meetings.firstIndex(where: { $0.id == record.id }) else { throw TranscriptEditError.invalidDocument }
        var next = meetings
        next[index] = record
        if !isDemoMode { try MeetingRecordStorage(url: storageURL).save(next) }
        meetings = next
    }

    private func recoverInterruptedProcessing() {
        var changed = false
        for index in meetings.indices where meetings[index].status == .processing || meetings[index].status == .recording {
            let existing = try? transcriptStorage.load(for: meetings[index].id)
            meetings[index].status = .failed
            meetings[index].errorMessage = "이전 작업이 중단됐습니다. 원본을 확인하고 다시 전사해 주세요."
            meetings[index].processingOutcome = .init(kind: .interrupted, message: meetings[index].errorMessage,
                previousResultRetained: existing != nil || !meetings[index].transcript.isEmpty,
                retainedRevisionID: existing?.revisionID)
            changed = true
        }
        if changed { saveMeetings() }
    }

    private func loadMeetings() {
        do { meetings = try MeetingRecordStorage(url: storageURL).load() }
        catch {
            meetingIndexError = error.localizedDescription
            alertMessage = "회의 목록을 읽지 못했습니다. 기존 파일을 덮어쓰지 않도록 저장을 중단했습니다. \(error.localizedDescription)"
        }
    }

    private func recoverInterruptedCaptures() {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var changed = false
        for directory in directories {
            let manifestURL = directory.appendingPathComponent("capture-manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(CaptureSessionManifest.self, from: data),
                  manifest.status == .recording || manifest.status == .failed,
                  manifest.systemAudio.bufferCount > 0 || manifest.microphone.bufferCount > 0
            else { continue }

            let duration: TimeInterval
            if let recordedDuration = manifest.recordedDuration {
                duration = recordedDuration
            } else if let startedAt = manifest.startedAt {
                duration = max(0, (manifest.endedAt ?? Date()).timeIntervalSince(startedAt))
            } else {
                duration = 0
            }
            if let index = meetings.firstIndex(where: { $0.id == manifest.sessionID }) {
                // A historical unfinished manifest must not overwrite a later transcription outcome.
                guard meetings[index].status == .recording else { continue }
                meetings[index].status = .failed
                meetings[index].duration = max(meetings[index].duration, duration)
                meetings[index].systemAudioPath = manifest.systemAudio.path
                meetings[index].microphoneAudioPath = manifest.microphone.path
                meetings[index].captureManifestPath = manifestURL.path
                meetings[index].captureMode = .systemAndMicrophone
                meetings[index].errorMessage = "이전 앱 실행이 녹음 중 종료됐습니다. 저장된 PCM 채널을 검토해 주세요."
                meetings[index].processingOutcome = .init(kind: .interrupted, message: meetings[index].errorMessage)
            } else {
                meetings.insert(
                    MeetingRecord(
                        id: manifest.sessionID,
                        title: "복구된 회의",
                        startedAt: manifest.startedAt ?? manifest.createdAt,
                        duration: duration,
                        status: .failed,
                        audioPath: nil,
                        systemAudioPath: manifest.systemAudio.path,
                        microphoneAudioPath: manifest.microphone.path,
                        captureManifestPath: manifestURL.path,
                        captureMode: .systemAndMicrophone,
                        processingOutcome: .init(kind: .interrupted, message: "이전 녹음 작업이 중단됐습니다. 저장된 원본 채널로 다시 전사할 수 있습니다."),
                        glossaryProfile: "복구된 snapshot",
                        transcript: [],
                        claims: [],
                        errorMessage: "이전 앱 실행이 녹음 중 종료됐습니다. 저장된 PCM 채널을 검토해 주세요."
                    ),
                    at: 0
                )
            }
            changed = true
        }
        if changed { saveMeetings() }
    }

    @discardableResult
    private func saveMeetings() -> Bool {
        if isDemoMode { return true }
        guard canModifyMeetingIndex else { return false }
        do { try MeetingRecordStorage(url: storageURL).save(meetings); return true }
        catch {
            alertMessage = "회의 목록을 저장하지 못했습니다. 녹음 파일은 유지됩니다. \(error.localizedDescription)"
            return false
        }
    }

    private var canModifyMeetingIndex: Bool {
        guard let meetingIndexError else { return true }
        alertMessage = "회의 목록 파일을 먼저 복구해야 합니다. 기존 파일은 보존되어 있습니다. \(meetingIndexError)"
        return false
    }

    private func loadGlossary() {
        struct Document: Decodable {
            struct Entry: Decodable {
                let canonical: String
                let observedForms: [String]?
                let priority: Int
            }
            let entries: [Entry]
        }

        let url = storageURL.deletingLastPathComponent().appendingPathComponent("glossary.json")
        if let data = try? Data(contentsOf: url),
           let document = try? JSONDecoder().decode(Document.self, from: data) {
            glossaryTerms = document.entries
                .sorted { $0.priority > $1.priority }
                .map {
                    GlossaryTerm(
                        canonical: $0.canonical,
                        observedForms: $0.observedForms ?? [],
                        isEnabled: true
                    )
                }
            return
        }

        glossaryTerms = []
    }

    private static let demoMeeting: MeetingRecord = {
        let segments = [
            TranscriptSegment(
                startTime: 0,
                endTime: 18,
                speaker: "화자 A",
                text: "이번 릴리스에서는 기존 저장 형식을 유지하고 누락된 이벤트부터 확인하겠습니다.",
                confidence: 0.94,
                revisedText: nil
            ),
            TranscriptSegment(
                startTime: 18,
                endTime: 38,
                speaker: "화자 B",
                text: "저장 구조는 바꾸지 않고 출력 결과만 별도로 검증하는 것이 좋겠습니다.",
                confidence: 0.91,
                revisedText: nil
            ),
            TranscriptSegment(
                startTime: 38,
                endTime: 58,
                speaker: "화자 C",
                text: "그럼 이벤트 전달을 확인하고 저는 캐시 영향 범위를 정리하겠습니다.",
                confidence: 0.66,
                revisedText: "그럼 이벤트 전달을 확인하고 저는 캐시 영향 범위를 정리하겠습니다."
            ),
        ]
        return MeetingRecord(
            title: "제품 검토 회의",
            startedAt: Date().addingTimeInterval(-3_600),
            duration: 58,
            status: .needsReview,
            audioPath: nil,
            captureMode: .systemAndMicrophone,
            glossaryProfile: "사전 없음",
            transcript: segments,
            claims: [
                EvidenceClaim(
                    kind: .decision,
                    text: "기존 저장 형식을 유지합니다.",
                    owner: nil,
                    sourceSegmentIDs: [segments[0].id],
                    isReviewed: true
                ),
                EvidenceClaim(
                    kind: .action,
                    text: "이벤트 전달 누락 여부를 확인합니다.",
                    owner: nil,
                    sourceSegmentIDs: [segments[0].id, segments[2].id],
                    isReviewed: false
                ),
            ],
            errorMessage: nil
        )
    }()
}
