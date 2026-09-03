import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: GroveStore

    var body: some View {
        TabView {
            Form {
                LabeledContent("전사 시점", value: "녹음 종료 후")
                LabeledContent("전사 모델", value: "MOSS · 로컬 베타")
                Section("새 녹음·가져오기의 기본값") {
                    MeetingSpeakerOptionsView(options: $store.defaultSpeakerOptions)
                    Text("각 녹음에서 따로 변경할 수 있습니다. 기존 녹음에는 적용되지 않습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("이 베타에서는 사용자 사전이 전사에 적용되지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("원본 보관", value: "녹음 파일과 전사 원문 유지")
                Text("텍스트와 화자를 수정해도 원문은 바뀌지 않습니다. 대화 화면에서 변경을 되돌릴 수 있습니다.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("처리", systemImage: "waveform") }

            Form {
                Label("음성과 전사는 기본적으로 이 Mac에만 저장됩니다.", systemImage: "lock.shield")
                LabeledContent("저장 위치", value: "Application Support/Grove")
                Text("녹음과 전사를 외부 서비스로 자동 전송하는 기능은 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("개인정보", systemImage: "hand.raised") }
        }
        .padding(12)
    }
}
