import AVFoundation
import CoreML
import Foundation
import Testing
@testable import GroveInference

struct VoiceEmbeddingExtractorTests {
    private func vector(_ index: Int) -> [Float] {
        var result = [Float](repeating: 0, count: 256)
        result[index] = 1
        return result
    }

    @Test func perSampleRangeContractPreservesOrderAndRejectsSilentTrimming() throws {
        let ranges = [VoiceSampleRange(start: 5, end: 8), .init(start: 0, end: 3)]
        #expect(try VoiceEmbeddingMath.strictRanges(ranges) == ranges)
        #expect(throws: InferenceError.self) { try VoiceEmbeddingMath.strictRanges([.init(start: 0, end: 11)]) }
        #expect(throws: InferenceError.self) { try VoiceEmbeddingMath.strictRanges([.init(start: 0, end: 1.9), .init(start: 3, end: 6)]) }
        #expect(throws: InferenceError.self) { try VoiceEmbeddingMath.strictRanges([.init(start: 0, end: 3), .init(start: 2, end: 5)]) }
        let sample = VoiceEmbeddingSample(range: ranges[0], voicePrint: SpeakerVoicePrint(
            modelIdentifier: "synthetic", embedding: vector(0), speechDuration: 3, sampleCount: 1))
        #expect(try JSONDecoder().decode(VoiceEmbeddingSample.self, from: JSONEncoder().encode(sample)) == sample)
    }

    @Test func rangeSelectionIsBoundedAndDoesNotCountOverlappingAudioTwice() throws {
        let ranges: [VoiceSampleRange] = (0..<8).map { (index: Int) -> VoiceSampleRange in
            let start = Double(index) * 20
            return VoiceSampleRange(start: start, end: start + 15)
        }
        let selected = try VoiceEmbeddingMath.selectRanges(Array(ranges.reversed()))
        #expect(selected.count == 5)
        #expect(selected.map { $0.end - $0.start } == [10, 10, 10, 10, 10])
        #expect(selected[0].start == 0)
        #expect(selected[4].start == 80)
        #expect(throws: InferenceError.self) {
            try VoiceEmbeddingMath.selectRanges([.init(start: 0, end: 3), .init(start: 2, end: 5)])
        }
    }

    @Test func invalidAndTooShortRangesAreRejectedButOneUsableSpanSupportsDiagnostics() throws {
        for range in [VoiceSampleRange(start: -1, end: 3), .init(start: 2, end: 2),
                      .init(start: .nan, end: 3), .init(start: 0, end: .infinity), .init(start: 0, end: 1.99)] {
            #expect(throws: InferenceError.self) { try VoiceEmbeddingMath.selectRanges([range]) }
        }
        #expect(throws: InferenceError.self) { try VoiceEmbeddingMath.selectRanges([]) }
        #expect(try VoiceEmbeddingMath.selectRanges([.init(start: 0, end: 2)]) == [.init(start: 0, end: 2)])
        #expect(throws: InferenceError.self) {
            try VoiceEmbeddingMath.frameRanges([.init(start: 1, end: 4)], frameCount: 48_000)
        }
        let frames = try VoiceEmbeddingMath.frameRanges([.init(start: 1, end: 3)], frameCount: 48_000)
        #expect(frames[0].start == 16_000)
        #expect(frames[0].count == 32_000)
    }

    @Test func paddingFramesNeverContributeToSpeakerPooling() {
        let weights = VoiceEmbeddingMath.weights(activeSamples: 32_000)
        #expect(weights.count == 589)
        #expect(weights.filter { $0 == 1 }.count == 118)
        #expect(weights.dropFirst(118).allSatisfy { $0 == 0 })
        #expect(VoiceEmbeddingMath.weights(activeSamples: 160_000).allSatisfy { $0 == 1 })
        #expect(VoiceEmbeddingMath.weights(activeSamples: 0).allSatisfy { $0 == 0 })
    }

    @Test func activeFrameCenteringCancelsPaddedGlobalOffsetAndKeepsTailNeutral() throws {
        let count = (32_000 - 400) / 160 + 1
        var first = [Float](repeating: -40, count: 80 * 998)
        var shifted = first
        for band in 0..<80 {
            for frame in 0..<count {
                first[band * 998 + frame] = Float(frame % 5) + 17
                shifted[band * 998 + frame] = first[band * 998 + frame] - 9
            }
        }
        let one = try VoiceEmbeddingMath.multiArray(values: first, shape: [1, 1, 80, 998], dataType: .float32)
        let two = try VoiceEmbeddingMath.multiArray(values: shifted, shape: [1, 1, 80, 998], dataType: .float32)
        let centered = try VoiceEmbeddingMath.centerActiveFrames(one, activeSamples: 32_000)
        let same = try VoiceEmbeddingMath.centerActiveFrames(two, activeSamples: 32_000)
        #expect((0..<centered.count).allSatisfy { abs(centered[$0].floatValue - same[$0].floatValue) < 1e-6 })
        #expect(abs((0..<count).reduce(0.0) { $0 + Double(centered[$1].floatValue) }) < 1e-4)
        #expect((count..<998).allSatisfy { centered[$0].floatValue == 0 })
    }

    @Test func float16AndFloat32ArraysUseTheActualDeclaredType() throws {
        for type in [MLMultiArrayDataType.float16, .float32] {
            let values: [Float] = [0, 0.5, -0.25, 1]
            let array = try VoiceEmbeddingMath.multiArray(values: values, shape: [1, 4], dataType: type)
            #expect(array.dataType == type)
            #expect((0..<array.count).map { array[$0].floatValue } == values)
            let converted = try VoiceEmbeddingMath.convert(array, to: .float32)
            #expect((0..<converted.count).map { converted[$0].floatValue } == values)
        }
        #expect(throws: InferenceError.self) { try VoiceEmbeddingMath.multiArray(values: [1], shape: [1], dataType: .double) }
        #expect(throws: InferenceError.self) { try VoiceEmbeddingMath.multiArray(values: [.infinity], shape: [1], dataType: .float32) }
        #expect(throws: InferenceError.self) { try VoiceEmbeddingMath.multiArray(values: [100_000], shape: [1], dataType: .float16) }
    }

    @Test func unitNormalizationAndDurationWeightedCentroidRemainFinite() throws {
        let unit = try VoiceEmbeddingMath.normalized(vector(0).map { $0 * 8 })
        #expect(unit == vector(0))
        let centroid = try VoiceEmbeddingMath.centroid([vector(0), vector(1)], durations: [3, 4])
        #expect(abs(centroid[0] - 0.6) < 1e-6)
        #expect(abs(centroid[1] - 0.8) < 1e-6)
        #expect(throws: InferenceError.self) { try VoiceEmbeddingMath.normalized([Float](repeating: 0, count: 256)) }
        #expect(throws: InferenceError.self) { try VoiceEmbeddingMath.normalized([1, 2]) }
        #expect(throws: InferenceError.self) { try VoiceEmbeddingMath.normalized([Float](repeating: .nan, count: 256)) }
    }

    @Test func modelIdentityCannotBeSilentlyMixedAndPrintsRoundTrip() throws {
        let print = SpeakerVoicePrint(modelIdentifier: "model-A", embedding: vector(0), speechDuration: 6, sampleCount: 2)
        let other = SpeakerVoicePrint(modelIdentifier: "model-B", embedding: vector(0), speechDuration: 6, sampleCount: 2)
        #expect(try print.cosineSimilarity(to: print) == 1)
        #expect(throws: InferenceError.self) { try print.cosineSimilarity(to: other) }
        #expect(try JSONDecoder().decode(SpeakerVoicePrint.self, from: JSONEncoder().encode(print)) == print)
        let rho = SpeakerVoicePrint(modelIdentifier: "model-rho-v2", embedding: Array(vector(0).prefix(128)), speechDuration: 6, sampleCount: 2)
        #expect(try rho.cosineSimilarity(to: rho) == 1)
        let malformed = SpeakerVoicePrint(modelIdentifier: "model-rho-v2", embedding: vector(0), speechDuration: 6, sampleCount: 2)
        #expect(throws: InferenceError.self) { try rho.cosineSimilarity(to: malformed) }
    }

    @Test func fingerprintIsPathIndependentAndIncludesActualWeights() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["one", "two"] {
            for model in ["FBank.mlmodelc", "Embedding.mlmodelc"] {
                let weights = root.appendingPathComponent(folder).appendingPathComponent(model).appendingPathComponent("weights")
                try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
                try Data([1, 2, 3]).write(to: weights.appendingPathComponent("weight.bin"))
            }
        }
        let first = try VoiceEmbeddingExtractor.modelFingerprint(directory: root.appendingPathComponent("one"))
        let second = try VoiceEmbeddingExtractor.modelFingerprint(directory: root.appendingPathComponent("two"))
        #expect(first == second)
        let centered = try VoiceEmbeddingExtractor.modelFingerprint(directory: root.appendingPathComponent("one"), recipe: .activeFrameCenteredV2)
        #expect(centered != first)
        try Data([1, 2, 4]).write(to: root.appendingPathComponent("two/Embedding.mlmodelc/weights/weight.bin"))
        #expect(try VoiceEmbeddingExtractor.modelFingerprint(directory: root.appendingPathComponent("two")) != first)
    }

    @Test func missingModelFailureDeletesOnlyOwnedAnalysisAndPreservesOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("original.wav")
        try writeSyntheticAudio(to: audio)
        let bytes = try Data(contentsOf: audio)
        let sentinel = root.appendingPathComponent("keep.txt")
        try Data("preserve".utf8).write(to: sentinel)
        let extractor = VoiceEmbeddingExtractor(modelDirectory: root.appendingPathComponent("absent"))
        await #expect(throws: (any Error).self) {
            try await extractor.extract(source: audio, ranges: [.init(start: 0, end: 2)], workingDirectory: root)
        }
        #expect(try Data(contentsOf: audio) == bytes)
        #expect(try Data(contentsOf: sentinel) == Data("preserve".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["keep.txt", "original.wav"])
    }

    private func writeSyntheticAudio(to url: URL) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
        buffer.frameLength = 32_000
        for index in 0..<32_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.07) * 0.1) }
        let writer = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer.write(from: buffer)
    }
}

struct VoiceEmbeddingNativeTests {
    struct SampleSet: Codable {
        let id: String
        let enrollment: [VoiceSampleRange]
        let heldOut: [VoiceSampleRange]
    }
    struct Manifest: Codable { let samples: [SampleSet] }
    struct Row: Codable {
        let id: String
        let enrollment: SpeakerVoicePrint
        let heldOut: SpeakerVoicePrint
        let enrolledWithProductionMinimum: Bool
        let similarities: [String: Double]
    }
    struct Output: Codable { let rows: [Row]; let elapsedSeconds: Double }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GROVE_RUN_VOICEPRINT_NATIVE_TEST"] == "1"))
    func nativeCoreMLHeldOutEvaluation() async throws {
        let environment = ProcessInfo.processInfo.environment
        let audio = URL(fileURLWithPath: try #require(environment["GROVE_VOICEPRINT_AUDIO"]))
        let models = URL(fileURLWithPath: try #require(environment["GROVE_VOICEPRINT_MODEL_DIRECTORY"]))
        let manifestURL = URL(fileURLWithPath: try #require(environment["GROVE_VOICEPRINT_EVAL_MANIFEST"]))
        let output = URL(fileURLWithPath: try #require(environment["GROVE_VOICEPRINT_OUTPUT"]))
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("evaluation.json").path))
        guard !FileManager.default.fileExists(atPath: output.appendingPathComponent("evaluation.json").path) else {
            throw InferenceError.invalidOutput("이전 평가를 보존하려면 새 출력 폴더를 지정해 주세요.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        #expect(!manifest.samples.isEmpty)
        let original = try Data(contentsOf: audio)
        let extractor = VoiceEmbeddingExtractor(modelDirectory: models,
                                                usePLDATransform: environment["GROVE_VOICEPRINT_USE_PLDA"] == "1")
        let start = Date()
        var enrolled: [String: SpeakerVoicePrint] = [:]
        var heldOut: [String: SpeakerVoicePrint] = [:]
        for sample in manifest.samples {
            enrolled[sample.id] = try await extractor.extract(source: audio, ranges: sample.enrollment, workingDirectory: output)
            heldOut[sample.id] = try await extractor.extract(source: audio, ranges: sample.heldOut, workingDirectory: output)
        }
        let rows = try manifest.samples.map { sample in
            let profile = try #require(enrolled[sample.id])
            let query = try #require(heldOut[sample.id])
            return Row(id: sample.id, enrollment: profile, heldOut: query,
                       enrolledWithProductionMinimum: profile.sampleCount >= 2 && profile.speechDuration >= 6,
                       similarities: try enrolled.mapValues { try query.cosineSimilarity(to: $0) })
        }
        let result = Output(rows: rows, elapsedSeconds: Date().timeIntervalSince(start))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: output.appendingPathComponent("evaluation.json"), options: .atomic)
        #expect(try Data(contentsOf: audio) == original)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: output.path)
        #expect(!remaining.contains { $0.hasPrefix("voiceprint-") })
        #expect(Set(rows.map { $0.enrollment.modelIdentifier }).count == 1)
    }
}
