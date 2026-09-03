import Foundation

public enum Ultra8Model {
    public static let revision = "2a45f114eaf920b4d50b04a5964cc1aab35ddf5f"
    public static let sha256 = "c64a1fb633ad52b77103ce0c0a0dd2b5f55a71f029083ed819901e36c7420c0a"
    public static let fileName = "ultra_diar_streaming_sortformer_8spk_v1.onnx"
    public static let postprocessing = "nemo-default-0.5"

    public static func url(in applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("Models/Ultra8/\(revision)/\(fileName)")
    }
}
