import SwiftUI

struct MeetingSpeakerOptionsView: View {
    @Binding var options: MeetingSpeakerOptions
    var isDual = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("화자 분리 엔진", selection: $options.engineChoice) {
                ForEach(MeetingEngineChoice.allCases) { engine in Text(engine.label).tag(engine) }
            }
            Picker("화자 수", selection: $options.mode) {
                ForEach(MeetingProcessingMode.allCases) { mode in Text(mode.label).tag(mode) }
            }
            if options.mode == .manualCount {
                if isDual {
                    countField("컴퓨터 소리의 화자 수", text: $options.systemCountText)
                    countField("마이크의 화자 수", text: $options.microphoneCountText)
                    Text("각 채널에서 실제로 발언한 사람 수를 입력하세요. 전체 참석자 수를 양쪽에 반복 입력하지 않습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    countField("발화한 사람 수", text: $options.countText)
                    Text("참석자 총원이 아니라 녹음에서 실제로 발언한 사람 수를 입력하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = options.validationMessage(isDual: isDual) {
                    Text(error).font(.caption).foregroundStyle(GroveTheme.evidence)
                }
            }
            Text(engineExplanation).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var engineExplanation: String {
        switch options.engineChoice {
        case .automatic:
            return "인원 미입력 또는 1–8명은 Ultra8, 9명 이상은 Community-1을 사용합니다. 인원 미입력은 최대 8명까지만 구분하므로, 9명 이상이면 인원을 입력해 주세요. Ultra8에서는 인원수가 강제되지 않습니다."
        case .sortformerStreaming:
            return "최대 4명까지 자동으로 구분합니다. 입력 인원은 결과 확인용이며, 모델에 인원수를 강제하지 않습니다."
        case .ultra8:
            return "최대 8명까지 자동으로 구분합니다. 입력 인원은 결과 확인용이며, 모델에 인원수를 강제하지 않습니다. 한국어 5명 이상 정확도는 추가 검증이 필요합니다."
        case .community1:
            return options.mode == .manualCount ? "입력한 인원수를 화자 분리에 적용합니다." : "인원수를 지정하지 않고 자동으로 추정합니다."
        }
    }

    private func countField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(label, text: text, prompt: Text("숫자 입력"))
                .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 96)
                .accessibilityLabel(label)
            Text("명").foregroundStyle(.secondary)
        }
    }
}

struct ImportRecordingOptionsSheet: View {
    @ObservedObject var store: GroveStore
    let source: URL
    @State private var options: MeetingSpeakerOptions
    @State private var folderID: UUID?
    @Environment(\.dismiss) private var dismiss

    init(store: GroveStore, source: URL) {
        self.store = store
        self.source = source
        _options = State(initialValue: store.defaultSpeakerOptions)
        _folderID = State(initialValue: store.selectedFolderID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("녹음 파일 전사").font(GroveTypography.title)
            Text(source.lastPathComponent).lineLimit(2).foregroundStyle(.secondary)
            RecordingFolderPicker(store: store, folderID: $folderID)
            MeetingSpeakerOptionsView(options: $options)
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("전사 시작") {
                    guard let plan = try? options.plan(isDual: false) else { return }
                    dismiss()
                    Task { await store.importRecording(from: source, plan: plan, folderID: folderID) }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(store.isBusy || (try? options.plan(isDual: false)) == nil)
            }
        }.padding(24).frame(width: 460)
    }
}
