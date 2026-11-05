import Foundation
import ios_system

// 手机上跑命令：用 a-Shell 作者的 ios_system（BSD-3），git、grep、sed、curl 这些都做成 App 里的框架，
// 在 App 自己的进程里跑（iPhone 不让 App 启动别的程序）。哪些命令在哪个框架里见 commandDictionary.plist。
// 一次只跑一条（ios_system 里很多是全局状态）。

struct ShellResult {
    var output: String
    var status: Int32
    var seconds: Double
    var killed = false
    var ok: Bool { status == 0 && !killed }
}

/// PythonCommand.c
@_silgen_name("xiaoju_python3_interrupt") private func xiaoju_python3_interrupt() -> Int32

final class ShellRunner: @unchecked Sendable {
    static let shared = ShellRunner()

    /// 一条命令最多跑多久（秒），超时就停掉
    static let timeout: Double = 120
    /// 输出最多留多少字（太长只留最后这些）
    static let maxOutput = 60_000

    private let queue = DispatchQueue(label: "xiaoju.shell", qos: .userInitiated)
    private var ready = false
    private let lock = NSLock()
    private var runningPid: pid_t = 0
    private var killedByUs = false
    /// ios_system 用这个指针当会话 id（按指针区分），一直留着不释放
    private let session: UnsafeMutablePointer<CChar> = strdup("xiaoju-shell")

    private init() {}
    nonisolated(unsafe) static var keep: UnsafeRawPointer?

    /// 只做一次：环境变量、证书、git 配置
    private func setup() {
        guard !ready else { return }
        ready = true
        // curl / git 走 https 要用的证书（App 里带的 Mozilla 证书包）；放在 initializeEnvironment 前面，它就不会改成 文稿/cacert.pem
        if let pem = Bundle.main.path(forResource: "cacert", ofType: "pem") {
            setenv("SSL_CERT_FILE", pem, 1)
        }
        initializeEnvironment()
        joinMainThread = false
        setenv("TERM", "dumb", 1)
        setenv("CLICOLOR", "0", 1)
        setenv("PAGER", "cat", 1)
        setenv("GIT_PAGER", "cat", 1)
        setupPython()
        // node 命令只被 ios_system 用 dlsym 找，没人直接调用；存一下地址，免得编译时被当成没用的代码删掉
        ShellRunner.keep = unsafeBitCast(xiaojuNodeMain as @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32,
                                         to: UnsafeRawPointer.self)
        ios_switchSession(session)
        ios_setContext(session)
    }

    /// python3：App 里带的官方 CPython（App/Shell/PythonCommand.c）。标准库在 App 包的 python/lib/python3.x/
    private func setupPython() {
        let home = Bundle.main.bundleURL.appendingPathComponent("python")
        let lib = home.appendingPathComponent("lib")
        guard let ver = (try? FileManager.default.contentsOfDirectory(atPath: lib.path))?.first(where: { $0.hasPrefix("python3") }),
              let fw = Bundle.main.privateFrameworksURL?.appendingPathComponent("Python.framework/Python") else { return }
        let std = lib.appendingPathComponent(ver)
        setenv("XIAOJU_PYTHON_LIB", fw.path, 1)
        setenv("PYTHONHOME", home.path, 1)
        // pip 装的包放 资源库/python/site-packages（「文件」App 里看不到）；pip 本身从 App 里的 pip.whl 跑
        let site = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("python/site-packages")
        try? FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        setenv("PYTHONPATH", [std.path, std.appendingPathComponent("lib-dynload").path, site.path,
                              home.appendingPathComponent("pip.whl").path].joined(separator: ":"), 1)
        setenv("PIP_TARGET", site.path, 1)
        setenv("PIP_UPGRADE", "1", 1)                  // --target 装过的再装会报「已存在」，直接覆盖
        setenv("PIP_ONLY_BINARY", ":all:", 1)          // 手机上编译不了源码包，只要现成的
        setenv("PIP_DISABLE_PIP_VERSION_CHECK", "1", 1)
        setenv("PIP_NO_INPUT", "1", 1)
        setenv("PIP_CACHE_DIR", FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("pip").path, 1)
        setenv("PYTHONUTF8", "1", 1)
        setenv("PYTHONUNBUFFERED", "1", 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        // ios_system 默认按名字轮换 6 个 Python 解释器（pythonA、pythonB…），我们只有一个
        numPythonInterpreters = 1
    }

    /// git 的全局配置写在 资源库/Preferences/git/config（ios_system 把 XDG_CONFIG_HOME 指到那里，「文件」App 里看不到）。
    /// 推送用 GitHub 令牌当密码；提交作者用你的 GitHub 用户名。
    static func writeGitConfig(name: String, email: String, token: String) {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = lib.appendingPathComponent("Preferences/git", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var cfg = "[user]\n\tname = \(q(name.isEmpty ? "小橘推送" : name))\n\temail = \(q(email.isEmpty ? "xiaoju@users.noreply.github.com" : email))\n"
        if !token.isEmpty { cfg += "\tpassword = \(q(token))\n" }
        let u = dir.appendingPathComponent("config")
        try? cfg.write(to: u, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
    }

    /// 能用的命令名（给提示和「没有这个命令」判断用）
    static let commands: Set<String> = {
        guard let u = Bundle.main.url(forResource: "commandDictionary", withExtension: "plist"),
              let d = NSDictionary(contentsOf: u) as? [String: Any] else { return [] }
        return Set(d.keys)
    }()

    /// 在 cwd 里跑一条命令。output 每收到一段输出就回调一次（在后台线程）。
    func run(_ command: String, cwd: URL, output: @escaping @Sendable (String) -> Void) async -> ShellResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<ShellResult, Never>) in
                queue.async { c.resume(returning: self.runSync(command, cwd: cwd, output: output)) }
            }
        } onCancel: {
            self.stop()
        }
    }

    /// 停掉正在跑的命令。
    /// Python 先像 Ctrl-C 一样让它自己停（硬停会把解释器卡在半路，之后的 python3 都跑不了），5 秒还没停再硬停。
    /// 其他命令用 ios_kill（a-Shell 的 Ctrl-C）；不能直接发 SIGINT，命令没装处理函数时会把整个 App 杀掉。
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard runningPid != 0 else { return }
        killedByUs = true
        let pid = runningPid
        if xiaoju_python3_interrupt() == 1 {
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let still = self.runningPid == pid; self.lock.unlock()
                if still { _ = ios_kill() }
            }
            return
        }
        _ = ios_kill()
    }

    private func runSync(_ command: String, cwd: URL, output: @escaping (String) -> Void) -> ShellResult {
        setup()
        let started = Date()
        var outFds: [Int32] = [0, 0]
        var inFds: [Int32] = [0, 0]
        guard pipe(&outFds) == 0, pipe(&inFds) == 0 else {
            return ShellResult(output: "开不了管道：\(String(cString: strerror(errno)))", status: 1, seconds: 0)
        }
        // 没有键盘输入：stdin 直接是空的（要问用户名密码的命令会读到结束，不会卡住）
        close(inFds[1])
        guard let outFile = fdopen(outFds[1], "w"), let inFile = fdopen(inFds[0], "r") else {
            close(outFds[0]); close(outFds[1]); close(inFds[0])
            return ShellResult(output: "开不了输出", status: 1, seconds: 0)
        }
        setvbuf(outFile, nil, _IOLBF, 0)

        // 读输出：后台一直读到管道关掉
        var collected = Data()
        let collectLock = NSLock()
        let readDone = DispatchSemaphore(value: 0)
        let readFd = outFds[0]
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 8192)
            var pending = Data()
            while true {
                let n = read(readFd, &buf, buf.count)
                if n <= 0 { break }
                let chunk = Data(buf[0..<n])
                collectLock.lock(); collected.append(chunk)
                if collected.count > ShellRunner.maxOutput * 4 { collected = collected.suffix(ShellRunner.maxOutput * 2) }
                collectLock.unlock()
                // 只把完整的 UTF-8 交出去（中文字可能被切成两半）
                pending.append(chunk)
                if let s = String(data: pending, encoding: .utf8) { output(s); pending.removeAll() }
                else if pending.count > 16 { output(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
            }
            if !pending.isEmpty { output(String(decoding: pending, as: UTF8.self)) }
            close(readFd)
            readDone.signal()
        }

        ios_switchSession(session)
        ios_setContext(session)
        ios_setDirectoryURL(cwd)
        ios_setStreams(inFile, outFile, outFile)
        let pid = ios_fork()
        lock.lock(); runningPid = pid; killedByUs = false; lock.unlock()

        // 超时保险
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + ShellRunner.timeout)
        timer.setEventHandler { [weak self] in self?.stop() }
        timer.resume()

        _ = ios_system(command.decomposedStringWithCanonicalMapping)
        ios_waitpid(pid)
        let status = ios_getCommandStatus()
        ios_releaseThreadId(pid)
        timer.cancel()

        lock.lock(); runningPid = 0; let killed = killedByUs; killedByUs = false; lock.unlock()

        // 命令自己可能已经把输出关了；还开着才关（关了读线程才会结束）
        if fcntl(outFds[1], F_GETFD) >= 0 { fflush(outFile); fclose(outFile) }
        if fcntl(inFds[0], F_GETFD) >= 0 { fclose(inFile) }
        _ = readDone.wait(timeout: .now() + 3)

        collectLock.lock()
        var text = String(decoding: collected, as: UTF8.self)
        collectLock.unlock()
        if text.count > ShellRunner.maxOutput { text = "…（前面太长，省掉了）\n" + String(text.suffix(ShellRunner.maxOutput)) }
        return ShellResult(output: text, status: killed && status == 0 ? 130 : status,
                           seconds: Date().timeIntervalSince(started), killed: killed)
    }
}
