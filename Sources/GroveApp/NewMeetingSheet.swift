import SwiftUI

struct NewMeetingSheet: View {
    @ObservedObject var store: GroveStore
    @State private var title = ""
    @State private var profile = "사전 없음"
    @State private var captureMode: CaptureMode = .microphone

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("새 회의")
                    .font(.system(.title, design: .serif).weight(.semibold))
                Text("녹음 파일을 먼저 안전하게 저장한 뒤 전사를 시작합니다.")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("회의 제목", text: $title, prompt: Text("회의 제목 입력"))
                Picker("사전", selection: $profile) {
                    Text("사전 없음").tag("사전 없음")
                    if !store.glossaryTerms.isEmpty {
                        Text("사용자 사전").tag("사용자 사전")
                    }
                }

                Picker("입력", selection: $captureMode) {
                    ForEach(CaptureMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.symbol).tag(mode)
                    }
                }
                LabeledContent("저장") {
                    Text(captureMode == .microphone
                        ? "이 Mac · 원본 M4A"
                        : "이 Mac · System/Mic PCM 분리")
                }
            }
            .formStyle(.grouped)

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text(captureMode == .systemAndMicrophone
                    ? "화면 권한 없이 Core Audio로 Mac 출력과 마이크를 분리 저장합니다."
                    : "마이크만 녹음하고 회의 종료 후 한국어로 전사합니다.")
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
                            glossaryProfile: profile,
                            captureMode: captureMode
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
    }
}
