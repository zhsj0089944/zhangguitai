import Foundation
import Darwin

/// 后台服务的启停。调的是原来那两个脚本，不重写逻辑 ——
/// 关掉 App 不影响服务，这点由「父进程是 launchd，不是 App」保证。
enum Service {

    struct Result {
        let ok: Bool
        let message: String
    }

    struct RunResult {
        let code: Int32
        let output: String
        let timedOut: Bool
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 100) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        p.environment = ProcessInfo.processInfo.environment

        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return RunResult(code: -1, output: "调不起 \(path)", timedOut: false) }

        var data = Data()
        let lock = NSLock()
        let readDone = DispatchSemaphore(value: 0)
        // 必须异步把管道读空；同步 availableData 在没有输出时会一直阻塞，
        // 外层 deadline 根本没机会执行（实测 1 秒超时仍等进程结束）。
        DispatchQueue.global(qos: .utility).async {
            let got = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); data.append(got); lock.unlock()
            readDone.signal()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                Darwin.kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        // 子进程可能把管道留给孙进程；最多再等 1 秒拿现有输出，绝不无限等。
        _ = readDone.wait(timeout: .now() + 1)
        p.terminationHandler = nil
        lock.lock(); let snapshot = data; lock.unlock()
        let output = String(data: snapshot, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return RunResult(
            code: timedOut ? -2 : p.terminationStatus,
            output: output,
            timedOut: timedOut
        )
    }

    private static func outputTail(_ text: String, limit: Int = 500) -> String {
        let compact = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
        guard compact.count > limit else { return compact }
        return "…" + String(compact.suffix(limit))
    }

    static var up: Bool { Api.portOpen() }

    /// 启动交给 launchd 托管，崩了会自动拉回来。
    static func start() -> Result {
        if up { return Result(ok: true, message: "服务本来就在运行") }

        let hasSuper = FileManager.default.fileExists(atPath: Cfg.supervisor.path)
        let hasGuard = FileManager.default.fileExists(atPath: Cfg.guardScript.path)
        guard hasSuper || hasGuard else {
            return Result(ok: false, message: "找不到服务的启动程序，请确认服务已安装在电脑上")
        }

        let script = hasSuper ? Cfg.supervisor.path : Cfg.guardScript.path
        let launched = run("/bin/bash", [script, "start"], timeout: 25)
        let scriptNote = outputTail(launched.output)

        // 冷启动要装依赖、加载浏览器内核，最多等 90 秒
        for _ in 0..<90 {
            if up { return Result(ok: true, message: "服务已启动") }
            Thread.sleep(forTimeInterval: 1)
        }

        var message: String
        if launched.timedOut {
            message = "启动脚本超过 25 秒未结束，已终止"
        } else if launched.code != 0 {
            message = "启动脚本退出码 \(launched.code)"
        } else {
            message = "启动脚本已执行，但 90 秒内端口仍未就绪"
        }
        if !scriptNote.isEmpty { message += "：\(scriptNote)" }
        return Result(ok: false, message: message)
    }

    /// 停止顺序不能反：先拆 launchd 托管，再停守护，最后关端口。
    static func stop() -> Result {
        let was = up
        var notes: [String] = []

        if FileManager.default.fileExists(atPath: Cfg.supervisor.path) {
            let r = run("/bin/bash", [Cfg.supervisor.path, "stop"], timeout: 40)
            if r.timedOut { notes.append("supervise stop 超时") }
            else if r.code != 0, !r.output.isEmpty { notes.append("supervise: \(outputTail(r.output, limit: 180))") }
        }
        if FileManager.default.fileExists(atPath: Cfg.guardScript.path) {
            let r = run("/bin/bash", [Cfg.guardScript.path, "stop"], timeout: 25)
            if r.timedOut { notes.append("guard stop 超时") }
            else if r.code != 0, !r.output.isEmpty { notes.append("guard: \(outputTail(r.output, limit: 180))") }
        }

        for pid in guardPids() { _ = run("/bin/kill", [pid], timeout: 5) }
        Thread.sleep(forTimeInterval: 1)

        if let pid = portPid() {
            _ = run("/bin/kill", [pid], timeout: 5)
            for _ in 0..<15 {
                if !up { break }
                Thread.sleep(forTimeInterval: 1)
            }
            if up {
                _ = run("/bin/kill", ["-9", pid], timeout: 5)
                Thread.sleep(forTimeInterval: 1)
            }
        }

        if up {
            var message = "还有进程占着 \(Cfg.port)"
            if !notes.isEmpty { message += "；脚本输出：\(notes.joined(separator: "；"))" }
            return Result(ok: false, message: message)
        }
        var message = was ? "服务已停止" : "本来就是停着的"
        if !notes.isEmpty, was {
            message += "（脚本有告警：\(notes.joined(separator: "；"))）"
        }
        return Result(ok: true, message: message)
    }

    static func restart() -> Result {
        let stopped = stop()
        guard stopped.ok else {
            return Result(ok: false, message: "重启失败：服务没能停干净（\(stopped.message)）")
        }
        Thread.sleep(forTimeInterval: 1)
        return start()
    }

    private static func portPid() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(Cfg.port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let first = s.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
        return (first?.isEmpty == false) ? first : nil
    }

    /// 只找真的在跑守护循环的进程。
    /// 不用 `pkill -f` —— 它会把命令行里带同样字串的进程全杀掉（grep、编辑器、调用它的 shell）。
    private static func guardPids() -> [String] {
        let me = String(ProcessInfo.processInfo.processIdentifier)
        var out: [String] = []
        for pid in pgrep("xianyu_guard.sh") {
            guard pid != me else { continue }
            let cmd = ps(pid)
            guard cmd.contains("xianyu_guard.sh"), cmd.contains("_loop"),
                  !cmd.contains("grep"), !cmd.contains("pgrep"), !cmd.contains("pkill") else { continue }
            out.append(pid)
        }
        return out
    }

    private static func pgrep(_ pattern: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-u", "\(getuid())", "-f", pattern]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func ps(_ pid: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", pid, "-o", "command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
