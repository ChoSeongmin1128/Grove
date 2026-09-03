import Foundation
import GroveInference
import Testing
@testable import GroveApp

private func unitVoice(_ dimension: Int, model: String = "test-model") -> SpeakerVoicePrint {
    var embedding = [Float](repeating: 0, count: 256)
    embedding[dimension] = 1
    return SpeakerVoicePrint(modelIdentifier: model, embedding: embedding, speechDuration: 8, sampleCount: 2)
}

private func savedProfile(_ dimension: Int, folder: UUID, name: String) -> SavedSpeakerProfile {
    SavedSpeakerProfile(folderID: folder, name: name, voice: unitVoice(dimension), sourceMeetingID: UUID(),
        sourceRevisionID: UUID(), sourceSpeakerID: UUID(), createdAt: Date())
}

struct SavedSpeakerProfileTests {
    @Test func attendanceChangesMatchOnlyKnownVoicesAndLeaveUnknownUnassigned() {
        let folder = UUID()
        let a = savedProfile(0, folder: folder, name: "A")
        let b = savedProfile(1, folder: folder, name: "B")
        let c = savedProfile(2, folder: folder, name: "C")
        let ids = [UUID(), UUID(), UUID()]
        let matches = SpeakerProfileMatcher.matches(voices: [ids[0]: unitVoice(0), ids[1]: unitVoice(2), ids[2]: unitVoice(3)], profiles: [a, b, c])
        #expect(Set(matches.map { $0.profile.name }) == ["A", "C"])
        #expect(!matches.contains { $0.speakerID == ids[2] })
        #expect(SpeakerProfileMatcher.matches(voices: [ids[0]: unitVoice(0, model: "incompatible")], profiles: [a]).isEmpty)
    }

    @Test func ambiguousOrDuplicateAssignmentsAreNotForced() {
        let folder = UUID()
        let a = savedProfile(0, folder: folder, name: "A")
        let duplicate = savedProfile(0, folder: folder, name: "B")
        #expect(SpeakerProfileMatcher.matches(voices: [UUID(): unitVoice(0)], profiles: [a, duplicate]).isEmpty)
        #expect(SpeakerProfileMatcher.matches(voices: [UUID(): unitVoice(0), UUID(): unitVoice(0)], profiles: [a]).isEmpty)
        #expect(SpeakerProfileMatcher.cosine([0, 0], [0, 0]) == nil)
        #expect(SpeakerProfileMatcher.cosine([Float.nan], [1]) == nil)
    }

    @Test func inferredNameIsReversibleAndManualRenameClearsIdentity() throws {
        let speaker = MeetingSpeaker(name: "화자 1", order: 0)
        let utterance = DocumentUtterance(id: UUID(), startTime: 0, endTime: 4, rawText: "원문", sourceChannelID: "recording", engineClusterID: "0", speakerID: speaker.id)
        var doc = try TranscriptDocument(speakers: [speaker], utterances: [utterance])
        let profile = savedProfile(0, folder: UUID(), name: "A")
        try doc.applySpeakerProfile(profile, to: speaker.id, similarity: 0.9, confirmed: false)
        #expect(doc.schemaVersion == 5)
        #expect(doc.speakers[0].name == "A")
        #expect(doc.speakers[0].profileMatch?.isConfirmed == false)
        #expect(TranscriptRenderer.render(doc).contains("A (추정)"))
        #expect(TranscriptRenderer.render(doc, options: .init(format: .markdown, selectedUtteranceIDs: [utterance.id])).contains("A \\(추정\\)"))
        try doc.undo()
        #expect(doc.speakers[0].name == "화자 1")
        #expect(doc.speakers[0].profileMatch == nil)
        try doc.redo()
        try doc.renameSpeaker(speaker.id, to: "다른 사람")
        #expect(doc.speakers[0].profileMatch == nil)
        #expect(doc.utterances[0].rawText == "원문")
        let restored = try JSONDecoder().decode(TranscriptDocument.self, from: JSONEncoder().encode(doc))
        #expect(restored == doc)
    }

    @Test func cleanEnrollmentExcludesOverlapAndShortFragments() throws {
        let a = MeetingSpeaker(name: "A", order: 0)
        let b = MeetingSpeaker(name: "B", order: 1)
        func utterance(_ start: Double, _ end: Double, _ id: UUID) -> DocumentUtterance {
            .init(id: UUID(), startTime: start, endTime: end, rawText: "발화", sourceChannelID: "recording", engineClusterID: nil, speakerID: id)
        }
        let doc = try TranscriptDocument(speakers: [a, b], utterances: [utterance(0, 5, a.id), utterance(6, 11, a.id), utterance(12, 18, a.id), utterance(14, 17, b.id), utterance(19, 20, a.id)])
        let ranges = try VoiceProfileSelection.ranges(in: doc, speakerID: a.id)
        #expect(ranges.count == 2)
        #expect(ranges.allSatisfy { $0.end < 12 })
        #expect(throws: VoiceProfileError.self) { try VoiceProfileSelection.ranges(in: doc, speakerID: b.id) }
    }

    @Test func removedVoiceprintsDoNotSurviveInMetadataBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = MeetingLibraryStorage(url: root.appendingPathComponent("library.json"))
        let folder = MeetingFolder(name: "폴더")
        let profile = savedProfile(0, folder: folder.id, name: "A")
        var library = MeetingLibrary()
        library.folders = [folder]
        library.speakerProfiles = [profile]
        try storage.save(library)
        library.speakerProfiles = []
        try storage.save(library)
        let backup = try JSONDecoder().decode(MeetingLibrary.self, from: Data(contentsOf: storage.url.appendingPathExtension("backup")))
        #expect(backup.speakerProfiles?.isEmpty == true)
        #expect(try storage.load().speakerProfiles?.isEmpty == true)
    }
}
