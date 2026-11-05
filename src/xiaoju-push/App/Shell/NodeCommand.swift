import Foundation
import JavaScriptCore

// node / js 命令：用 iPhone 自带的 JavaScriptCore 跑 JavaScript（没有 npm，也没有 Node 的大部分模块）。
// 支持 node 文件.js、node -e "代码"、node -p "表达式"；有 console.log/error、process.argv/env/exit、
// require("fs") 的 readFileSync / writeFileSync / existsSync / readdirSync、require("path") 的 join/basename/dirname。
// ios_system 按 commandDictionary.plist 里的 MAIN / xiaoju_node_main 找到这里。

@_silgen_name("xiaoju_thread_stdout") private func threadStdout() -> UnsafeMutablePointer<FILE>?
@_silgen_name("xiaoju_thread_stderr") private func threadStderr() -> UnsafeMutablePointer<FILE>?

@_cdecl("xiaoju_node_main")
public func xiaojuNodeMain(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    let out = threadStdout(), err = threadStderr()
    func write(_ s: String, _ f: UnsafeMutablePointer<FILE>?) { if let f { fputs(s, f); fflush(f) } }
    var args: [String] = (0..<Int(argc)).compactMap { argv?[$0].map { String(cString: $0) } }
    let name = args.first ?? "node"
    args.removeFirst()

    var code: String, file = "[eval]", printResult = false
    if let i = args.firstIndex(where: { $0 == "-e" || $0 == "-p" || $0 == "--eval" || $0 == "--print" }), i + 1 < args.count {
        printResult = args[i] == "-p" || args[i] == "--print"
        code = args[i + 1]
        args = Array(args[(i + 2)...])
    } else if let f = args.first, !f.hasPrefix("-") {
        file = f
        guard let s = try? String(contentsOfFile: f, encoding: .utf8) else {
            write("\(name): 打不开 \(f)\n", err); return 1
        }
        code = s.hasPrefix("#!") ? s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined() : s
        args.removeFirst()
    } else {
        write("用法：\(name) 文件.js ｜ \(name) -e \"代码\" ｜ \(name) -p \"表达式\"\n", err); return 2
    }

    guard let ctx = JSContext() else { write("\(name): 起不来 JavaScriptCore\n", err); return 1 }
    var exitCode: Int32? = nil
    var failed = false
    ctx.exceptionHandler = { _, e in
        if exitCode != nil { return }
        failed = true
        let stack = e?.objectForKeyedSubscript("stack")?.toString() ?? ""
        write("\(e?.toString() ?? "出错了")\n" + (stack.isEmpty || stack == "undefined" ? "" : stack + "\n"), err)
    }

    // 把参数格式化成 console.log 的样子：字符串原样，其他用 JSON
    ctx.evaluateScript("""
    var __fmt = function(a){ return Array.prototype.map.call(a, function(x){
      if (typeof x === 'string') return x;
      if (x instanceof Error) return String(x.stack || x);
      if (typeof x === 'function') return '[Function]';
      if (x === undefined) return 'undefined';
      try { var s = JSON.stringify(x, null, 2); return s === undefined ? String(x) : s; } catch(e) { return String(x); }
    }).join(' '); };
    """)
    let log: @convention(block) (String) -> Void = { write($0 + "\n", out) }
    let logErr: @convention(block) (String) -> Void = { write($0 + "\n", err) }
    ctx.setObject(log, forKeyedSubscript: "__out" as NSString)
    ctx.setObject(logErr, forKeyedSubscript: "__err" as NSString)
    ctx.evaluateScript("""
    var console = {
      log: function(){ __out(__fmt(arguments)); }, info: function(){ __out(__fmt(arguments)); },
      error: function(){ __err(__fmt(arguments)); }, warn: function(){ __err(__fmt(arguments)); },
      table: function(x){ __out(__fmt([x])); }
    };
    var print = console.log;
    """)

    // process
    let exit: @convention(block) (Int32) -> Void = { c in
        exitCode = c
        JSContext.current()?.exception = JSValue(newErrorFromMessage: "__exit__", in: JSContext.current())
    }
    let cwd: @convention(block) () -> String = { FileManager.default.currentDirectoryPath }
    ctx.setObject(exit, forKeyedSubscript: "__exit" as NSString)
    ctx.setObject(cwd, forKeyedSubscript: "__cwd" as NSString)
    ctx.setObject(["node", file] + args, forKeyedSubscript: "__argv" as NSString)
    ctx.setObject(ProcessInfo.processInfo.environment, forKeyedSubscript: "__env" as NSString)
    ctx.evaluateScript("""
    var process = { argv: __argv, env: __env, platform: 'ios', exitCode: 0,
      exit: function(c){ __exit(c === undefined ? process.exitCode : c); }, cwd: function(){ return __cwd(); },
      stdout: { write: function(s){ __out(String(s).replace(/\\n$/, '')); } },
      stderr: { write: function(s){ __err(String(s).replace(/\\n$/, '')); } } };
    """)

    // fs / path（只做常用的同步函数）
    let read: @convention(block) (String) -> Any = { p in
        if let s = try? String(contentsOfFile: p, encoding: .utf8) { return s }
        JSContext.current()?.exception = JSValue(newErrorFromMessage: "ENOENT: 打不开文件 '\(p)'", in: JSContext.current())
        return NSNull()
    }
    let writeFile: @convention(block) (String, String) -> Void = { p, s in
        do { try s.write(toFile: p, atomically: true, encoding: .utf8) } catch {
            JSContext.current()?.exception = JSValue(newErrorFromMessage: "写不了 '\(p)'：\(error.localizedDescription)", in: JSContext.current())
        }
    }
    let exists: @convention(block) (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    let list: @convention(block) (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0))?.sorted() ?? [] }
    ctx.setObject(read, forKeyedSubscript: "__read" as NSString)
    ctx.setObject(writeFile, forKeyedSubscript: "__write" as NSString)
    ctx.setObject(exists, forKeyedSubscript: "__exists" as NSString)
    ctx.setObject(list, forKeyedSubscript: "__list" as NSString)
    ctx.evaluateScript("""
    var __mods = {
      fs: { readFileSync: function(p){ return __read(String(p)); }, writeFileSync: function(p, s){ __write(String(p), String(s)); },
            existsSync: function(p){ return __exists(String(p)); }, readdirSync: function(p){ return __list(String(p)); } },
      path: { join: function(){ return Array.prototype.join.call(arguments, '/').replace(/\\/+/g, '/'); },
              basename: function(p){ return String(p).split('/').pop(); },
              dirname: function(p){ var a = String(p).split('/'); a.pop(); return a.join('/') || '.'; },
              extname: function(p){ var m = /\\.[^./]*$/.exec(String(p)); return m ? m[0] : ''; } }
    };
    var module = { exports: {} }, exports = module.exports;
    function require(n){ n = String(n).replace(/^node:/, '');
      if (__mods[n]) return __mods[n];
      throw new Error("手机上没有 Node 的 '" + n + "' 模块（没有 npm，只有 fs、path）"); }
    """)

    failed = false
    let result = ctx.evaluateScript(code, withSourceURL: URL(fileURLWithPath: file))
    if let c = exitCode { return c }
    if failed { return 1 }
    if printResult, let r = result, !r.isUndefined {
        ctx.setObject(r, forKeyedSubscript: "__r" as NSString)
        ctx.evaluateScript("console.log(__r)")
    }
    let pc = ctx.evaluateScript("process.exitCode")?.toInt32() ?? 0
    return pc
}
