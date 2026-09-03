import AVFoundation
import Darwin
import Foundation
import MLX
import MLXAudioSTT

@main
struct MossHarness {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("MOSS worker: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        guard (4...5).contains(CommandLine.arguments.count) else {
            throw NSError(domain: "MossHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected input WAV, new output JSON, local model directory, and optional chunk seconds (1...180)"])
        }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let modelDirectory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw NSError(domain: "MossHarness", code: 6, userInfo: [NSLocalizedDescriptionKey: "Output already exists"])
        }
        let file = try AVAudioFile(forReading: input)
        guard file.processingFormat.sampleRate == 16_000,
              file.processingFormat.channelCount == 1,
              file.length > 0 else {
            throw NSError(domain: "MossHarness", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected nonempty mono 16kHz input"])
        }
        let chunkSeconds = CommandLine.arguments.count == 5
            ? (Int(CommandLine.arguments[4]) ?? 0)
            : (file.length <= 180 * 16_000 ? 180 : 60)
        guard (1...180).contains(chunkSeconds) else {
            throw NSError(domain: "MossHarness", code: 7, userInfo: [NSLocalizedDescriptionKey: "Chunk seconds must be 1...180"])
        }
        let started = Date()
        let model = try await MossTranscribeDiarizeModel.fromModelDirectory(modelDirectory)
        let loaded = Date()
        let parameters = STTGenerateParameters(maxTokens: 8192, temperature: 0, topP: 1, chunkDuration: Float(chunkSeconds), minChunkDuration: 0, repetitionContextSize: 100)
        let chunkFrames = AVAudioFrameCount(chunkSeconds * 16_000)
        var segments: [[String: Any]] = []
        var chunks: [[String: Any]] = []
        var generationTokens = 0
        var hitTokenLimit = false
        var hasUnparsedText = false
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let startFrame = file.framePosition
            let count = AVAudioFrameCount(min(Int64(chunkFrames), file.length - startFrame))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
                throw NSError(domain: "MossHarness", code: 3, userInfo: [NSLocalizedDescriptionKey: "PCM allocation failed"])
            }
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else {
                throw NSError(domain: "MossHarness", code: 4, userInfo: [NSLocalizedDescriptionKey: "PCM read ended before the audio file"])
            }
            let audio = MLXArray(Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))))
            print("Processing chunk \(chunks.count + 1) at \(Double(startFrame) / 16_000)s")
            fflush(stdout)
            let output = model.generate(audio: audio, generationParameters: parameters)
            let offset = Double(startFrame) / 16_000
            let capped = output.generationTokens >= 8192
            let parsedCompletely = isCompleteTimestampedOutput(output.text)
            hasUnparsedText = hasUnparsedText || !parsedCompletely
            let chunkIndex = chunks.count
            for var segment in output.segments ?? [] {
                guard let start = segment["start"] as? Double, let end = segment["end"] as? Double,
                      let text = segment["text"] as? String else {
                    throw NSError(domain: "MossHarness", code: 5, userInfo: [NSLocalizedDescriptionKey: "Malformed MOSS segment"])
                }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                segment["start"] = start + offset
                segment["end"] = end + offset
                segment["asr_chunk"] = chunkIndex
                segments.append(segment)
            }
            chunks.append([
                "index": chunkIndex, "start": offset,
                "end": Double(file.framePosition) / 16_000,
                "rawText": output.text, "generationTokens": output.generationTokens,
                "hitTokenLimit": capped,
                "parsedCompletely": parsedCompletely,
            ])
            generationTokens += output.generationTokens
            hitTokenLimit = hitTokenLimit || capped
            if capped || !parsedCompletely { break }
        }
        let finished = Date()
        let document: [String: Any] = [
            "model": "OpenMOSS-Team/MOSS-Transcribe-Diarize",
            "runtime": "mlx-audio-swift-v0.1.3",
            "chunkDurationSeconds": chunkSeconds,
            "chunkingPolicy": CommandLine.arguments.count == 5 ? "explicit" : "short-180-long-60-v1",
            "modelLoadSeconds": loaded.timeIntervalSince(started),
            "inferenceSeconds": finished.timeIntervalSince(loaded),
            "audioDurationSeconds": Double(file.length) / 16000,
            "text": segments.compactMap { $0["text"] as? String }.joined(separator: "\n"),
            "segments": segments,
            "chunks": chunks,
            "generationTokens": generationTokens,
            "hitTokenLimit": hitTokenLimit,
            "hasUnparsedText": hasUnparsedText,
            "processedAudioFrames": file.framePosition,
            "inputAudioFrames": file.length,
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outputURL, options: .atomic)
        print("Saved Swift MOSS output; chunks=\(chunks.count), tokens=\(generationTokens), inference=\(finished.timeIntervalSince(loaded))")
    }

    private static func isCompleteTimestampedOutput(_ raw: String) -> Bool {
        // Detect the upstream repetition guard ending mid-segment before maxTokens.
        // Empty chunks can be silence; nonempty unmatched text must not be published.
        let pattern = #"\[\d+(?:[\.,]\d+)?\]\[S\d+\].*?\[\d+(?:[\.,]\d+)?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return false }
        let remainder = regex.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
        return remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
