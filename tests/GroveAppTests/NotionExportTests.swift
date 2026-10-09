import Foundation
import Testing
@testable import GroveApp

private final class NotionProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [(Int, String)] = []
    nonisolated(unsafe) static var methods: [String] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    private static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.lock.withLock {
            Self.methods.append(request.httpMethod ?? "GET")
            if let body = request.httpBody { Self.bodies.append(body) }
            return Self.responses.isEmpty ? (500, "{}") : Self.responses.removeFirst()
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
@MainActor
struct NotionExportTests {
    private let parent = "01234567-89ab-cdef-0123-456789abcdef"
    private let child = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private func fixture() throws -> (MeetingRecord, TranscriptDocument) {
        let meeting = MeetingRecord(title: "정기 회의", startedAt: Date(timeIntervalSince1970: 0), duration: 2, status: .ready,
                                    glossaryProfile: "없음", transcript: [], claims: [])
        let document = try TranscriptDocument(speakers: [], utterances: [.init(id: UUID(), startTime: 0, endTime: 1,
            rawText: "원문을 유지합니다.", sourceChannelID: "recording", engineClusterID: nil, speakerID: nil, editedText: nil)])
        return (meeting, document)
    }
    private func client(_ responses: [(Int, String)]) -> NotionClient {
        NotionProtocol.responses = responses
        NotionProtocol.methods = []
        NotionProtocol.bodies = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NotionProtocol.self]
        return NotionClient(token: "synthetic-test-token", session: URLSession(configuration: configuration))
    }
    private var parentPage: String { "{\"object\":\"page\",\"id\":\"\(parent)\",\"properties\":{}}" }
    private var parentMarkdown: String { #"{"markdown":"기존 원문"}"# }
    private var dividerResult: String { #"{"markdown":"기존 원문\n---"}"# }
    private var childPage: String { "{\"object\":\"page\",\"id\":\"\(child)\",\"parent\":{\"page_id\":\"\(parent)\"}}" }
    @Test func repeatedApplyReusesReceiptWithoutAnotherCreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = NotionExporter(directory: directory)
        let (meeting, document) = try fixture()
        let client = client([(200, parentPage), (200, parentMarkdown), (200, dividerResult), (200, childPage), (200, childPage), (200, parentPage), (200, childPage)])
        let first = try await exporter.save(meeting: meeting, document: document, parentLink: parent, original: false, client: client)
        let repeated = try await exporter.save(meeting: meeting, document: document, parentLink: parent, original: false, client: client)
        #expect(first == repeated)
        #expect(NotionProtocol.methods.filter { $0 == "PATCH" }.count == 1)
        #expect(NotionProtocol.methods.filter { $0 == "POST" }.count == 1)
        #expect(try exporter.receipt(meetingID: meeting.id)?.verified == true)
    }
    @Test func uncertainCreationSurvivesRestartAndDoesNotCreateAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = NotionExporter(directory: directory)
        let (meeting, document) = try fixture()
        let client = client([(200, parentPage), (200, parentMarkdown), (200, dividerResult), (503, "{}"), (200, parentPage)])
        do { _ = try await exporter.save(meeting: meeting, document: document, parentLink: parent, original: false, client: client); Issue.record("서버 오류가 성공으로 처리됨") }
        catch { #expect(error is NotionExportError) }
        let reopened = NotionExporter(directory: directory)
        do { _ = try await reopened.save(meeting: meeting, document: document, parentLink: parent, original: false, client: client); Issue.record("불확실한 생성이 재시도됨") }
        catch { #expect(error is NotionExportError) }
        #expect(NotionProtocol.methods.filter { $0 == "POST" }.count == 1)
        #expect(try reopened.receipt(meetingID: meeting.id)?.pageID == nil)
    }
    @Test func asynchronousTaskIsNotMistakenForACreatedPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = NotionExporter(directory: directory)
        let (meeting, document) = try fixture()
        let task = "{\"object\":\"async_task\",\"id\":\"\(child)\",\"status\":\"queued\"}"
        let client = client([(200, parentPage), (200, parentMarkdown), (200, dividerResult), (202, task)])
        do {
            _ = try await exporter.save(meeting: meeting, document: document, parentLink: parent, original: false, client: client)
            Issue.record("비동기 작업이 생성된 페이지로 취급됨")
        } catch { if case NotionExportError.unknownResult = error {} else { Issue.record("예상하지 않은 오류: \(error)") } }
        #expect(try exporter.receipt(meetingID: meeting.id)?.pageID == nil)
        #expect(NotionProtocol.methods == ["GET", "GET", "PATCH", "POST"])
    }
    @Test func missingParentPermissionNeverUploadsTranscript() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = NotionExporter(directory: directory)
        let (meeting, document) = try fixture()
        let client = client([(404, "{}")])
        do { _ = try await exporter.save(meeting: meeting, document: document, parentLink: parent, original: false, client: client); Issue.record("권한 오류가 성공으로 처리됨") }
        catch { #expect(error is NotionExportError) }
        #expect(NotionProtocol.methods == ["GET"])
        #expect(try exporter.receipt(meetingID: meeting.id) == nil)
    }
    @Test func aDifferentReturnedPageNeverReceivesTheTranscript() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = NotionExporter(directory: directory)
        let (meeting, document) = try fixture()
        let client = client([(200, "{\"object\":\"page\",\"id\":\"\(child)\",\"properties\":{}}")])
        await #expect(throws: NotionExportError.self) { try await exporter.save(meeting: meeting, document: document, parentLink: parent, original: false, client: client) }
        #expect(NotionProtocol.methods == ["GET"])
        #expect(try exporter.receipt(meetingID: meeting.id) == nil)
    }
}

@MainActor
struct ExportPresentationTests {
    @Test func inferredSpeakerLabelMatchesInPlainTextAndRichText() throws {
        let profile = SavedSpeakerProfile(folderID: UUID(), name: "등록한 팀원", sourceMeetingID: nil,
            sourceRevisionID: nil, sourceSpeakerID: nil, createdAt: Date())
        let speaker = MeetingSpeaker(name: "화자 1", order: 0)
        let utterance = DocumentUtterance(id: UUID(), startTime: 0, endTime: 1, rawText: "검토할 내용입니다.",
            sourceChannelID: "recording", engineClusterID: "0", speakerID: speaker.id, editedText: nil)
        var document = try TranscriptDocument(speakers: [speaker], utterances: [utterance])
        try document.applySpeakerProfile(profile, to: speaker.id, similarity: 0.9, confirmed: false)
        let meeting = MeetingRecord(title: "검토 회의", startedAt: Date(), duration: 1, status: .ready,
            glossaryProfile: "", transcript: [], claims: [])
        #expect(MeetingExportContent.markdown(meeting: meeting, document: document, original: false).contains(TranscriptRenderer.escapeMarkdown("등록한 팀원 (추정)")))
        #expect(MeetingExportContent.html(meeting: meeting, document: document, original: false).contains("등록한 팀원 (추정)"))
        try document.confirmSpeakerIdentity(speaker.id)
        #expect(!MeetingExportContent.html(meeting: meeting, document: document, original: false).contains("(추정)"))
    }
}
