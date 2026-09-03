import Foundation

public struct NativeInferenceBackend: Sendable {
    public let mossExecutable: URL
    public let mossModelDirectory: URL
    public let sortformerExecutable: URL
    public let communityExecutable: URL
    public let ultra8Executable: URL?
    public let ultra8Model: URL?
    private let runner = NativeProcessRunner()

    public init(mossExecutable: URL, mossModelDirectory: URL, sortformerExecutable: URL, communityExecutable: URL,
                ultra8Executable: URL? = nil, ultra8Model: URL? = nil) {
        self.mossExecutable = mossExecutable
        self.mossModelDirectory = mossModelDirectory
        self.sortformerExecutable = sortformerExecutable
        self.communityExecutable = communityExecutable
        self.ultra8Executable = ultra8Executable
        self.ultra8Model = ultra8Model
    }

    public func transcribe(audio: URL, duration: Double, directory: URL) async throws -> RawTranscription {
        let output = directory.appendingPathComponent("moss.json")
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw InferenceError.invalidOutput("새 작업 폴더가 필요합니다. 기존 전사는 보존됩니다.")
        }
        guard mossModelDirectory.isFileURL else {
            throw InferenceError.invalidOutput("로컬 전사 모델 폴더가 필요합니다.")
        }
        try await runner.run(executable: mossExecutable, arguments: [audio.path, output.path, mossModelDirectory.path], directory: directory,
                             log: directory.appendingPathComponent("moss.log"))
        return try ExternalOutputDecoder.moss(Data(contentsOf: output), duration: duration)
    }

    public func diarize(audio: URL, duration: Double, configuration: InferenceConfiguration, directory: URL) async throws -> [DiarizationTurn] {
        let engine = try configuration.resolvedEngine()
        let output = directory.appendingPathComponent("diarization.json")
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw InferenceError.invalidOutput("새 작업 폴더가 필요합니다. 기존 화자 결과는 보존됩니다.")
        }
        let log = directory.appendingPathComponent("diarization.log")
        let arguments = try Self.diarizationArguments(audio: audio, output: output, configuration: configuration, ultra8Model: ultra8Model)
        let executable: URL
        switch engine {
        case .sortformerStreaming: executable = sortformerExecutable
        case .community1: executable = communityExecutable
        case .ultra8:
            guard let ultra8Executable else { throw InferenceError.missingExecutable("Ultra8") }
            executable = ultra8Executable
        }
        try await runner.run(executable: executable, arguments: arguments, directory: directory, log: log)
        let data: Data
        if engine != .community1 {
            data = try Data(contentsOf: output)
        } else {
            data = try ExternalOutputDecoder.segmentsObject(from: Data(contentsOf: log))
            try data.write(to: output, options: .withoutOverwriting)
        }
        return try ExternalOutputDecoder.diarization(data, engine: engine, duration: duration)
    }

    public static func diarizationArguments(audio: URL, output: URL, configuration: InferenceConfiguration,
                                           ultra8Model: URL? = nil) throws -> [String] {
        switch try configuration.resolvedEngine() {
        case .sortformerStreaming:
            // The measured streaming condition uses --compute-units all. Never add
            // --offline here: that invokes a different model and timeline algorithm.
            return ["sortformer", audio.path, "--compute-units", "all", "--output", output.path]
        case .community1:
            var arguments = ["diarize", audio.path, "--engine", "community1", "--community1-compute-units", "ane", "--json"]
            if configuration.speakerCountPolicy == .exact, let count = configuration.expectedSpeakerCount {
                arguments += ["--num-speakers", String(count)]
            }
            return arguments
        case .ultra8:
            guard let ultra8Model, ultra8Model.isFileURL else { throw InferenceError.invalidOutput("Ultra8 로컬 모델이 준비되지 않았습니다.") }
            return [audio.path, ultra8Model.path, output.path]
        }
    }
}

public actor NativeInferencePipeline {
    private let backend: NativeInferenceBackend
    private var isRunning = false

    public init(backend: NativeInferenceBackend) { self.backend = backend }

    public func run(audio: URL, duration: Double, configuration: InferenceConfiguration, directory: URL,
                    progress: @Sendable (String) async -> Void = { _ in }) async throws -> InferenceResult {
        guard !isRunning else { throw InferenceError.jobAlreadyRunning }
        _ = try configuration.resolvedEngine()
        guard duration.isFinite, duration > 0, audio.isFileURL, FileManager.default.fileExists(atPath: audio.path) else {
            throw InferenceError.invalidOutput("읽을 수 있는 녹음 파일이 필요합니다.")
        }
        isRunning = true
        defer { isRunning = false }
        return try await execute(audio: audio, duration: duration, configuration: configuration, directory: directory, progress: progress)
    }

    public func runRecording(source: URL, configuration: InferenceConfiguration, directory: URL,
                             progress: @Sendable (String) async -> Void = { _ in }) async throws -> InferenceResult {
        guard !isRunning else { throw InferenceError.jobAlreadyRunning }
        _ = try configuration.resolvedEngine()
        isRunning = true
        defer { isRunning = false }
        try Task.checkCancellation()
        await progress("녹음 파일을 준비하고 있습니다")
        let prepared = try await AnalysisAudioPreparer.prepare(source: source, destination: directory.appendingPathComponent("analysis.wav"))
        // Only the generated working copy is disposable. The input recording and all
        // raw model outputs remain untouched, including when a model fails or cancels.
        defer { try? FileManager.default.removeItem(at: prepared.url) }
        return try await execute(audio: prepared.url, duration: prepared.duration, configuration: configuration,
                                 directory: directory, progress: progress)
    }

    private func execute(audio: URL, duration: Double, configuration: InferenceConfiguration, directory: URL,
                         progress: @Sendable (String) async -> Void) async throws -> InferenceResult {
        try Task.checkCancellation()
        await progress("대화를 전사하고 있습니다")
        let text = try await backend.transcribe(audio: audio, duration: duration, directory: directory)
        try Task.checkCancellation()
        // Each stage is its own headless process, so MOSS's model allocations are
        // released before the diarizer starts. Do not run the two models concurrently.
        await progress("발화자를 구분하고 있습니다")
        let turns = try await backend.diarize(audio: audio, duration: duration, configuration: configuration, directory: directory)
        try Task.checkCancellation()
        return try InferenceResult(duration: duration, configuration: configuration, transcription: text, rawDiarization: turns)
    }
}
