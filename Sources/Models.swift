import Foundation

// MARK: - 服务

struct Health: Decodable {
    struct Services: Decodable {
        let cookie_manager: String?
        let database: String?
    }
    struct Sys: Decodable {
        let cpu_percent: Double?
        let memory_percent: Double?
    }
    let status: String
    let services: Services?
    let system: Sys?
}

// MARK: - 店铺账号

struct Account: Decodable, Identifiable {

    struct Run: Decodable {
        let running: Bool?
        let connection_state: String?
        let ws_ready: Bool?
        let session_ready: Bool?
        let has_current_token: Bool?
        let message_stream_status: String?
        let message_stream_ready: Bool?
        let message_stream_note: String?
        let token_refresh_status: String?
        let last_heartbeat_age_seconds: Int?
        let last_user_chat_age_seconds: Int?
        let token_last_refreshed_at_display: String?
        let last_stream_watchdog_reconnect_at_display: String?
    }

    let id: String
    let enabled: Bool?
    let username: String?
    let remark: String?
    let auto_confirm: Bool?
    let auto_comment: Bool?
    let auto_red_flower: Bool?
    let pause_duration: Int?
    let runtime_status: Run?

    /// 只有真正“收发正常”才算在线。running/ws/session 都为 true 但
    /// message_stream 已卡死时是“假在线”，不能拿去点亮菜单栏和总览绿点。
    var isOnline: Bool { link == .fine }

    /// 连接状态。五档，别做成二值 —— 「假在线」是最坑的一档。
    enum Link {
        case fine, fake, retrying, down, off

        var text: String {
            switch self {
            case .fine: return "正常"
            case .fake: return "假在线"
            case .retrying: return "重连中"
            case .down: return "已断开"
            case .off: return "未启用"
            }
        }

        var hint: String {
            switch self {
            case .fine: return "收发正常"
            case .fake: return "连着但收不到买家消息，建议重连"
            case .retrying: return "正在自动重连，等一下"
            case .down: return "自动重连没成功，点重连接一下"
            case .off: return "这个账号没启用，不收发消息"
            }
        }
    }

    var link: Link {
        guard enabled ?? true else { return .off }
        // 账号明确启用但拿不到运行态，是“断开”，不是“未启用”。
        guard let r = runtime_status else { return .down }
        guard r.running == true else { return .down }
        // 服务端已经算好 message_stream_ready 布尔值，它就是权威判据。
        // 别再自己拿 status 字符串做白名单：曾漏掉 recovering，把「正在重连」
        // 显示成绿色「正常」；也曾把 warming_up/watching 这类服务端认为可用的
        // 状态误判成「假在线」。只有布尔值缺失（老服务端）才退回字符串。
        if r.ws_ready == true && r.session_ready == true {
            if let ready = r.message_stream_ready { return ready ? .fine : .fake }
            switch r.message_stream_status {
            case "suspected_stale", "connection_unready", "recovering":
                return .fake
            default:
                return .fine
            }
        }
        if r.connection_state == "reconnecting" { return .retrying }
        return r.ws_ready == true ? .fake : .down
    }

    var heartbeat: String {
        guard let s = runtime_status?.last_heartbeat_age_seconds else { return "—" }
        if s < 90 { return "\(s) 秒前" }
        if s < 5400 { return "\(s / 60) 分钟前" }
        return "\(s / 3600) 小时前"
    }

    var lastTalk: String {
        guard let s = runtime_status?.last_user_chat_age_seconds else { return "还没有" }
        if s < 90 { return "\(s) 秒前" }
        if s < 5400 { return "\(s / 60) 分钟前" }
        if s < 172800 { return "\(s / 3600) 小时前" }
        return "\(s / 86400) 天前"
    }

    var title: String {
        if let r = remark, !r.isEmpty { return r }
        if let u = username, !u.isEmpty { return u }
        return id
    }

    /// 只改启用标记的副本。用于点击后立刻翻转按钮，不等整表回读。
    func withEnabled(_ on: Bool) -> Account {
        Account(id: id, enabled: on, username: username, remark: remark,
                auto_confirm: auto_confirm, auto_comment: auto_comment,
                auto_red_flower: auto_red_flower, pause_duration: pause_duration,
                runtime_status: runtime_status)
    }
}

// MARK: - 营收

struct SalesSummary: Decodable {
    struct Data: Decodable {
        let today_sales: Double
        let week_sales: Double
        let month_sales: Double
        let update_time: String?
    }
    let success: Bool
    let data: Data?
}

/// 平台实付台账口径。`fresh=false` 时页面必须显示“未同步”，绝不能
/// 把旧数据当成今天营收，也不能退回 orders.amount 标价。
struct PaidSales: Decodable {
    struct Shop: Decodable {
        let today: Double
        let week: Double
        let month: Double
        let order_count: Int?
    }

    let success: Bool
    let data: [String: Shop]?
    let fresh: Bool?
    let fetched_at: String?
    let coverage_end: String?
    let data_updated_at: String?
    let message: String?
}

// MARK: - 订单

struct Order: Decodable, Identifiable {

    struct DeliveryProgress: Decodable {
        let expected_quantity: Int?
        let finalized_count: Int?
        let pending_finalize_count: Int?
        let remaining_count: Int?
        let aggregate_status: String?
    }

    let order_id: String
    let item_id: String?
    let buyer_nick: String?
    let buyer_id: String?
    let quantity: String?
    let amount: String?
    let order_status: String?
    let platform_created_at: String?
    let platform_paid_at: String?
    let platform_completed_at: String?
    let cookie_id: String?
    let created_at: String?
    let sid: String?
    let delivery_progress: DeliveryProgress?

    var id: String { order_id }

    var amountValue: Double { Double(amount ?? "") ?? 0 }

    var isPaid: Bool { (platform_paid_at?.isEmpty == false) }

    /// 库里时间都是 UTC，展示 +8。空字符串不能参与 coalesce。
    var when: String {
        let raw = [platform_paid_at, platform_created_at, created_at]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let raw else { return "—" }
        return Clock.utcToLocal(raw)
    }

    var statusText: String {
        switch order_status {
        case "completed": return "已完成"
        case "shipped": return "已发货"
        case "pending_ship": return "还没发货"
        case "refunding": return "退款中"
        case "refund_cancelled": return "退款撤销"
        case "cancelled": return "已取消"
        case "pending_payment": return "待付款"
        case "processing": return "处理中"
        case "partial_success": return "发了一部分"
        case "partial_pending_finalize": return "待收尾"
        default: return order_status ?? "—"
        }
    }

    var isDone: Bool { order_status == "completed" }
    var isDead: Bool { order_status == "cancelled" || order_status == "refunding" }

    /// 这单还需要我动手吗。已完成的不需要 —— 日志里没 success 也不代表没发（手动补发不进日志）。
    var needsMe: Bool {
        switch order_status {
        case "pending_ship", "shipped", "partial_success", "partial_pending_finalize":
            return true
        default:
            return false
        }
    }
}

/// 发货结果。优先用服务端逐单元进度，日志只作为补充证据。
enum Ship: String {
    case sent, partial, noRule, multi, unconfirmed, failed, otherShop, skipped, unknown

    var text: String {
        switch self {
        case .sent: return "已发"
        case .partial: return "部分已发"
        case .noRule: return "没找到发货内容"
        case .multi: return "撞了多条发货规则"
        case .unconfirmed: return "发送未确认"
        case .failed: return "发货失败"
        case .otherShop: return "不是本店的单"
        case .skipped: return "未执行"
        case .unknown: return "暂无记录"
        }
    }

    /// 只要不能证明整单已发完，就必须进入人工核对。
    var isBad: Bool {
        switch self {
        case .noRule, .multi, .unconfirmed, .failed, .partial, .skipped, .unknown:
            return true
        default:
            return false
        }
    }
}

struct DeliveryLog: Decodable {
    let id: Int?
    let cookie_id: String?
    let order_id: String?
    let buyer_nick: String?
    let status: String?
    let reason: String?
    let created_at: String?
    let channel: String?
}

// MARK: - 会话

struct ChatSession: Decodable, Identifiable {
    let chat_id: String
    let buyer_name: String?
    let sender_name: String?
    let content: String?
    let content_type: Int?
    let item_id: String?
    let item_title: String?
    let direction: Int?
    let created_at: String?
    let unread_count: Int?
    let buyer_id: String?
    let sender_id: String?
    let source: String?

    var id: String { chat_id }

    /// 当前这条摘要的指纹。人工标「已读」时记下它，用来判断这条已读还作不作数：
    /// 买家再发新消息，时间/内容变了 → 指纹变了 → 提示自动回来。
    var stamp: String {
        let c = content ?? ""
        return "\(created_at ?? "")|\(direction ?? 0)|\(c.prefix(60))"
    }

    var who: String {
        if let b = buyer_name, !b.isEmpty, b != "未知用户" { return b }
        if let s = sender_name, !s.isEmpty, s != "未知用户" { return s }
        return chat_id
    }

    /// 最后一条是买家发的真人内容 → 在等你回。
    /// 图片/语音也是买家消息，不能因为摘要以 "[" 开头就当系统噪声。
    var waiting: Bool {
        guard direction == 2 else { return false }
        // 未读是强信号，无论多久都算。
        if (unread_count ?? 0) > 0 { return !isSystemCard && !isAck }
        // 未读为 0 不等于“不用回”：店主可能在手机上看过还没回、或回在别处。
        // 但不能把几个月前的历史买家话永久算等待，所以只回看最近 7 天。
        guard Clock.date(created_at) != nil, minutes <= 7 * 24 * 60 else { return false }
        guard let c = content, !c.isEmpty else { return false }
        if isSystemCard { return false }
        if isAck { return false }
        for s in ChatSession.noise where c.hasPrefix(s) { return false }
        return true
    }

    /// 只是「知道了」的收尾应答，不是提问，不需要回。
    /// 实测踩过：买家说完 okok 后又发了个 [ok]，会话摘要停在 [ok] 上，
    /// 一条 5 天前的收尾被算成「等你回话」。
    ///
    /// 只认「整条就是一个方括号短词」这种平台表情/应答，比如 [ok]、[比心]。
    /// 不打折地认「好的」「谢谢」—— 那是买家亲手打的字，哪怕只是客套，
    /// 未读时也该让店主自己看见（宁可多一条，不可漏一条）。
    private var isAck: Bool {
        let t = (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("["), t.hasSuffix("]"), t.count <= 8 else { return false }
        let inner = t.dropFirst().dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ChatSession.acks.contains(inner)
    }

    /// 值不值得出现在列表里。未知用户 + 系统卡片 = 平台推送，留着只会埋掉真买家。
    var worth: Bool {
        if waiting { return true }
        if who != chat_id && who != "未知用户" { return true }
        guard let c = content, !c.isEmpty else { return false }
        return !isSystemCard
    }

    /// 平台交易/评价通知。只认明确文案，绝不把普通方括号文本和图片一起误杀。
    private var isSystemCard: Bool {
        let c = content ?? ""
        if ChatSession.systemPrefixes.contains(where: { c.hasPrefix($0) }) { return true }
        for s in ChatSession.noise where c.hasPrefix(s) { return true }
        return false
    }

    var minutes: Int {
        guard let d = Clock.date(created_at) else { return 0 }
        return max(0, Int(Date().timeIntervalSince(d) / 60))
    }

    var when: String { Clock.monthDayTime(created_at) }

    static let noise = [
        "快给ta一个评价吧", "有蚂蚁森林能量可领", "诚邀您参与", "闲小蜜", "对方正在输入",
        // 自己的自动话术偶尔被平台记成买家方向（direction=2），不是买家在提问。
        "已收到小红花", "已求买家送我闲鱼小红花",
    ]

    /// 「知道了」类应答。只在整条是 `[xxx]` 时参与判定，
    /// 所以这里放表情/短应答就行，不会误伤买家真说的话。
    static let acks: Set<String> = [
        "ok", "okay", "okk", "okok", "okokok", "比心", "好的", "好", "收到", "已收到",
        "谢谢", "谢啦", "了解", "知道", "微笑", "笑哭", "赞", "呵呵", "哈哈",
    ]

    /// 平台交易/评价通知。只认明确文案，绝不把普通方括号文本和图片一起误杀。
    /// 这张表是拿两店 137+13 个真实会话的 direction=2 文案全集反查出来的：
    /// 漏一条，总览就会多报一个「买家在等你回话」。
    static let systemPrefixes = [
        "[你已发货]", "[我完成了评价]", "[退款成功", "[超时未付款",
        "[卡片消息]", "[交易关闭]", "[订单", "[系统", "[工作台通知]",
        // 2026-11-09 实测漏网：这四条曾让「5 个买家等你回话」全是假数字。
        "[买家确认收货", "[我已付款", "[我已拍下", "[你已评价",
    ]
}

struct ChatMessage: Decodable, Identifiable {
    let id: String
    let chat_id: String
    let sender_id: String?
    let sender_name: String?
    let content: String?
    let direction: Int?
    let reply_source: String?
    let created_at: String?

    var mine: Bool { direction == 1 }

    var source: String? {
        guard mine else { return nil }
        guard let s = reply_source, !s.isEmpty else { return "手动" }
        return s
    }

    enum Keys: String, CodingKey {
        case id, chat_id, sender_id, sender_name, content, direction, reply_source, created_at
    }

    /// 本地造一条（只在界面上显示，不会真的发出去）
    static func local(_ text: String) -> ChatMessage {
        ChatMessage(text)
    }

    private init(_ text: String) {
        id = UUID().uuidString
        chat_id = ""
        sender_id = nil
        sender_name = nil
        content = text
        direction = 1
        reply_source = "本地提示"
        created_at = nil
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Keys.self)
        chat_id = (try? c.decode(String.self, forKey: .chat_id)) ?? ""
        sender_id = try? c.decodeIfPresent(String.self, forKey: .sender_id)
        sender_name = try? c.decodeIfPresent(String.self, forKey: .sender_name)
        content = try? c.decodeIfPresent(String.self, forKey: .content)
        direction = try? c.decodeIfPresent(Int.self, forKey: .direction)
        reply_source = try? c.decodeIfPresent(String.self, forKey: .reply_source)
        created_at = try? c.decodeIfPresent(String.self, forKey: .created_at)
        if let s = try? c.decodeIfPresent(String.self, forKey: .id) { id = s }
        else if let i = try? c.decodeIfPresent(Int.self, forKey: .id) { id = String(i) }
        else { id = UUID().uuidString }
    }
}

// MARK: - 其它

struct ItemBrief: Decodable {
    let item_id: String
    let item_title: String?
    let item_price: String?
}

struct RuleBrief: Decodable {
    let id: Int?
    let keyword: String?
    let enabled: Bool?
    /// 服务端直出的店铺归属（delivery_rules.cookie_id 本来就有）。
    /// 以前不带这一列，客户端拿 keyword 反推标题，330 条里会漏 12 条。
    let cookie_id: String?
}

struct AISettings: Decodable {
    let ai_enabled: Bool?
    let model_name: String?
    let base_url: String?
    let api_key: String?
    let api_type: String?
    let max_discount_percent: Int?
    let max_discount_amount: Int?
    let max_bargain_rounds: Int?
    let custom_prompts: String?
}

struct LogStats: Decodable {
    struct S: Decodable {
        let total_logs: Int?
        let max_capacity: Int?
    }
    let success: Bool?
    let stats: S?
}

// MARK: - 时间

enum Clock {

    private static let f: DateFormatter = {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.timeZone = TimeZone(identifier: "Asia/Shanghai")
        d.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return d
    }()

    static func date(_ s: String?) -> Date? {
        guard let s, s.count >= 19 else { return nil }
        return f.date(from: String(s.prefix(19)))
    }

    /// 库里是 UTC，界面要北京时间
    static func utcToLocal(_ utc: String) -> String {
        guard let d = f.date(from: String(utc.prefix(19))) else { return String(utc.prefix(16)) }
        let local = d.addingTimeInterval(8 * 3600)
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = TimeZone(identifier: "Asia/Shanghai")
        out.dateFormat = "MM-dd HH:mm"
        return out.string(from: local)
    }

    static func monthDayTime(_ s: String?) -> String {
        guard let s, s.count >= 16 else { return "" }
        return String(s.dropFirst(5).prefix(11))
    }

    static func hms(_ d: Date) -> String {
        let x = DateFormatter()
        x.dateFormat = "HH:mm:ss"
        return x.string(from: d)
    }

    static func today() -> String {
        let x = DateFormatter()
        x.dateFormat = "yyyy-MM-dd"
        return x.string(from: Date())
    }

    /// 分钟 → 人话
    static func ago(_ m: Int) -> String {
        if m < 1 { return "刚刚" }
        if m < 60 { return "\(m) 分钟" }
        if m < 1440 { return "\(m / 60) 小时" }
        return "\(m / 1440) 天"
    }
}
