import AppKit
import GroveInference
import SwiftUI
import Testing
@testable import GroveApp

@MainActor
struct TranscriptLayoutRenderingTests {
    // Opt-in images use synthetic text in an offscreen host; no app is launched or window shown.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GROVE_LAYOUT_OUTPUT"] != nil))
    func renderSyntheticTranscriptAtCompactAndLargeTypeSizes() throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GROVE_LAYOUT_OUTPUT"]))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Grove.LayoutTest.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: base)
            defaults.removePersistentDomain(forName: suite)
        }
        _ = NSApplication.shared
        GroveTypography.registerFonts()
        let store = GroveStore(baseDirectory: base)
        let meeting = MeetingRecord(title: "레이아웃 테스트", startedAt: Date(), duration: 40, status: .ready,
                                    audioPath: nil, glossaryProfile: "", transcript: [], claims: [], errorMessage: nil)
        store.meetings = [meeting]
        let result = try InferenceResult(duration: 40, configuration: .init(expectedSpeakerCount: 3),
            transcription: .init(utterances: [
                .init(start: 0.08, end: 3.12, text: "오늘 논의할 내용을 먼저 정리하겠습니다."),
                .init(start: 4.1, end: 7.3, text: "네, 일정부터 확인하겠습니다."),
                .init(start: 7.8, end: 12.2, text: "같은 화자가 이어서 말해도 각 발화는 따로 수정할 수 있습니다."),
                .init(start: 13, end: 18, text: "긴 문장이 여러 줄로 표시될 때에도 왼쪽의 화자와 시작·종료 시간을 유지하고 본문이 오른쪽에서 자연스럽게 이어지는지 확인합니다."),
                .init(start: 20.2, end: 20.6, text: "네."),
                .init(start: 22, end: 27, text: "이 구간은 화자 활동이 비슷해서 확인이 필요합니다."),
                .init(start: 30, end: 34, text: "확인한 뒤 다음 내용으로 넘어가겠습니다.")
            ]), rawDiarization: [
                .init(start: 0, end: 3.2, clusterID: "A"), .init(start: 4, end: 18.2, clusterID: "B"),
                .init(start: 20, end: 20.7, clusterID: "A"), .init(start: 22, end: 27, clusterID: "B"),
                .init(start: 22, end: 26.5, clusterID: "C"), .init(start: 30, end: 34.1, clusterID: "A")
            ])
        try store.acceptInferenceResult(result, meetingID: meeting.id, sourceChannelID: "recording")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, width, scale, reviewing, scheme) in [
            ("compact", 780.0, 1.0, false, ColorScheme.dark),
            ("large-type", 600.0, 2.0, false, .dark),
            ("review", 780.0, 1.0, true, .dark),
            ("light", 780.0, 1.0, false, .light)
        ] {
            defaults.set(scale, forKey: "transcriptTextScale")
            let view = TranscriptView(store: store, meeting: meeting, reviewOnly: .constant(reviewing), showsSpeakers: .constant(false))
                .defaultAppStorage(defaults).environment(\.colorScheme, scheme)
                .frame(width: width, height: 740)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 740),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: width, height: 740)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("transcript-\(name).png"), options: .atomic)
            #expect(bitmap.pixelsWide >= Int(width))
            window.contentView = nil
        }
    }
}
