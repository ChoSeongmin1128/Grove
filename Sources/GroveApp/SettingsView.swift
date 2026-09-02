import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: GroveStore

    var body: some View {
        TabView {
            Form {
                LabeledContent("실시간 초안", value: "Apple Speech")
                LabeledContent("최종 전사", value: "Apple Speech")
                LabeledContent("WhisperKit", value: "검증 후 선택 적용")
                Toggle("원본 오디오 보존", isOn: $store.keepsOriginalAudio)
            }
            .formStyle(.grouped)
            .tabItem { Label("처리", systemImage: "waveform") }

            Form {
                Label("음성과 전사는 기본적으로 이 Mac에만 저장됩니다.", systemImage: "lock.shield")
                LabeledContent("저장 위치", value: "Application Support/Grove")
                Text("외부 서비스 자동 전송은 현재 비활성화되어 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("개인정보", systemImage: "hand.raised") }
        }
        .padding(12)
    }
}
