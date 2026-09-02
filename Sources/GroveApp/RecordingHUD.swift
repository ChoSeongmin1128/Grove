import SwiftUI

struct RecordingHUD: View {
    @ObservedObject var store: GroveStore
    @ObservedObject private var recorder: AudioRecorder
    @ObservedObject private var systemCapture: SystemAudioTapService
    let meeting: MeetingRecord

    init(store: GroveStore, meeting: MeetingRecord) {
        self.store = store
        self.meeting = meeting
        recorder = store.recorder
        systemCapture = store.systemCapture
    }

    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .shadow(color: .red.opacity(0.35), radius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("원본 저장 중")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(elapsed.clockString)
                .font(.body.monospacedDigit().weight(.medium))
            if store.activeCaptureMode == .systemAndMicrophone {
                channelMeter(
                    label: "System",
                    symbol: "speaker.wave.2.fill",
                    level: systemCapture.level
                )
                channelMeter(
                    label: "Mic",
                    symbol: "mic.fill",
                    level: recorder.level
                )
            } else {
                channelMeter(label: "Mic", symbol: "mic.fill", level: recorder.level)
            }
            Divider().frame(height: 26)
            Button("종료") {
                Task { await store.stopRecording() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.22))
        }
        .shadow(color: .black.opacity(0.16), radius: 20, y: 7)
        .frame(maxWidth: 760)
    }

    private var elapsed: TimeInterval {
        store.activeCaptureMode == .systemAndMicrophone
            ? max(systemCapture.elapsed, recorder.elapsed)
            : recorder.elapsed
    }

    private func channelMeter(label: String, symbol: String, level: Double) -> some View {
        HStack(spacing: 7) {
            LevelMeter(level: level)
                .frame(width: 58, height: 24)
            Label(label, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(level > 0.03 ? GroveTheme.grove : .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) 입력 레벨")
        .accessibilityValue("\(Int(level * 100))퍼센트")
    }
}

private struct LevelMeter: View {
    let level: Double

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<8, id: \.self) { index in
                let threshold = Double(index + 1) / 8
                Capsule()
                    .fill(level >= threshold ? GroveTheme.grove : Color.secondary.opacity(0.18))
                    .frame(width: 4, height: 7 + CGFloat(index % 4) * 4)
            }
        }
    }
}
