import Foundation

// 可选的模型。两台手机必须选同一个文件（握手时会核对指纹）。
struct ModelSpec: Identifiable, Hashable {
    let id: String
    let name: String
    let file: String
    let url: URL
    let note: String

    static let q9b = ModelSpec(
        id: "9b", name: "Qwen3.5-9B · Q4_K_M", file: "Qwen3.5-9B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf")!,
        note: "5.7 GB，每层 113–136 MB。两台合跑的主要目标")
    static let q4b = ModelSpec(
        id: "4b", name: "Qwen3.5-4B · Q4_K_M", file: "Qwen3.5-4B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf")!,
        note: "2.7 GB，每层 64–70 MB。先用它试通链路")
    static let all = [q9b, q4b]
    static func by(_ id: String) -> ModelSpec { all.first { $0.id == id } ?? q9b }
}

enum Paths {
    static var models: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// 模型文件在哪：优先用「文件」App 拷进来的完整文件，没有就用 App 自己下载的
    static func file(for m: ModelSpec) -> URL {
        let doc = documents.appendingPathComponent(m.file)
        if FileManager.default.fileExists(atPath: doc.path) { return doc }
        return models.appendingPathComponent(m.file)
    }
    static func parts(for m: ModelSpec) -> URL { models.appendingPathComponent(m.file + ".parts.json") }
}

struct XJError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

extension Double {
    var mb: String { self >= 1024 ? String(format: "%.1f GB", self / 1024) : String(format: "%.0f MB", self) }
}

/// 模型结构（每层多大），从本地文件头读出来
struct ModelLayout {
    var nLayer: Int
    var layerMB: [Double]
    var ioMB: Double

    func mb(_ l0: Int, _ l1: Int) -> Double {
        guard l0 < l1, l1 <= layerMB.count else { return 0 }
        return layerMB[l0..<l1].reduce(0, +)
    }

    init(_ info: xjg_model_info) {
        nLayer = Int(info.n_layer)
        var arr: [Double] = []
        withUnsafeBytes(of: info.layer_mb) { raw in
            let p = raw.bindMemory(to: Double.self)
            for i in 0..<min(nLayer, 128) { arr.append(p[i]) }
        }
        layerMB = arr
        ioMB = info.io_mb
    }

    static func read(_ url: URL) -> ModelLayout? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var info = xjg_model_info()
        var err = [CChar](repeating: 0, count: 256)
        guard xjg_model_info_of(url.path, &info, &err, Int32(err.count)) == 0 else { return nil }
        return ModelLayout(info)
    }
}

func cString(_ buf: [CChar]) -> String {
    buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}
