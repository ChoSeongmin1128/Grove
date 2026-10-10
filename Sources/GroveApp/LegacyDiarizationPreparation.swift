import CryptoKit
import Foundation
import GroveInference

// The speech CLI downloads Community-1 itself from the repository's main branch. Grove only
// runs it against the revision it was verified with.
enum Community1Model {
    static let repository = "aufklarer/Pyannote-Community-1-CoreML"
    static let revision = "a14e6c420d56e8472850649b016a486fd0acbe81"

    struct File: Sendable {
        let path: String
        let bytes: Int
        let sha256: String
    }

    static let files: [File] = [
        .init(path: "config.json", bytes: 4154, sha256: "6bf96d3f361ad1b5bcfbcf2bdf70a2072d211fefd875700231e1f3b2fb69e713"),
        .init(path: "plda.safetensors", bytes: 199624, sha256: "aff6294b68b66adcbc1c2a402b1379ecfdd98d8d759dc2cca62b5380babea359"),
        .init(path: "embedding.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "f4b5ad2e2ea815e334acaf162fa42e999ecd9881ecac4166ff43d6bc1d9322d6"),
        .init(path: "embedding.mlmodelc/coremldata.bin", bytes: 345, sha256: "3ad7a2f309143107fc5394f34592ce80482bf6dbe6831e0588cff44cbaa609e5"),
        .init(path: "embedding.mlmodelc/model.mil", bytes: 76426, sha256: "66d248aad00b3e103151097a9bbba558402933c0cf31c010f66b086ac94d7aaf"),
        .init(path: "embedding.mlmodelc/weights/weight.bin", bytes: 27430272, sha256: "1019c1bb4472abfe705da19db3b5d0764adcb2d59dabf766fef74f0963f810f2"),
        .init(path: "segmentation.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "44d83274cec5ccfe4a959eca359a89e4fd757b1872962449f2206784fb2031e5"),
        .init(path: "segmentation.mlmodelc/coremldata.bin", bytes: 328, sha256: "5385e1af87712e3027ac96915d3b85de9450681e73ef355dfadd4b274cc9ba58"),
        .init(path: "segmentation.mlmodelc/model.mil", bytes: 27100, sha256: "8c0956cbbce7bac956cb85176fde28353a0d4a1e623f5621b6277b3d256ad0e8"),
        .init(path: "segmentation.mlmodelc/weights/weight.bin", bytes: 5960448, sha256: "d2c1c75adec19e64ea732808839b6b8da2968a8a26b8aa3e170ef283df44a6ca"),
    ]
}

enum LegacyDiarizationPreparation {
    /// Sizes are checked on every call; `verifyContents` also hashes the files, which is
    /// done once before a job starts rather than while the UI renders.
    static func validate(engine: DiarizationEngine, caches: URL? = nil,
                         environment: [String: String] = ProcessInfo.processInfo.environment,
                         files manifest: [Community1Model.File] = Community1Model.files,
                         verifyContents: Bool = false) throws {
        guard engine == .community1 else { return }
        let directory = community1Directory(caches: caches, environment: environment)
        for file in manifest {
            let url = directory.appendingPathComponent(file.path)
            guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == file.bytes else {
                throw InferenceError.invalidOutput("Community-1 모델이 준비되지 않았습니다. 준비된 화자 분리 엔진을 선택해 주세요.")
            }
            if verifyContents, try sha256(url) != file.sha256 {
                throw InferenceError.invalidOutput("Community-1 모델이 검증한 버전과 다릅니다. 모델을 다시 준비하거나 Nemotron 3를 선택해 주세요.")
            }
        }
    }

    private static func community1Directory(caches: URL?, environment: [String: String]) -> URL {
        let files = FileManager.default
        let override = [environment["QWEN3_CACHE_DIR"], environment["QWEN3_ASR_CACHE_DIR"]]
            .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let root = override.map { URL(fileURLWithPath: $0) }
            ?? caches ?? files.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let base = root.appendingPathComponent("qwen3-speech")
        let legacy = base.appendingPathComponent("aufklarer_Pyannote-Community-1-CoreML")
        let legacyEntries = (try? files.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
        let hasLegacyWeights = legacyEntries.contains { ["safetensors", "mlmodelc", "mlpackage"].contains($0.pathExtension) }
        return hasLegacyWeights ? legacy : base.appendingPathComponent("models/aufklarer/Pyannote-Community-1-CoreML")
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
