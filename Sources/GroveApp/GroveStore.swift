import Foundation

@MainActor
final class GroveStore: ObservableObject {
    @Published var meetings: [MeetingRecord] = []
    @Published var glossaryTerms: [GlossaryTerm] = []
    @Published var selection: SidebarDestination? = .library
    @Published var selectedTab: MeetingTab = .minutes
    @Published var isPresentingNewMeeting = false
    @Published var isPresentingImporter = false
    @Published var alertMessage: String?
    @Published var activeMeetingID: UUID?
    @Published var processingStage: String?
    @Published var keepsOriginalAudio = true
    @Published var activeCaptureMode: CaptureMode?

    let recorder = AudioRecorder()
    let systemCapture = SystemAudioTapService()

    private let storageURL: URL
    private let audioDirectory: URL
    private let isDemoMode: Bool

    init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Grove", isDirectory: true)
        storageURL = base.appendingPathComponent("meetings.json")
        audioDirectory = base.appendingPathComponent("Audio", isDirectory: true)
        isDemoMode = CommandLine.arguments.contains("--demo")

        try? FileManager.default.createDirectory(
            at: audioDirectory,
            withIntermediateDirectories: true
        )
        loadGlossary()
        if isDemoMode {
            meetings = [Self.demoMeeting]
            selection = .meeting(Self.demoMeeting.id)
        } else {
            loadMeetings()
            recoverInterruptedCaptures()
        }
    }

    var activeMeeting: MeetingRecord? {
        guard let activeMeetingID else { return nil }
        return meetings.first { $0.id == activeMeetingID }
    }

    var isRecording: Bool {
        recorder.isRecording || systemCapture.isRecording
    }

    var approvedContextStrings: [String] {
        glossaryTerms
            .filter(\.isEnabled)
            .flatMap { [$0.canonical] + $0.observedForms }
    }

    func beginRecording(
        title: String,
        glossaryProfile: String,
        captureMode: CaptureMode
    ) async {
        guard !isRecording else { return }
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
            audioPath: captureMode == .microphone ? audioURL.path : nil,
            captureMode: captureMode,
            glossaryProfile: glossaryProfile,
            transcript: [],
            claims: [],
            errorMessage: nil
        )

        let dualDirectory = audioDirectory.appendingPathComponent(
            id.uuidString,
            isDirectory: true
        )
        do {
            if captureMode == .microphone {
                try recorder.start(to: audioURL)
            } else {
                isPresentingNewMeeting = false
                let microphoneURL = dualDirectory.appendingPathComponent("microphone.m4a")
                try systemCapture.start(
                    sessionID: id,
                    directory: dualDirectory,
                    microphoneURL: microphoneURL
                )
                do {
                    try recorder.start(to: microphoneURL)
                } catch {
                    systemCapture.cancel(errorMessage: error.localizedDescription)
                    throw error
                }
                meeting.systemAudioPath = dualDirectory
                    .appendingPathComponent("system-audio.caf").path
                meeting.microphoneAudioPath = microphoneURL.path
                meeting.captureManifestPath = dualDirectory
                    .appendingPathComponent("capture-manifest.json").path
            }
            meetings.insert(meeting, at: 0)
            activeMeetingID = id
            activeCaptureMode = captureMode
            selection = .meeting(id)
            selectedTab = .transcript
            isPresentingNewMeeting = false
            saveMeetings()
        } catch {
            meeting.status = .failed
            meeting.errorMessage = error.localizedDescription
            alertMessage = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard let id = activeMeetingID,
              let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        if activeCaptureMode == .systemAndMicrophone {
            do {
                _ = recorder.stop()
                let result = try systemCapture.stop()
                meetings[index].duration = result.duration
                meetings[index].systemAudioPath = result.systemAudioURL.path
                meetings[index].microphoneAudioPath = result.microphoneURL.path
                meetings[index].captureManifestPath = result.manifestURL.path
                meetings[index].status = .processing
                processingStage = "두 채널을 Apple 한국어 모델로 정확 전사 중"
                activeCaptureMode = nil
                saveMeetings()
                await transcribeDualMeeting(id: id, result: result)
            } catch {
                meetings[index].status = .failed
                meetings[index].errorMessage = error.localizedDescription
                activeCaptureMode = nil
                alertMessage = error.localizedDescription
                saveMeetings()
            }
        } else {
            meetings[index].duration = recorder.stop()
            meetings[index].status = .processing
            processingStage = "Apple 한국어 모델로 정확 전사 중"
            activeCaptureMode = nil
            saveMeetings()
            await transcribeMeeting(id: id)
        }
    }

    func importRecording(from sourceURL: URL) async {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if access { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let id = UUID()
        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let target = audioDirectory.appendingPathComponent("\(id.uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: sourceURL, to: target)
            let meeting = MeetingRecord(
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
            meetings.insert(meeting, at: 0)
            activeMeetingID = id
            selection = .meeting(id)
            selectedTab = .transcript
            processingStage = "가져온 파일을 Apple 한국어 모델로 전사 중"
            saveMeetings()
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
        meetings.removeAll { $0.id == meeting.id }
        if selection == .meeting(meeting.id) { selection = .library }
        if !isDemoMode {
            let paths = [
                meeting.audioPath,
                meeting.systemAudioPath,
                meeting.microphoneAudioPath,
                meeting.captureManifestPath,
            ].compactMap { $0 }
            for path in Set(paths) {
                try? FileManager.default.removeItem(atPath: path)
            }
            if let manifestPath = meeting.captureManifestPath {
                let directory = URL(fileURLWithPath: manifestPath).deletingLastPathComponent()
                try? FileManager.default.removeItem(at: directory)
            }
        }
        saveMeetings()
    }

    private func transcribeMeeting(id: UUID) async {
        guard let index = meetings.firstIndex(where: { $0.id == id }),
              let path = meetings[index].audioPath else { return }
        do {
            let contextStrings = meetings[index].glossaryProfile == "사전 없음"
                ? []
                : approvedContextStrings
            let output = try await AppleTranscriptionService.transcribe(
                file: URL(fileURLWithPath: path),
                contextualStrings: contextStrings
            )
            guard !output.text.isEmpty else { throw TranscriptionError.emptyResult }
            let segment = TranscriptSegment(
                startTime: 0,
                endTime: output.duration,
                speaker: "화자 1",
                text: output.text,
                confidence: output.meanConfidence,
                revisedText: nil
            )
            guard let updatedIndex = meetings.firstIndex(where: { $0.id == id }) else { return }
            meetings[updatedIndex].duration = output.duration
            meetings[updatedIndex].transcript = [segment]
            meetings[updatedIndex].status = (output.meanConfidence ?? 1) < 0.72
                ? .needsReview
                : .ready
            meetings[updatedIndex].errorMessage = nil
            processingStage = nil
            saveMeetings()
        } catch {
            guard let updatedIndex = meetings.firstIndex(where: { $0.id == id }) else { return }
            meetings[updatedIndex].status = .failed
            meetings[updatedIndex].errorMessage = error.localizedDescription
            processingStage = nil
            alertMessage = error.localizedDescription
            saveMeetings()
        }
    }

    private func transcribeDualMeeting(
        id: UUID,
        result: SystemAudioCaptureResult
    ) async {
        guard let meetingIndex = meetings.firstIndex(where: { $0.id == id }) else { return }
        let contextStrings = meetings[meetingIndex].glossaryProfile == "사전 없음"
            ? []
            : approvedContextStrings
        var segments: [TranscriptSegment] = []
        var errors: [String] = []

        if result.systemBufferCount > 0 {
            do {
                let output = try await AppleTranscriptionService.transcribe(
                    file: result.systemAudioURL,
                    contextualStrings: contextStrings
                )
                if !output.text.isEmpty {
                    segments.append(
                        TranscriptSegment(
                            startTime: 0,
                            endTime: output.duration,
                            speaker: "원격 오디오",
                            text: output.text,
                            confidence: output.meanConfidence,
                            revisedText: nil
                        )
                    )
                }
            } catch {
                errors.append("시스템 오디오: \(error.localizedDescription)")
            }
        }

        if result.microphoneFrameCount > 0 {
            do {
                let output = try await AppleTranscriptionService.transcribe(
                    file: result.microphoneURL,
                    contextualStrings: contextStrings
                )
                if !output.text.isEmpty {
                    segments.append(
                        TranscriptSegment(
                            startTime: 0,
                            endTime: output.duration,
                            speaker: "내 마이크",
                            text: output.text,
                            confidence: output.meanConfidence,
                            revisedText: nil
                        )
                    )
                }
            } catch {
                errors.append("마이크: \(error.localizedDescription)")
            }
        }

        guard let updatedIndex = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[updatedIndex].transcript = segments.sorted { $0.startTime < $1.startTime }
        meetings[updatedIndex].status = segments.isEmpty ? .failed : .needsReview
        meetings[updatedIndex].errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        processingStage = nil
        if segments.isEmpty {
            alertMessage = errors.joined(separator: "\n")
        }
        saveMeetings()
    }

    private func loadMeetings() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        meetings = (try? decoder.decode([MeetingRecord].self, from: data)) ?? []
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
            if let startedAt = manifest.startedAt {
                duration = max(0, (manifest.endedAt ?? Date()).timeIntervalSince(startedAt))
            } else {
                duration = 0
            }
            if let index = meetings.firstIndex(where: { $0.id == manifest.sessionID }) {
                meetings[index].status = .needsReview
                meetings[index].duration = max(meetings[index].duration, duration)
                meetings[index].systemAudioPath = manifest.systemAudio.path
                meetings[index].microphoneAudioPath = manifest.microphone.path
                meetings[index].captureManifestPath = manifestURL.path
                meetings[index].captureMode = .systemAndMicrophone
                meetings[index].errorMessage = "이전 앱 실행이 녹음 중 종료됐습니다. 저장된 PCM 채널을 검토해 주세요."
            } else {
                meetings.insert(
                    MeetingRecord(
                        id: manifest.sessionID,
                        title: "복구된 회의",
                        startedAt: manifest.startedAt ?? manifest.createdAt,
                        duration: duration,
                        status: .needsReview,
                        audioPath: nil,
                        systemAudioPath: manifest.systemAudio.path,
                        microphoneAudioPath: manifest.microphone.path,
                        captureManifestPath: manifestURL.path,
                        captureMode: .systemAndMicrophone,
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

    private func saveMeetings() {
        guard !isDemoMode else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(meetings) else { return }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storageURL, options: .atomic)
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
