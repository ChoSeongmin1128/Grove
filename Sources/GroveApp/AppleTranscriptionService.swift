@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

struct AppleTranscriptionOutput: Sendable {
    let text: String
    let meanConfidence: Double?
    let duration: TimeInterval
}

enum AppleTranscriptionService {
    static func transcribe(
        file: URL,
        contextualStrings: [String]
    ) async throws -> AppleTranscriptionOutput {
        let requestedLocale = Locale(identifier: "ko-KR")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw TranscriptionError.unsupportedKorean
        }

        let audioFile = try AVAudioFile(forReading: file)
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try await analyzer.setContext(context)
        }

        let resultTask = Task { () throws -> (String, [Double]) in
            var text = ""
            var confidences: [Double] = []
            for try await result in transcriber.results {
                text += String(result.text.characters)
                for run in result.text.runs {
                    if let confidence = run.transcriptionConfidence {
                        confidences.append(confidence)
                    }
                }
            }
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), confidences)
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let (text, confidences) = try await resultTask.value
            let confidence = confidences.isEmpty
                ? nil
                : confidences.reduce(0, +) / Double(confidences.count)
            return AppleTranscriptionOutput(
                text: text,
                meanConfidence: confidence,
                duration: duration
            )
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}

enum TranscriptionError: LocalizedError {
    case unsupportedKorean
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .unsupportedKorean:
            "이 Mac에 Apple 한국어 음성 모델이 준비되지 않았습니다. 인터넷 연결 후 다시 시도해 주세요."
        case .emptyResult:
            "음성을 찾지 못했습니다. 녹음의 입력 레벨과 마이크 장치를 확인해 주세요."
        }
    }
}
