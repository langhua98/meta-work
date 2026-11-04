import Foundation
import UIKit
import llama

// 手机上的小模型（llama.cpp + GGUF）。
// 不常驻：要用时才加载，空闲 2 分钟、App 进后台、内存告警时释放。
// 每次只把一句话翻成一条 JSON 指令：用 GBNF 语法锁死输出格式，模型写不出格式以外的东西。

struct ModelInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let short: String
    let note: String
    let file: String
    let url: URL
    let bytes: Int64

    static let qwen = ModelInfo(
        id: "2b", name: "Qwen3.5-2B · Q4_K_M", short: "Qwen3.5-2B", note: "快，省内存（运行约 1.6 GB）",
        file: "Qwen3.5-2B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf")!,
        bytes: 1_280_835_840)

    static let qwen4b = ModelInfo(
        id: "4b", name: "Qwen3.5-4B · Q4_K_M", short: "Qwen3.5-4B", note: "更聪明，慢一些，运行要 3 GB 左右（试试 15 Pro Max 跑不跑得动）",
        file: "Qwen3.5-4B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf")!,
        bytes: 2_740_937_888)

    /// 在 Kaggle 上用小橘推送的工具调用数据微调过的 4B（scripts/finetune/train_kaggle.ipynb 训好后传到 HF）
    static let xiaoju4b = ModelInfo(
        id: "4b-xiaoju", name: "Qwen3.5-4B 小橘版 · Q4_K_M", short: "Qwen3.5-4B 小橘版",
        note: "专门训练过调用小橘推送的工具（要先在 Kaggle 训好才能下载）",
        file: "Qwen3.5-4B-xiaoju-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/langhua1998/Qwen3.5-4B-xiaoju-GGUF/resolve/main/Qwen3.5-4B-xiaoju-Q4_K_M.gguf")!,
        bytes: 2_740_937_888)

    static let all = [qwen, qwen4b, xiaoju4b]
}

/// 下载、删除模型文件。
@MainActor
final class ModelStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelStore()

    /// 现在用哪个模型（设置里切换）
    @Published var selectedID: String {
        didSet {
            UserDefaults.standard.set(selectedID, forKey: "localModel")
            refresh()
            Task { await LocalModel.shared.unload() }
        }
    }
    var info: ModelInfo { ModelInfo.all.first { $0.id == selectedID } ?? .qwen }
    /// 正在下载的是哪个
    @Published private(set) var downloadingID: String?

    @Published private(set) var downloaded = false
    @Published private(set) var progress: Double?
    @Published private(set) var received: Int64 = 0
    @Published var error = ""

    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    override init() {
        selectedID = UserDefaults.standard.string(forKey: "localModel") ?? ModelInfo.qwen.id
        super.init()
        refresh()
    }

    func refresh() { downloaded = isDownloaded(info) }

    func isDownloaded(_ m: ModelInfo) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(m.file).path)
    }

    var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("models", isDirectory: true)
    }

    var fileURL: URL { folder.appendingPathComponent(info.file) }

    var downloading: Bool { progress != nil }

    func download() { download(info) }

    func download(_ m: ModelInfo) {
        guard task == nil else { return }
        downloadingID = m.id
        error = ""
        let c = URLSessionConfiguration.default
        c.allowsCellularAccess = false
        c.waitsForConnectivity = true
        c.timeoutIntervalForResource = 6 * 3600
        let s = URLSession(configuration: c, delegate: self, delegateQueue: .main)
        session = s
        progress = 0
        received = 0
        let t = s.downloadTask(with: m.url)
        task = t
        t.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        progress = nil
        downloadingID = nil
    }

    func delete() { delete(info) }

    func delete(_ m: ModelInfo) {
        Task { await LocalModel.shared.unload() }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(m.file))
        refresh()
        objectWillChange.send()
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite
                : (ModelInfo.all.first { $0.id == downloadingID } ?? info).bytes
            received = totalBytesWritten
            progress = Double(totalBytesWritten) / Double(total)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // 临时文件在这个回调返回后就会被删，必须马上搬走
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models", isDirectory: true)
        // 按下载地址认是哪个模型的文件
        let name = downloadTask.originalRequest?.url?.lastPathComponent ?? ModelInfo.qwen.file
        let dest = base.appendingPathComponent(ModelInfo.all.first { $0.file == name }?.file ?? name)
        var failure = ""
        do {
            if let code = (downloadTask.response as? HTTPURLResponse)?.statusCode, code != 200 {
                throw PushError("下载失败（\(code)）")
            }
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: location, to: dest)
            var u = dest
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            try? u.setResourceValues(v)
        } catch {
            failure = error.localizedDescription
        }
        MainActor.assumeIsolated {
            self.error = failure
            self.refresh()
            self.objectWillChange.send()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            if let error, (error as NSError).code != NSURLErrorCancelled {
                self.error = "下载中断：\(error.localizedDescription)"
            }
            self.task = nil
            self.progress = nil
            self.downloadingID = nil
            session.finishTasksAndInvalidate()
        }
    }
}

/// llama.cpp 的薄封装。所有 llama 调用都在一个串行队列上做。
actor LocalModel {
    static let shared = LocalModel()

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    /// 已经算进 KV 缓存的前缀（固定说明），下次同样的前缀就不用重算
    private var cachedPrefix: [llama_token] = []
    /// 前缀算完后的整个状态快照。Qwen3.5 有循环层，KV 缓存删不掉后半段，
    /// 以前每句话都要把两千多字的说明重算一遍（4B 要十几二十秒，看着像卡住）；现在算一次存起来，下次直接恢复。
    private var prefixState: [UInt8] = []
    private var idleTimer: Task<Void, Never>?
    private static var backendReady = false

    static let contextSize: UInt32 = 3072

    var isLoaded: Bool { model != nil }
    private var loadedPath = ""
    /// 内存浮标用：现在在内存里的模型文件名（没加载是 nil）
    var loadedFile: String? { model == nil ? nil : (loadedPath as NSString).lastPathComponent }

    init() {
        Task { @MainActor in
            NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                   object: nil, queue: .main) { _ in
                Task { await LocalModel.shared.unload() }
            }
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                   object: nil, queue: .main) { _ in
                Task { await LocalModel.shared.unload() }
            }
        }
    }

    func load(path: String) throws {
        if model != nil && loadedPath == path { return }
        if model != nil { unload() }
        if !Self.backendReady {
            llama_backend_init()
            Self.backendReady = true
        }
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 99
        guard let m = llama_model_load_from_file(path, mp) else {
            throw PushError("模型加载失败，可能是内存不够，先关掉别的 App 再试")
        }
        var cp = llama_context_default_params()
        cp.n_ctx = Self.contextSize
        cp.n_batch = Self.contextSize
        cp.n_ubatch = 512
        let threads = Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw PushError("模型加载失败（上下文）")
        }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        cachedPrefix = []
        loadedPath = path
    }

    func unload() {
        idleTimer?.cancel()
        idleTimer = nil
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil
        model = nil
        vocab = nil
        cachedPrefix = []
        prefixState = []
    }

    /// 用完后 2 分钟没人用就释放
    private func scheduleUnload() {
        idleTimer?.cancel()
        idleTimer = Task {
            try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            if !Task.isCancelled { self.unload() }
        }
    }

    private func tokenize(_ text: String, special: Bool) -> [llama_token] {
        guard let vocab else { return [] }
        let n = Int32(text.utf8.count) + 16
        var out = [llama_token](repeating: 0, count: Int(n))
        var got = llama_tokenize(vocab, text, Int32(text.utf8.count), &out, n, false, special)
        if got < 0 {
            out = [llama_token](repeating: 0, count: Int(-got))
            got = llama_tokenize(vocab, text, Int32(text.utf8.count), &out, -got, false, special)
        }
        return Array(out.prefix(Int(max(0, got))))
    }

    private func piece(_ t: llama_token) -> [UInt8] {
        guard let vocab else { return [] }
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, t, &buf, 64, 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, t, &buf, -n, 0, false)
        }
        return buf.prefix(Int(max(0, n))).map { UInt8(bitPattern: $0) }
    }

    private func savePrefix() {
        guard let ctx else { return }
        let n = llama_state_seq_get_size(ctx, 0)
        guard n > 0, n < 400 * 1_048_576 else { return }
        var buf = [UInt8](repeating: 0, count: n)
        let got = buf.withUnsafeMutableBufferPointer { llama_state_seq_get_data(ctx, $0.baseAddress, n, 0) }
        prefixState = got == n ? buf : []
    }

    private func restorePrefix(_ mem: llama_memory_t?) -> Bool {
        guard let ctx else { return false }
        llama_memory_clear(mem, true)
        let n = prefixState.count
        let got = prefixState.withUnsafeBufferPointer { llama_state_seq_set_data(ctx, $0.baseAddress, n, 0) }
        if got == 0 { prefixState = []; llama_memory_clear(mem, true); return false }
        return true
    }

    private func decode(_ tokens: [llama_token]) throws {
        guard let ctx, !tokens.isEmpty else { return }
        var toks = tokens
        let rc = toks.withUnsafeMutableBufferPointer { buf in
            llama_decode(ctx, llama_batch_get_one(buf.baseAddress, Int32(buf.count)))
        }
        if rc != 0 { throw PushError("模型计算出错（\(rc)）") }
    }

    /// prefix 是固定的说明（可缓存），suffix 是这一句。返回模型输出（受 grammar 约束）。
    func generate(prefix: String, suffix: String, grammar: String, maxTokens: Int = 160) throws -> String {
        guard let ctx, let vocab else { throw PushError("模型还没加载") }
        idleTimer?.cancel()
        defer { scheduleUnload() }

        let pre = tokenize(prefix, special: true)
        let suf = tokenize(suffix, special: true)
        guard pre.count + suf.count + maxTokens < Int(Self.contextSize) else { throw PushError("这句话太长了") }

        let mem = llama_get_memory(ctx)
        // 只保留前缀、删掉后面的；模型里有循环层时删不了（返回 false），就整个重算
        if pre == cachedPrefix, llama_memory_seq_rm(mem, 0, llama_pos(pre.count), -1) {
        } else if pre == cachedPrefix, !prefixState.isEmpty, restorePrefix(mem) {
        } else {
            llama_memory_clear(mem, true)
            cachedPrefix = []
            prefixState = []
            var i = 0
            while i < pre.count {
                // 点了停止：长提示词读到一半也马上停（不然下一句要排在它后面等）
                if Task.isCancelled { throw CancellationError() }
                let chunk = Array(pre[i..<min(pre.count, i + 512)])
                try decode(chunk)
                i += chunk.count
            }
            cachedPrefix = pre
            savePrefix()
        }
        try decode(suf)

        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(chain) }
        guard let g = llama_sampler_init_grammar(vocab, grammar, "root") else { throw PushError("指令语法有错") }
        llama_sampler_chain_add(chain, g)
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())

        var bytes: [UInt8] = []
        var depth = 0
        var inString = false
        var escaped = false
        for _ in 0..<maxTokens {
            if Task.isCancelled { break }
            let t = llama_sampler_sample(chain, ctx, -1)
            if llama_vocab_is_eog(vocab, t) { break }
            let p = piece(t)
            bytes += p
            // JSON 对象收口就停，不用等结束符
            for b in p {
                if escaped { escaped = false; continue }
                if inString {
                    if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
                    continue
                }
                if b == 0x22 { inString = true } else if b == 0x7B { depth += 1 } else if b == 0x7D { depth -= 1 }
            }
            if depth == 0 && bytes.contains(0x7B) { break }
            try decode([t])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
