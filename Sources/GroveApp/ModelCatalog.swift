import Foundation
import GroveInference

enum ModelGroup: String, CaseIterable, Identifiable, Sendable {
    case moss, nemotron3, ultra8, voiceIdentity
    var id: String { rawValue }
    var label: String { switch self { case .voiceIdentity: "목소리 등록"; case .moss: "한국어 전사 (MOSS)"; case .nemotron3: "화자 분리 (Nemotron 3)"; case .ultra8: "화자 분리 (Ultra8, 선택 사항)" } }
}

struct ModelAsset: Sendable {
    let group: ModelGroup
    let repository: String
    let revision: String
    let name: String
    let bytes: Int64
    let sha256: String
    var remoteURL: URL { URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(name)")! }
    func destination(in base: URL) -> URL {
        switch group {
        case .voiceIdentity: base.appendingPathComponent("Models/VoiceIdentity/\(name)")
        case .moss: base.appendingPathComponent("Models/hub/models--OpenMOSS-Team--MOSS-Transcribe-Diarize/snapshots/\(revision)/\(name)")
        case .nemotron3: NemotronModel.url(in: base)
        case .ultra8: Ultra8Model.url(in: base)
        }
    }
}

enum ModelCatalog {
    static let assets: [ModelAsset] = [
        .init(group: .voiceIdentity, repository: "FluidInference/speaker-diarization-coreml", revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232", name: "Embedding.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682"),
        .init(group: .voiceIdentity, repository: "FluidInference/speaker-diarization-coreml", revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232", name: "Embedding.mlmodelc/coremldata.bin", bytes: 704, sha256: "4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004"),
        .init(group: .voiceIdentity, repository: "FluidInference/speaker-diarization-coreml", revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232", name: "Embedding.mlmodelc/metadata.json", bytes: 2818, sha256: "1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5"),
        .init(group: .voiceIdentity, repository: "FluidInference/speaker-diarization-coreml", revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232", name: "Embedding.mlmodelc/model.mil", bytes: 78432, sha256: "22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3"),
        .init(group: .voiceIdentity, repository: "FluidInference/speaker-diarization-coreml", revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232", name: "Embedding.mlmodelc/weights/weight.bin", bytes: 13412288, sha256: "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b"),
        .init(group: .voiceIdentity, repository: "FluidInference/speaker-diarization-coreml", revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232", name: "FBank.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a"),
        .init(group: .voiceIdentity, repository: "FluidInference/speaker-diarization-coreml", revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232", name: "FBank.mlmodelc/coremldata.bin", bytes: 853, sha256: "57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759"),
        .init(group: .voiceIdentity, repository: "FluidInference/speaker-diarization-coreml", revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232", name: "FBank.mlmodelc/metadata.json", bytes: 3409, sha256: "2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a"),
        .init(group: .voiceIdentity, repository: "FluidInference/speaker-diarization-coreml", revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232", name: "FBank.mlmodelc/model.mil", bytes: 15667, sha256: "27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed"),
        .init(group: .voiceIdentity, repository: "FluidInference/speaker-diarization-coreml", revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232", name: "FBank.mlmodelc/weights/weight.bin", bytes: 1776896, sha256: "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36"),
        .init(group: .moss, repository: "OpenMOSS-Team/MOSS-Transcribe-Diarize", revision: "704aa4a9c304e8520be88901e0d1960158ef5b15", name: "added_tokens.json", bytes: 707, sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"),
        .init(group: .moss, repository: "OpenMOSS-Team/MOSS-Transcribe-Diarize", revision: "704aa4a9c304e8520be88901e0d1960158ef5b15", name: "config.json", bytes: 2335, sha256: "2b2b7a6e61334152bdd7ecf8a4da3073b4940a097e193d1d2b22093e77535234"),
        .init(group: .moss, repository: "OpenMOSS-Team/MOSS-Transcribe-Diarize", revision: "704aa4a9c304e8520be88901e0d1960158ef5b15", name: "generation_config.json", bytes: 107, sha256: "e53a4b3ce4f944230cf1ca8fed0c42f4ff0d8c1443eaf98b5315d987334dd9e4"),
        .init(group: .moss, repository: "OpenMOSS-Team/MOSS-Transcribe-Diarize", revision: "704aa4a9c304e8520be88901e0d1960158ef5b15", name: "merges.txt", bytes: 1671853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        .init(group: .moss, repository: "OpenMOSS-Team/MOSS-Transcribe-Diarize", revision: "704aa4a9c304e8520be88901e0d1960158ef5b15", name: "model-00000-of-00001.safetensors", bytes: 1817113576, sha256: "9a0ceb4ab7330357db3ff583dba8d83625d5b733b00e1d55d6970e11b07026c4"),
        .init(group: .moss, repository: "OpenMOSS-Team/MOSS-Transcribe-Diarize", revision: "704aa4a9c304e8520be88901e0d1960158ef5b15", name: "model.safetensors.index.json", bytes: 65401, sha256: "0345ac5d8f360abe4e9adadb5fecd38e7730052b75f64bb58182818b1544cc36"),
        .init(group: .moss, repository: "OpenMOSS-Team/MOSS-Transcribe-Diarize", revision: "704aa4a9c304e8520be88901e0d1960158ef5b15", name: "preprocessor_config.json", bytes: 315, sha256: "ba2e601484abc80f4cded977f9a4fd4a53175b7d35c2f2511f0cfc3a32ad2499"),
        .init(group: .moss, repository: "OpenMOSS-Team/MOSS-Transcribe-Diarize", revision: "704aa4a9c304e8520be88901e0d1960158ef5b15", name: "processor_config.json", bytes: 292, sha256: "a978c2dd54a65b576c3dae4b654fe9bcbac1184c6db2df0afb2c90fcdc872ae7"),
        .init(group: .moss, repository: "OpenMOSS-Team/MOSS-Transcribe-Diarize", revision: "704aa4a9c304e8520be88901e0d1960158ef5b15", name: "special_tokens_map.json", bytes: 613, sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
        .init(group: .moss, repository: "OpenMOSS-Team/MOSS-Transcribe-Diarize", revision: "704aa4a9c304e8520be88901e0d1960158ef5b15", name: "tokenizer.json", bytes: 11423222, sha256: "bcf03774334462d6e34b5005cb11120a62275f146ee2953e68731ecdbce84fbb"),
        .init(group: .moss, repository: "OpenMOSS-Team/MOSS-Transcribe-Diarize", revision: "704aa4a9c304e8520be88901e0d1960158ef5b15", name: "tokenizer_config.json", bytes: 503, sha256: "61d04c96104177240688396655ae3f7cf38ce2ea036db867a1d2b6883e27c3d5"),
        .init(group: .moss, repository: "OpenMOSS-Team/MOSS-Transcribe-Diarize", revision: "704aa4a9c304e8520be88901e0d1960158ef5b15", name: "vocab.json", bytes: 2776833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
        .init(group: .nemotron3, repository: "nvidia/Nemotron-3-Diarization", revision: "f667ed73aee57d40cc39428eb768b4fd87a0a29e", name: "Nemotron-3-Diarization.q8_0.gguf", bytes: 107012128, sha256: "08456d9e22cd9a323c0364d98375f3746d6e68507ebb705cd46438c534c7a3a1"),
        .init(group: .ultra8, repository: "investguy/ultra_diar_streaming_sortformer_8spk_v1_onnx", revision: Ultra8Model.revision, name: Ultra8Model.fileName, bytes: 492246180, sha256: Ultra8Model.sha256),
    ]
}
