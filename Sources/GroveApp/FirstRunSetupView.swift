import GroveInference
import SwiftUI

struct FirstRunSetupView: View {
    @ObservedObject var store: GroveStore
    @ObservedObject private var models: ModelManager
    @ObservedObject private var apple: AppleTranscriptionPreparation
    init(store: GroveStore) {
        self.store = store
        models = store.modelManager
        apple = store.applePreparation
    }
    private var selected: TranscriptionEngine { store.defaultSpeakerOptions.transcriptionEngine }
    private var isPreparing: Bool { models.isInstalling || apple.isPreparing }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "waveform").font(.system(size: 38)).foregroundStyle(GroveTheme.grove)
                Text("Grove 시작하기").font(GroveTypography.title)
                Text("회의를 녹음하고, 이 Mac에서 전사하세요.").font(GroveTypography.body).foregroundStyle(.secondary)
                choice(.moss, title: "정밀 전사 / 화자 분리", detail: "한국어 전사와 최대 8명의 화자 구분. 기본 모델 약 1.9 GB를 한 번 준비합니다.")
                choice(.apple, title: "Mac 기본 전사", detail: "Grove 모델 설치 없이 macOS 전사를 사용합니다. 화자 구분은 제공하지 않습니다.")
                if selected == .apple {
                    Text("한국어 언어 자산이 없으면 macOS가 Apple에서 내려받습니다. 준비한 자산은 다른 앱과 공유합니다.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let progress = apple.progress, apple.isPreparing { ProgressView(progress) }
                    if let message = apple.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                    if !apple.isSupported { Text(apple.hasChecked ? "이 Mac은 기본 한국어 전사를 지원하지 않습니다. 정밀 전사를 선택해 주세요." : "한국어 지원 여부를 확인하고 있습니다.").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("실행 엔진은 앱에 포함됩니다. 모델은 파일 검증과 짧은 실행 검사를 마친 뒤 사용할 수 있습니다.")
                        .font(.callout).foregroundStyle(.secondary)
                    if models.isInstalling {
                        ProgressView(value: models.fraction)
                        Text("\(ByteCountFormatter.string(fromByteCount: models.downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: models.totalBytes, countStyle: .file))")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if let message = models.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                }
                HStack {
                    if isPreparing {
                        ProgressView().controlSize(.small)
                        Button("준비 중단") { models.cancel(); apple.cancel() }
                    } else {
                        Button(models.hasPartialDownloads && selected == .moss ? "이어받기" : "시작하기") {
                            if selected == .apple { apple.prepare() } else { models.install() }
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                        Text("다음 실행부터 준비한 모델을 재사용합니다.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(36).frame(maxWidth: 620)
                .frame(maxWidth: .infinity, alignment: .center)
        }.task { await apple.refresh() }
    }
    private func choice(_ engine: TranscriptionEngine, title: String, detail: String) -> some View {
        Button {
            var options = store.defaultSpeakerOptions
            options.transcriptionEngine = engine
            store.defaultSpeakerOptions = options
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: selected == engine ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected == engine ? GroveTheme.grove : Color.secondary)
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(GroveTypography.heading).foregroundStyle(GroveTheme.ink)
                    Text(detail).font(GroveTypography.bodySmall).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }.padding(18).background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(selected == engine ? GroveTheme.grove : GroveTheme.divider, lineWidth: selected == engine ? 2 : 1) }
        }.buttonStyle(.plain).disabled(isPreparing)
    }
}
