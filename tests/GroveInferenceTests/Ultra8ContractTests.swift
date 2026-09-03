import Foundation
import Testing
@testable import GroveInference

struct Ultra8ContractTests {
    @Test func ultraIsTheAutomaticDefaultButCannotForceCountOrExceedCapacity() throws {
        #expect(try InferenceConfiguration(diarizationPreference: .ultra8).resolvedEngine() == .ultra8)
        for count in [1, 4, 8] {
            #expect(try InferenceConfiguration(expectedSpeakerCount: count, diarizationPreference: .ultra8).resolvedEngine() == .ultra8)
        }
        #expect(throws: InferenceError.self) { try InferenceConfiguration(expectedSpeakerCount: 9, diarizationPreference: .ultra8).resolvedEngine() }
        #expect(throws: InferenceError.self) {
            try InferenceConfiguration(expectedSpeakerCount: 4, diarizationPreference: .ultra8, speakerCountPolicy: .exact).resolvedEngine()
        }
        #expect(try InferenceConfiguration().resolvedEngine() == .ultra8)
        #expect(try InferenceConfiguration(expectedSpeakerCount: 4).resolvedEngine() == .ultra8)
    }

    @Test func noCountFlagCanReachUltraHelper() throws {
        let input = URL(fileURLWithPath: "/tmp/input.wav")
        let model = URL(fileURLWithPath: "/tmp/model.onnx")
        let output = URL(fileURLWithPath: "/tmp/output.json")
        for count in [nil, 4, 8] as [Int?] {
            let args = try NativeInferenceBackend.diarizationArguments(audio: input, output: output,
                configuration: .init(expectedSpeakerCount: count, diarizationPreference: .ultra8), ultra8Model: model)
            #expect(args == [input.path, model.path, output.path])
        }
    }

    private func envelope() -> [String: Any] {
        ["schemaVersion": 1, "engine": "ultra8", "maxSpeakers": 8, "speakerCountConstraint": NSNull(),
         "modelRevision": Ultra8Model.revision, "modelSHA256": Ultra8Model.sha256,
         "postprocessing": Ultra8Model.postprocessing, "durationSeconds": 10.0,
         "segments": [["start": 1.0, "end": 2.0, "speaker": "7"]]]
    }

    @Test func decoderRequiresPinnedModelPostprocessingCapacityAndCompleteDuration() throws {
        let good = envelope()
        let turns = try ExternalOutputDecoder.diarization(JSONSerialization.data(withJSONObject: good), engine: .ultra8, duration: 10)
        #expect(turns.first?.clusterID == "7")
        let invalid: [(String, Any)] = [("schemaVersion", 2), ("engine", "sortformer"), ("maxSpeakers", 4),
            ("speakerCountConstraint", 4), ("modelRevision", "other"), ("modelSHA256", "other"),
            ("postprocessing", "callhome"), ("durationSeconds", 3.0),
            ("segments", [["start": 1.0, "end": 2.0, "speaker": "8"]])]
        for (key, value) in invalid {
            var data = good
            data[key] = value
            #expect(throws: (any Error).self) { try ExternalOutputDecoder.diarization(JSONSerialization.data(withJSONObject: data), engine: .ultra8, duration: 10) }
        }
        var missing = good
        missing.removeValue(forKey: "speakerCountConstraint")
        #expect(throws: (any Error).self) { try ExternalOutputDecoder.diarization(JSONSerialization.data(withJSONObject: missing), engine: .ultra8, duration: 10) }
        for label in ["00", "-0", "01"] {
            var data = good
            data["segments"] = [["start": 1.0, "end": 2.0, "speaker": label]]
            #expect(throws: (any Error).self) { try ExternalOutputDecoder.diarization(JSONSerialization.data(withJSONObject: data), engine: .ultra8, duration: 10) }
        }
    }

    @Test func eightSpeakersRoundTripAndNineCannotBeClamped() throws {
        let turns: [DiarizationTurn] = (0..<8).map { index in .init(start: Double(index), end: Double(index) + 0.8, clusterID: String(index)) }
        let result = try InferenceResult(duration: 10, configuration: .init(diarizationPreference: .ultra8),
            transcription: .init(utterances: [.init(start: 7, end: 7.8, text: "마지막 화자")]), rawDiarization: turns)
        let reopened = try JSONDecoder().decode(InferenceResult.self, from: JSONEncoder().encode(result))
        try reopened.validate()
        #expect(reopened.assignments.first?.clusterID == "7")
        #expect(throws: InferenceError.self) {
            try SpeakerProjection.validate(turns + [.init(start: 8, end: 8.8, clusterID: "8")], duration: 10, engine: .ultra8)
        }
    }
}
