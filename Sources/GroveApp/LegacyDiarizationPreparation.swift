import Foundation
import GroveInference

enum LegacyDiarizationPreparation {
    static func validate(engine: DiarizationEngine, support: URL? = nil, caches: URL? = nil,
                         environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let files = FileManager.default
        switch engine {
        case .sortformerStreaming:
            let support = support ?? files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let model = support.appendingPathComponent("FluidAudio/Models/sortformer/v3/fp16/Sortformer_v2.1.mlmodelc")
            guard compiledModelIsPresent(model) else {
                throw InferenceError.invalidOutput("Sortformer 모델이 준비되지 않았습니다. 준비된 화자 분리 엔진을 선택해 주세요.")
            }
        case .community1:
            let override = [environment["QWEN3_CACHE_DIR"], environment["QWEN3_ASR_CACHE_DIR"]]
                .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let root = override.map { URL(fileURLWithPath: $0) }
                ?? caches ?? files.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let base = root.appendingPathComponent("qwen3-speech")
            let legacy = base.appendingPathComponent("aufklarer_Pyannote-Community-1-CoreML")
            let modern = base.appendingPathComponent("models/aufklarer/Pyannote-Community-1-CoreML")
            let legacyEntries = (try? files.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
            let hasLegacyWeights = legacyEntries.contains { ["safetensors", "mlmodelc", "mlpackage"].contains($0.pathExtension) }
            let directory = hasLegacyWeights ? legacy : modern
            guard compiledModelIsPresent(directory.appendingPathComponent("segmentation.mlmodelc")),
                  compiledModelIsPresent(directory.appendingPathComponent("embedding.mlmodelc")),
                  readableNonempty(directory.appendingPathComponent("config.json")),
                  readableNonempty(directory.appendingPathComponent("plda.safetensors")) else {
                throw InferenceError.invalidOutput("Community-1 모델이 준비되지 않았습니다. 준비된 화자 분리 엔진을 선택해 주세요.")
            }
        default: break
        }
    }

    private static func compiledModelIsPresent(_ url: URL) -> Bool {
        guard readableNonempty(url.appendingPathComponent("coremldata.bin")) else { return false }
        if readableNonempty(url.appendingPathComponent("model.mil")) {
            return weightsArePresent(url.appendingPathComponent("weights"))
        }
        return ["model0", "model1"].allSatisfy { stage in
            let child = url.appendingPathComponent(stage)
            return readableNonempty(child.appendingPathComponent("coremldata.bin"))
                && readableNonempty(child.appendingPathComponent("model.mil")) && weightsArePresent(child.appendingPathComponent("weights"))
        }
    }

    private static func weightsArePresent(_ directory: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
              !files.isEmpty else { return false }
        return files.allSatisfy(readableNonempty)
    }

    private static func readableNonempty(_ url: URL) -> Bool {
        FileManager.default.isReadableFile(atPath: url.path)
            && ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }
}
