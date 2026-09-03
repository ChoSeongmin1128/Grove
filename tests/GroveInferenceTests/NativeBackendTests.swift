import Foundation
import Testing
@testable import GroveInference

struct NativeBackendTests {
    @Test func retainedSortformerPathCannotTurnIntoOfflineAccidentally() throws {
        let args = try NativeInferenceBackend.diarizationArguments(audio: URL(fileURLWithPath: "/tmp/input.wav"),
            output: URL(fileURLWithPath: "/tmp/output.json"),
            configuration: .init(expectedSpeakerCount: 4, diarizationPreference: .sortformerStreaming))
        #expect(args.first == "sortformer")
        #expect(!args.contains("--offline"))
        #expect(args.contains("all"))
    }

    @Test func knownCountIsAdvisoryUnlessExplicitlyConstrained() throws {
        let audio = URL(fileURLWithPath: "/tmp/input.wav")
        let output = URL(fileURLWithPath: "/tmp/output.json")
        let advisory = try NativeInferenceBackend.diarizationArguments(audio: audio, output: output,
            configuration: .init(expectedSpeakerCount: 5), ultra8Model: URL(fileURLWithPath: "/tmp/model.onnx"))
        let exact = try NativeInferenceBackend.diarizationArguments(audio: audio, output: output,
            configuration: .init(expectedSpeakerCount: 5, speakerCountPolicy: .exact))
        #expect(!advisory.contains("--num-speakers"))
        #expect(exact.suffix(2) == ["--num-speakers", "5"])
    }

    @Test func unsupportedExactCountDoesNotSilentlyFallBackToAdvisory() throws {
        #expect(try InferenceConfiguration(expectedSpeakerCount: 3, speakerCountPolicy: .exact).resolvedEngine() == .community1)
        #expect(throws: InferenceError.self) {
            try InferenceConfiguration(expectedSpeakerCount: 3, diarizationPreference: .sortformerStreaming,
                                       speakerCountPolicy: .exact).resolvedEngine()
        }
        #expect(throws: InferenceError.self) { try InferenceConfiguration(speakerCountPolicy: .exact).resolvedEngine() }
    }

    @Test func runnerCapturesOutputAndDoesNotOverwriteLogs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("result.log")
        let runner = NativeProcessRunner()
        try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["test output"], directory: root, log: log)
        #expect(try String(contentsOf: log, encoding: .utf8) == "test output")
        await #expect(throws: (any Error).self) {
            try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["replacement"], directory: root, log: log)
        }
        #expect(try String(contentsOf: log, encoding: .utf8) == "test output")
    }

    @Test func cancelledWorkerTerminatesWithoutPublishingSuccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            try await NativeProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                                                directory: root, log: root.appendingPathComponent("cancelled.log"))
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
