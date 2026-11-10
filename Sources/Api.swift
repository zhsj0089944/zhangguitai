import Foundation

enum NetError: LocalizedError {
    case down
    case auth(String)
    case http(Int, String?)
    case bad(String)

    var errorDescription: String? {
        switch self {
        case .down: return "服务没开"
        case .auth(let m): return "登录失败：\(m)"
        case .http(let c, let detail):
            if let detail, !detail.isEmpty { return detail }
            return "接口报错 \(c)"
        case .bad(let m): return "数据格式不对：\(m)"
        }
    }
}

struct ResendOutcome {
    let ok: Bool
    let message: String
    let remaining: Int
    let failed: Int
}

struct ChatSessionsPayload {
    let sessions: [ChatSession]
    let source: String?
    let remoteError: String?
    let hasMore: Bool
}

struct ChatMessagesPayload {
    let messages: [ChatMessage]
    let source: String?
    let remoteError: String?
    let hasMore: Bool
}

/// 只跟本机的 8090 说话。token 存在内存，401 就自动重登一次再重试。
/// 全部在主线程隔离域里改 token，避免首屏/重启后多个请求并发重登产生竞态。
@MainActor
final class Api {

    static let shared = Api()

    private var token: String?
    private var loginFail: String?
    private var lastTry: Date = .distantPast

    private let url_session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 25
        c.timeoutIntervalForResource = 60
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()

    // MARK: 底层

    private func makeURL(_ path: String) -> URL? {
        URL(string: Cfg.base + (path.hasPrefix("/") ? path : "/" + path))
    }

    nonisolated static func portOpen() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = UInt16(Cfg.port).bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }

    private func login() async throws {
        if Date().timeIntervalSince(lastTry) < 5, let m = loginFail { throw NetError.auth(m) }
        lastTry = Date()
        loginFail = nil

        guard let pw = Cfg.password() else {
            loginFail = "读不到后台登录密码，请检查服务是否已正确安装"
            throw NetError.auth(loginFail!)
        }
        guard let u = makeURL("/login") else { throw NetError.down }

        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["username": "admin", "password": pw])

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await url_session.data(for: req)
        } catch let e as URLError {
            let downCodes: Set<URLError.Code> = [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut]
            if downCodes.contains(e.code) { throw NetError.down }
            throw NetError.bad(e.localizedDescription)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            throw NetError.http(status, Self.errorDetail(data))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            loginFail = "登录没有返回"
            throw NetError.auth(loginFail!)
        }
        if obj["success"] as? Bool == true, let t = obj["token"] as? String {
            token = t
        } else {
            loginFail = (obj["message"] as? String) ?? "密码不对"
            throw NetError.auth(loginFail!)
        }
    }

    private func raw(_ path: String, _ method: String = "GET",
                     body: [String: Any]? = nil, retry: Bool = true) async throws -> Data {
        guard Cfg.password() != nil else { throw NetError.auth("没有密码") }
        if token == nil { try await login() }
        guard let u = makeURL(path) else { throw NetError.down }

        var req = URLRequest(url: u)
        req.httpMethod = method
        if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await url_session.data(for: req)
        } catch let e as URLError {
            let downCodes: Set<URLError.Code> = [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut]
            if downCodes.contains(e.code) { throw NetError.down }
            throw NetError.bad(e.localizedDescription)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, retry {
            // 服务重启过，token 全废（SESSION_TOKENS 在内存里）。重登一次。
            token = nil
            try await login()
            return try await raw(path, method, body: body, retry: false)
        }
        if code >= 400 {
            throw NetError.http(code, Self.errorDetail(data))
        }
        return data
    }

    /// 把 FastAPI 的 detail / 业务 message 原样带到界面，别再只显示“接口报错 400”。
    private static func errorDetail(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let detail = obj["detail"] as? String, !detail.isEmpty { return detail }
        if let message = obj["message"] as? String, !message.isEmpty { return message }
        if let error = obj["error"] as? String, !error.isEmpty { return error }
        return nil
    }

    private func get<T: Decodable>(_ path: String, _ type: T.Type) async throws -> T {
        let d = try await raw(path)
        do { return try JSONDecoder().decode(T.self, from: d) }
        catch {
            throw NetError.bad("\(T.self)：\(error.localizedDescription)")
        }
    }

    private func post(_ path: String, _ method: String = "POST",
                      _ body: [String: Any] = [:]) async throws -> [String: Any] {
        let d = try await raw(path, method, body: body)
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw NetError.bad("接口没有返回有效 JSON")
        }
        if o["success"] as? Bool == false {
            throw NetError.bad((o["message"] as? String) ?? (o["detail"] as? String) ?? "操作没有成功")
        }
        return o
    }

    // MARK: 读

    func health() async throws -> Health { try await get("/health", Health.self) }
    func accounts() async throws -> [Account] { try await get("/cookies/details", [Account].self) }

    func sales() async throws -> SalesSummary.Data? {
        struct W: Decodable { let success: Bool; let data: SalesSummary.Data? }
        return (try await get("/api/sales/summary?period=today", W.self)).data
    }

    func paidSales() async throws -> PaidSales {
        try await get("/api/sales/paid-summary", PaidSales.self)
    }

    /// 让服务端立刻去平台重拉实付台账（约 3 秒），再读汇总。
    /// 以前刷新只是把旧台账再读一遍，数字不会变，看着像没反应。
    func refreshPaidSales() async throws -> String {
        let o = try await post("/api/sales/paid-summary/refresh")
        return (o["message"] as? String) ?? "实付台账已刷新"
    }

    func orders() async throws -> [Order] {
        struct W: Decodable { let success: Bool; let data: [Order]? }
        guard let data = (try await get("/api/orders", W.self)).data else {
            throw NetError.bad("订单接口没有返回 data")
        }
        return data
    }

    func shipLogs() async throws -> [DeliveryLog] {
        struct W: Decodable { let logs: [DeliveryLog]? }
        // 服务端上限已放宽到 1000；正常订单状态现在以逐单元进度为准，
        // 日志只用于解释失败原因，不再承担“整单是否发完”的裁判。
        return (try await get("/delivery-logs/recent?limit=1000", W.self)).logs ?? []
    }

    /// `limit` 决定服务端要不要翻页：平台单页最多 100 条，要 200 就得打两次平台接口，
    /// 是流控的主要来源之一。总览/账号页只要「谁在等我」，100 条足够；会话页才要 200。
    func sessions(_ shop: String, limit: Int = 100) async throws -> ChatSessionsPayload {
        struct W: Decodable {
            let success: Bool?
            let sessions: [ChatSession]?
            let source: String?
            let remote_error: String?
            let has_more: Bool?
            let message: String?
        }
        // remote=true：直接问平台要实时会话列表。服务端会翻页补满请求条数，
        // 并把 source/remote_error/has_more 一起返回，界面必须把这些状态显示出来。
        let w = try await get("/api/chat/sessions?cookie_id=\(shop)&limit=\(limit)&remote=true", W.self)
        if w.success == false { throw NetError.bad(w.message ?? "会话接口没有成功") }
        return ChatSessionsPayload(
            sessions: w.sessions ?? [],
            source: w.source,
            remoteError: w.remote_error,
            hasMore: w.has_more ?? false
        )
    }

    func messages(_ shop: String, _ chat: String) async throws -> ChatMessagesPayload {
        struct W: Decodable {
            let success: Bool?
            let messages: [ChatMessage]?
            let source: String?
            let remote_error: String?
            let has_more: Bool?
            let message: String?
        }
        let w = try await get("/api/chat/messages?cookie_id=\(shop)&chat_id=\(chat)&limit=100&remote=true", W.self)
        if w.success == false { throw NetError.bad(w.message ?? "消息接口没有成功") }
        return ChatMessagesPayload(
            messages: w.messages ?? [],
            source: w.source,
            remoteError: w.remote_error,
            hasMore: w.has_more ?? false
        )
    }

    func items(_ shop: String) async throws -> [ItemBrief] {
        struct W: Decodable { let items: [ItemBrief]? }
        return (try await get("/items/\(shop)", W.self)).items ?? []
    }

    func rules() async throws -> [RuleBrief] { try await get("/delivery-rules", [RuleBrief].self) }

    func ai(_ shop: String) async throws -> AISettings { try await get("/ai-reply-settings/\(shop)", AISettings.self) }

    func logStats() async throws -> LogStats.S? {
        (try await get("/logs/stats", LogStats.self)).stats
    }

    func captchaOn() async throws -> Bool {
        let d = try await raw("/login-captcha-settings")
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let b = o["enabled"] as? Bool else {
            throw NetError.bad("验证码设置")
        }
        return b
    }

    // MARK: 写

    func enable(_ shop: String, _ on: Bool) async throws {
        _ = try await post("/cookies/\(shop)/status", "PUT", ["enabled": on])
    }

    func autoConfirm(_ shop: String, _ on: Bool) async throws {
        _ = try await post("/cookies/\(shop)/auto-confirm", "PUT", ["auto_confirm": on])
    }

    func autoComment(_ shop: String, _ on: Bool) async throws {
        _ = try await post("/cookies/\(shop)/auto-comment", "PUT", ["auto_comment": on])
    }

    func autoFlower(_ shop: String, _ on: Bool) async throws {
        _ = try await post("/cookies/\(shop)/auto-red-flower", "PUT", ["auto_red_flower": on])
    }

    /// 只改开关，其余字段原样带回 —— 少带一个就把 API key 和提示词清空（踩过）。
    func aiOn(_ shop: String, _ on: Bool) async throws {
        let cur = try await ai(shop)
        let body: [String: Any] = [
            "ai_enabled": on,
            "model_name": cur.model_name ?? "deepseek-v4.1-flash",
            "api_key": cur.api_key ?? "",
            "base_url": cur.base_url ?? "",
            "api_type": cur.api_type ?? "openai",
            "max_discount_percent": cur.max_discount_percent ?? 10,
            "max_discount_amount": cur.max_discount_amount ?? 2,
            "max_bargain_rounds": cur.max_bargain_rounds ?? 2,
            "custom_prompts": cur.custom_prompts ?? "",
        ]
        _ = try await post("/ai-reply-settings/\(shop)", "PUT", body)
    }

    func captcha(_ on: Bool) async throws {
        _ = try await post("/login-captcha-settings", "PUT", ["enabled": on])
    }

    func resend(_ orderId: String) async throws -> ResendOutcome {
        let o = try await post("/api/orders/\(orderId)/deliver?force=true")
        let success = (o["success"] as? Bool) ?? false
        let delivered = (o["delivered"] as? Bool) ?? false
        let fully = (o["fully_delivered"] as? Bool) ?? delivered
        let remaining = (o["remaining_count"] as? Int) ?? 0
        let pendingFinalize = (o["pending_finalize_count"] as? Int) ?? 0
        let failed = (o["failed_count"] as? Int) ?? 0
        let message = (o["message"] as? String) ?? (o["error"] as? String) ?? ""
        let ok = success && delivered && fully && remaining == 0 && pendingFinalize == 0 && failed == 0
        return ResendOutcome(
            ok: ok,
            message: message.isEmpty ? (ok ? "补发完成" : "补发没有完成") : message,
            remaining: remaining + pendingFinalize,
            failed: failed
        )
    }

    func send(_ shop: String, _ chat: String, to: String, text: String) async throws -> String {
        let o = try await post("/api/chat/send", "POST", [
            "cookie_id": shop, "chat_id": chat, "to_user_id": to, "message": text,
        ])
        if (o["blocked"] as? Bool) == true { return (o["message"] as? String) ?? "被黑名单拦了" }
        if (o["success"] as? Bool) == true { return "" }
        return (o["message"] as? String) ?? (o["detail"] as? String) ?? "发送失败"
    }

    func exportBackup(to url: URL) async throws {
        try await raw("/backup/export").write(to: url, options: .atomic)
    }

    func clearLogs() async throws {
        _ = try await post("/logs/clear")
    }
}
