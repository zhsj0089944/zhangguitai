import Foundation

/// 数据与状态。界面靠一个 onChange 回调驱动，没有 Combine、没有 SwiftUI。
@MainActor
final class Store {

    // MARK: 状态

    private(set) var serviceUp = false
    private(set) var busy = false
    private(set) var busyText = ""
    private(set) var health: Health?
    private(set) var accounts: [Account] = []
    private(set) var paidSales: [String: PaidSales.Shop] = [:]
    private(set) var revenueFresh = false
    private(set) var revenueUpdatedAt: String?
    private(set) var revenueWarning: String?
    /// 后台是否提供实付营收接口。上游开源版没有 `/api/sales/paid-summary`，
    /// 探测到 404 就置 false，界面把这部分整个收起来。
    private(set) var revenueAvailable = true
    private(set) var orders: [Order] = []
    private(set) var logs: [DeliveryLog] = []
    private(set) var sessions: [String: [ChatSession]] = [:]
    private(set) var itemCount: [String: Int] = [:]
    private(set) var itemTitle: [String: String] = [:]
    private(set) var ruleCount: [String: (all: Int, on: Int)] = [:]
    private(set) var ai: [String: AISettings] = [:]
    private(set) var stats: LogStats.S?
    private(set) var lastUpdate: Date?
    private(set) var lastSuccessfulUpdate: Date?
    private(set) var lastError: String?
    private(set) var lastNotice: String?
    private(set) var sessionMeta: [String: SessionMeta] = [:]
    private(set) var loading = false
    /// 用户点「营收未同步」时用：真的去平台重拉一遍台账，再刷新汇总。
    /// 只在用户点的时候跑 —— 自动跑就等于每分钟开一次无头浏览器。
    private(set) var revenueRefreshing = false
    /// 写操作开始/结束/失败时递增，页面据此重建，不能只靠数据指纹。
    private(set) var uiRevision = 0
    /// 用户主动点刷新时为 true，顶栏据此显示「正在刷新…」，不用你猜有没有生效。
    private(set) var refreshing = false

    func refreshRevenue() async {
        guard !revenueRefreshing else { return }
        revenueRefreshing = true
        uiRevision &+= 1
        dirty()
        defer {
            revenueRefreshing = false
            uiRevision &+= 1
            dirty()
        }
        do {
            let message = try await Api.shared.refreshPaidSales()
            await reloadPaidOnly()
            lastError = nil
            showNotice(message, seconds: 5)
        } catch {
            failed("刷新实收失败：\(error.localizedDescription)")
        }
    }

    /// 只重读营收汇总，不碰其它接口。抓取完成后立刻能看到新数字。
    func reloadPaidOnly() async {
        do {
            let paid = try await Api.shared.paidSales()
            applyPaid(paid)
        } catch {
            // 后台压根没有 /api/sales/paid-summary（上游开源版就没有这个接口）时，
            // 整块营收 UI 收起来 —— 别人拿去用不该看到一个永远「未同步」的空白区。
            if case NetError.http(let code, _) = error, code == 404 {
                revenueAvailable = false
                revenueWarning = nil
            } else {
                revenueAvailable = true
                revenueWarning = "实付营收接口不可用：\(error.localizedDescription)"
            }
            revenueFresh = false
        }
        uiRevision &+= 1
        dirty()
    }

    private func applyPaid(_ paid: PaidSales) {
        if paid.success {
            revenueAvailable = true
            paidSales = paid.data ?? [:]
            revenueFresh = paid.fresh == true
            revenueUpdatedAt = paid.data_updated_at ?? paid.coverage_end
            revenueWarning = paid.fresh == true
                ? nil
                : (paid.message ?? "平台实付台账没有更新到今天，营收暂不显示")
            let missing = accounts.filter { paidSales[$0.id] == nil }
            if paid.fresh == true, !missing.isEmpty {
                revenueFresh = false
                revenueWarning = "实付台账缺少：" + missing.map { short($0.id) }.joined(separator: "、")
            }
        } else {
            paidSales = [:]
            revenueFresh = false
            revenueWarning = paid.message ?? "实付营收不可用"
        }
    }

    /// 会话页右上角那个刷新按钮：直接把当前会话消息重拉一次。
    /// 原来点它只是把同一份缓存再读一遍，看着像没反应。
    private(set) var chatRefreshing = false

    func beginChatRefresh() -> Bool {
        guard !chatRefreshing else { return false }
        chatRefreshing = true
        uiRevision &+= 1
        dirty()
        return true
    }

    func endChatRefresh() {
        chatRefreshing = false
        uiRevision &+= 1
        dirty()
    }

    struct SessionMeta {
        let source: String?
        let remoteError: String?
        let hasMore: Bool
    }

    var onChange: (() -> Void)?
    /// 菜单栏也需要在每次数据变化时重画；onChange 已经被当前页占用。
    var onStatusChange: (() -> Void)?

    private let appStartedAt = Date()
    private var connectStarted: [String: Date] = [:]
    private var activeActions: Set<String> = []
    private var noticeToken = UUID()
    private var timer: Timer?
    private var busyLoading = false
    /// 慢变量（商品数、发货规则、AI 开关）的刷新间隔。这些几乎不变，
    /// 跟着 20 秒轮询每次拉 210KB 纯浪费（每天约 0.9GB）。
    private var slowStamp = Date.distantPast
    private let slowEvery: TimeInterval = 300
    /// 会话列表的刷新间隔。这是唯一会真的打平台 IM 接口的调用：
    /// 原来跟着 20 秒主轮询跑，一天每店 4320 次，实测 11-09 一天被平台
    /// 流控 18 次、单个账号 remote_sessions 长期恒为 0，界面只能读本地缓存。
    /// 90 秒一次（每店 960 次/天）既能保证「有人等你」不滞后，又留出余量。
    private var sessionsStamp = Date.distantPast
    /// 会话页是否正显示在前台。在会话页时买家消息要跟得上，用 30 秒；
    /// 其余页面（总览/订单只要个待回数）90 秒足够，别拿平台接口刷着玩。
    private var chatPageVisible = false
    /// App 是否在前台。被切到后台 / 长时间没人看时，会话列表没必要还按 30 秒打平台。
    /// 切回来 `resumeAfterBackground()` 会恢复节奏并强制刷一次。
    private var appActive = true
    private var sessionsEvery: TimeInterval {
        if !appActive { return 180 }
        return chatPageVisible ? 30 : 90
    }
    /// 会话页要拉多少条。平台单页上限 100，原来会话页要 200 会让服务端多翻一页，
    /// 而翻页是 `listNewestPagination` 请求量的主要来源（11-12 实测一天 1211 次）。
    /// 近期的等回会话都在前 100 条里；更早的只能靠 `has_more` 提示
    /// （客户端没有翻页入口，`Api.sessions` 不带 cursor）。
    private let chatPageLimit = 100
    /// 平台流控冷却截止时间（按店）。服务端在冷却期内本来就只返回本地缓存，
    /// 客户端再按固定节奏去问只会让日志刷屏，这里按服务端给的剩余秒数等。
    private var chatBlockedUntil: [String: Date] = [:]
    /// 商品标题按店缓存（慢变量，5 分钟刷一次）。失败店保留上一版，不能把整店清空。
    private var cachedItemTitles: [String: [String: String]] = [:]
    /// 发货规则缓存（148KB，5 分钟刷一次）
    private var cachedRules: [RuleBrief] = []
    /// 开关的乐观值：点下就按目标值显示，服务端回读一致后自动清掉。
    /// 只给 AI 做这件事是不够的 —— 另外三个开关以前点完会先弹回旧值再跳回来，
    /// 看起来像「点了没反应」。
    private var switchOverrides: [String: Bool] = [:]
    /// 一次抓取还没结束又被要求刷新时，排队。原来直接 return，
    /// 用户点了刷新等于什么都没发生。
    private var pendingForce = false

    private func dirty() {
        onChange?()
        onStatusChange?()
    }

    // MARK: 轮询

    func start() {
        reload()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// 切到会话页时立即拉一次，并切到更快的节奏；离开就退回 90 秒。
    func setChatPageVisible(_ on: Bool) {
        guard chatPageVisible != on else { return }
        chatPageVisible = on
        if on {
            sessionsStamp = .distantPast
            reload(force: true)
        }
    }

    /// 从后台切回来时强制刷一次，并把慢变量也当成过期。
    /// App Nap 会把 Timer 压到十几分钟才跑一次，此时屏幕上的数字是旧的；
    /// 「切回来看到的就是现在」比省那一次请求重要得多。
    func resumeAfterBackground() {
        // 回到前台：恢复 30/90 秒节奏，并立刻补一次最新的。
        appActive = true
        let gap = Date().timeIntervalSince(lastUpdate ?? .distantPast)
        guard gap > 25 else { return }
        // 切回来时把会话节流重置：就算只能拉一次，也要拉最新的。
        sessionsStamp = .distantPast
        chatBlockedUntil = chatBlockedUntil.filter { $0.value > Date() }
        reload(force: true)
    }

    /// 切到后台。会话列表降到 180 秒 —— 平台请求没必要在没人看的时候继续打，
    /// 但也不能停（托盘图标上的待回数还要更新）。
    func enterBackground() {
        appActive = false
    }

    /// 从服务端的「流控冷却中，约 N 秒后自动重试」里把 N 抠出来。
    /// 只认紧挨着「秒」的那个数，不能整句扫数字 —— 报错里可能同时带
    /// 平台错误码 400600001，按最长数字取会取错。解析不出来返回 nil。
    static func cooldownSeconds(in text: String) -> Int? {
        guard let secRange = text.range(of: "秒") else { return nil }
        let head = text[text.startIndex..<secRange.lowerBound]
        var digits: [Character] = []
        for ch in head.reversed() {
            if ch.isNumber { digits.insert(ch, at: 0) }
            else if digits.isEmpty { continue }   // 跳过「约 」这类空白/修饰
            else { break }
        }
        guard !digits.isEmpty, let value = Int(String(digits)),
              value > 0, value <= 3600 else { return nil }
        return value
    }

    func reload() {
        reload(force: false)
    }

    /// `force` = 用户主动点的（刷新按钮、切页、切回来）。
    /// 这种请求必须真的发出：慢变量、会话节流一律绕过，并且在飞的那一轮结束后补跑，
    /// 不能因为「正好有一轮在跑」就静默丢掉。
    func reload(force: Bool) {
        let up = Service.up
        if up != serviceUp {
            serviceUp = up
            if !up { wipe() }
            dirty()
        }
        guard up else {
            lastUpdate = Date()
            refreshing = false
            dirty()
            return
        }
        if force {
            slowStamp = .distantPast
            sessionsStamp = .distantPast
            refreshing = true
            uiRevision &+= 1
        } else if !busyLoading, accounts.isEmpty {
            loading = true
        }
        dirty()
        if busyLoading {
            // 正在跑的那一轮结束后会自己接上，别把这次点击扔掉。
            if force { pendingForce = true }
            return
        }
        Task { await fetchAll() }
    }

    private func fetchAll() async {
        guard !busyLoading else { return }
        busyLoading = true
        loading = accounts.isEmpty
        var failures: [String] = []
        var coreDataSucceeded = false
        let startedAt = Date()
        defer {
            busyLoading = false
            loading = false
            lastUpdate = Date()
            refreshing = false
            // “最后成功”说的是核心看板数据成功到手；单个远端接口降级
            // 只标黄告警，不能因此把已经拿到的数据说成“尚无成功数据”。
            if coreDataSucceeded { lastSuccessfulUpdate = startedAt }
            lastError = failures.isEmpty ? nil : "部分数据未更新：" + Set(failures).sorted().joined(separator: "、")
            dirty()
            // 跑的过程中又被点了一次刷新：立刻补跑，别让那次点击落空。
            if pendingForce {
                pendingForce = false
                Task { await fetchAll() }
            }
        }

        do {
            let h = try await Api.shared.health()
            health = h
            if h.status.lowercased() != "healthy" {
                failures.append("服务健康：\(h.status)")
            }
        } catch {
            health = nil
            failures.append("服务健康：\(error.localizedDescription)")
            if case NetError.down = error { serviceUp = false }
        }

        let slowDue = Date().timeIntervalSince(slowStamp) > slowEvery
        async let accT = Api.shared.accounts()
        async let ordT = Api.shared.orders()
        async let logT = Api.shared.shipLogs()
        async let statT = Api.shared.logStats()
        async let paidT = Api.shared.paidSales()
        var rules = cachedRules
        if slowDue {
            do {
                rules = try await Api.shared.rules()
                cachedRules = rules
            } catch {
                failures.append("发货规则：\(error.localizedDescription)")
            }
        }

        do {
            accounts = try await accT
            coreDataSucceeded = true
        } catch {
            failures.append("账号：\(error.localizedDescription)")
        }
        do {
            orders = try await ordT
        } catch {
            failures.append("订单：\(error.localizedDescription)")
        }
        do {
            logs = try await logT
        } catch {
            failures.append("发货日志：\(error.localizedDescription)")
        }
        do {
            stats = try await statT
        } catch {
            failures.append("日志统计")
        }
        do {
            let paid = try await paidT
            applyPaid(paid)
        } catch {
            paidSales = [:]
            revenueFresh = false
            revenueWarning = "实付营收接口不可用：\(error.localizedDescription)"
        }

        for a in accounts where a.link == .fine {
            connectStarted[a.id] = nil
        }

        var table: [String: [ChatSession]] = [:]
        var meta = sessionMeta
        let sessionsDue = Date().timeIntervalSince(sessionsStamp) > sessionsEvery
        if sessionsDue {
            sessionsStamp = Date()
            for a in accounts {
                // 服务端在平台流控冷却期内只会返回本地缓存，此时不必每轮都问。
                if let until = chatBlockedUntil[a.id], until > Date() {
                    if let old = sessions[a.id] { table[a.id] = old }
                    meta[a.id] = meta[a.id] ?? SessionMeta(source: "cache", remoteError: nil, hasMore: false)
                    continue
                }
                do {
                    // 两页变一页：平台单页上限 100，原来会话页要 200 会让服务端多翻一页，
                    // 是 `listNewestPagination` 请求量的主要来源。
                    let got = try await Api.shared.sessions(a.id, limit: chatPageLimit)
                    if let remoteError = got.remoteError, !remoteError.isEmpty,
                       got.sessions.isEmpty, let old = sessions[a.id], !old.isEmpty {
                        // 远端失败且本地也为空时，别用“空列表”覆盖上一轮真实会话。
                        table[a.id] = old
                    } else {
                        table[a.id] = got.sessions
                    }
                    meta[a.id] = SessionMeta(
                        source: got.source,
                        remoteError: got.remoteError,
                        hasMore: got.hasMore
                    )
                    if let remoteError = got.remoteError, !remoteError.isEmpty {
                        // 服务端把「流控冷却中，约 N 秒后重试」写进 remote_error，
                        // 把 N 解析出来，冷却期内不再发请求 —— 否则冷却一解除就被
                        // 下一轮 20 秒轮询再打一次，退避永远续不上。
                        if let seconds = Self.cooldownSeconds(in: remoteError) {
                            chatBlockedUntil[a.id] = Date().addingTimeInterval(TimeInterval(seconds))
                        }
                        failures.append("\(short(a.id))会话：\(remoteError)")
                    } else {
                        chatBlockedUntil[a.id] = nil
                    }
                } catch {
                    // 单店拉取失败时保留上一轮，不能把整店会话当成“没有会话”。
                    if let old = sessions[a.id] { table[a.id] = old }
                    meta[a.id] = SessionMeta(
                        source: "cache",
                        remoteError: error.localizedDescription,
                        hasMore: meta[a.id]?.hasMore ?? false
                    )
                    failures.append("\(short(a.id))会话：\(error.localizedDescription)")
                }
            }
            sessions = table
            sessionMeta = meta
        }

        if slowDue {
            slowStamp = Date()
            var counts = itemCount
            var shopTitles = cachedItemTitles
            for a in accounts {
                do {
                    let items = try await Api.shared.items(a.id)
                    counts[a.id] = items.count
                    var titleMap: [String: String] = [:]
                    for i in items {
                        if let t = i.item_title, !t.isEmpty {
                            titleMap[i.item_id] = t
                        }
                    }
                    shopTitles[a.id] = titleMap
                } catch {
                    // 保留该店上一版标题和数量，不能一部分失败就显示 0。
                    failures.append("\(short(a.id))商品：\(error.localizedDescription)")
                }
                do {
                    let settings = try await Api.shared.ai(a.id)
                    if !activeActions.contains("toggle:\(a.id):ai") {
                        ai[a.id] = settings
                        // 回读值和目标值一致才清乐观值；不一致说明服务端没存进去，
                        // 这时也要清掉，让界面显示真实值而不是一直停在你的目标值。
                        switchOverrides["ai:\(a.id)"] = nil
                    }
                } catch {
                    failures.append("\(short(a.id)) AI 设置：\(error.localizedDescription)")
                }
            }
            cachedItemTitles = shopTitles
            itemCount = counts
            var mergedTitles: [String: String] = [:]
            for titleMap in shopTitles.values {
                for (id, title) in titleMap { mergedTitles[id] = title }
            }
            itemTitle = mergedTitles
        }

        // 规则条数直接按服务端返回的 cookie_id 分组，不再拿 keyword
        // 去商品标题里反推（反推会漏掉 12 条历史孤立规则，界面少报）。
        var rc: [String: (Int, Int)] = [:]
        for r in rules {
            guard let shop = r.cookie_id, !shop.isEmpty else { continue }
            let cur = rc[shop] ?? (0, 0)
            rc[shop] = (cur.0 + 1, cur.1 + (r.enabled == true ? 1 : 0))
        }
        ruleCount = rc

        rebuildShipState()
    }

    private func wipe() {
        health = nil; accounts = []; orders = []; logs = []
        sessions = [:]; sessionMeta = [:]; itemCount = [:]; itemTitle = [:]; ruleCount = [:]
        ai = [:]; switchOverrides = [:]; stats = nil; ship = [:]
        paidSales = [:]; revenueFresh = false; revenueUpdatedAt = nil; revenueWarning = nil
        lastError = nil; lastNotice = nil
        connectStarted = [:]
        activeActions = []
        pendingForce = false
        // 服务重启后必须重新拉慢变量；否则这里刚清空、那边 5 分钟时间戳
        // 还没到，商品数和 AI 开关会假显示为 0/关闭。
        slowStamp = .distantPast
        // 会话同理：服务重启会清掉服务端的流控冷却表，客户端也要立刻重拉。
        sessionsStamp = .distantPast
        chatBlockedUntil = [:]
        cachedItemTitles = [:]
        cachedRules = []
    }


    func refreshLogs() async {
        await refreshOrdersAndLogs()
    }

    /// 只重拉账号表。开关类写操作只影响一个布尔，没必要拉全量。
    func refreshAccounts() async {
        do {
            accounts = try await Api.shared.accounts()
            lastSuccessfulUpdate = Date()
        } catch {
            // 这一步失败不算致命：乐观值已经显示出来了，下一轮轮询会纠偏。
            lastError = "账号状态没刷新：\(error.localizedDescription)"
        }
        uiRevision &+= 1
        dirty()
    }

    /// 补发/改状态后订单和日志要一起重拉。只刷日志会让订单状态和
    /// 逐单元进度停在上一轮，界面无法证明这次补发到底成没成。
    @discardableResult
    func refreshOrdersAndLogs() async -> String? {
        var problems: [String] = []
        async let orderT = Api.shared.orders()
        async let logT = Api.shared.shipLogs()
        do {
            orders = try await orderT
        } catch {
            problems.append("订单：\(error.localizedDescription)")
        }
        do {
            logs = try await logT
        } catch {
            problems.append("发货日志：\(error.localizedDescription)")
        }
        rebuildShipState()
        let message = problems.isEmpty ? nil : "刷新失败：" + problems.joined(separator: "；")
        if let message { lastError = message }
        uiRevision &+= 1
        dirty()
        return message
    }

    // MARK: 启停

    func autoStart() {
        guard !busy else { return }
        busy = true
        busyText = "正在启动服务…"
        dirty()
        Task {
            let r = await Task.detached(priority: .userInitiated) { Service.start() }.value
            busy = false
            busyText = ""
            serviceUp = Service.up
            lastError = r.ok ? nil : r.message
            // 启动成功立刻强制拉一遍，别让首屏空等 20 秒那一轮。
            if r.ok { reload(force: true) } else { dirty() }
        }
    }

    func toggleService() {
        guard !busy else { return }
        let was = serviceUp
        // 停服务 = 两店全部停止自动发货、停止回复。三个入口（侧栏/设置/菜单栏）
        // 都走这里，在这里统一确认，才不会漏掉某一处。
        if was {
            let ok = Confirm.ask(
                title: "停止服务？",
                detail: "停止后两店都会停止自动发货和自动回复，买家付款后没人发货，直到你重新启动服务。",
                action: "停止服务")
            guard ok else { return }
        }
        busy = true
        busyText = was ? "正在停止服务…" : "正在启动服务…"
        dirty()
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                was ? Service.stop() : Service.start()
            }.value
            busy = false
            busyText = ""
            serviceUp = Service.up
            lastError = r.ok ? nil : r.message
            // 启停都会让所有数据失效：成功就立刻重拉，失败也要重画一遍按钮状态。
            if r.ok { reload(force: true) } else { dirty() }
        }
    }

    func restartService() {
        guard !busy else { return }
        let ok = Confirm.ask(
            title: "重启服务？",
            detail: "重启期间约十几秒两店都不会自动发货或回复，启动完成后自动恢复。",
            action: "重启", destructive: false)
        guard ok else { return }
        busy = true
        busyText = "正在重启服务…"
        dirty()
        Task {
            let r = await Task.detached(priority: .userInitiated) { Service.restart() }.value
            busy = false
            busyText = ""
            serviceUp = Service.up
            lastError = r.ok ? nil : r.message
            if r.ok { reload(force: true) } else { dirty() }
        }
    }

    // MARK: 店铺

    var onlineCount: Int { accounts.filter { $0.isOnline }.count }

    /// 只在刚启动/刚点重连后的 45 秒内显示“连接中”，不能因为本次运行
    /// 从未在线过就永久把“已断开”伪装成“连接中”。
    func connecting(_ a: Account) -> Bool {
        guard !a.isOnline, a.enabled ?? true else { return false }
        let since = connectStarted[a.id] ?? appStartedAt
        return Date().timeIntervalSince(since) < 45
    }

    func stateText(_ a: Account) -> String {
        if connecting(a) { return "连接中…" }
        return a.link.text
    }

    /// 账号显示名：优先后台备注（remark）→ 账号名（username）→ ID 尾号。
    /// 不内置任何店名，账号完全跟着后台 `/cookies/details` 走。
    func displayName(_ id: String) -> String {
        let key = id.trimmingCharacters(in: .whitespaces)
        if let a = accounts.first(where: { $0.id == key }) {
            let remark = (a.remark ?? "").trimmingCharacters(in: .whitespaces)
            if !remark.isEmpty { return remark }
            let user = (a.username ?? "").trimmingCharacters(in: .whitespaces)
            if !user.isEmpty { return user }
        }
        return key.isEmpty ? "未知账号" : String(key.suffix(6))
    }

    /// 表格列 / 标签用的短名：太长会撑坏布局。
    func short(_ id: String) -> String {
        let full = displayName(id)
        return full.count <= 6 ? full : String(full.prefix(6))
    }

    func name(_ id: String) -> String { displayName(id) }

    /// 单店营收只认平台实付台账。台账没覆盖今天时返回 nil，
    /// 页面显示“未同步”，绝不回退到 orders.amount 标价。
    func salesOf(_ shop: String) -> (today: Double, week: Double, month: Double)? {
        guard revenueFresh, let s = paidSales[shop] else { return nil }
        return (s.today, s.week, s.month)
    }

    // MARK: 发货

    private(set) var ship: [String: Ship] = [:]

    func rebuildShipState() {
        var byOrder: [String: [DeliveryLog]] = [:]
        for l in logs {
            guard let o = l.order_id, !o.isEmpty else { continue }
            byOrder[o, default: []].append(l)
        }
        var out: [String: Ship] = [:]
        for o in orders {
            let list = byOrder[o.order_id] ?? []
            let reason = list.map { $0.reason ?? "" }.joined(separator: " | ")
            let successCount = list.filter { $0.status == "success" }.count
            let progress = o.delivery_progress
            let expected = max(1, progress?.expected_quantity ?? Int(o.quantity ?? "") ?? 1)
            let finalized = progress?.finalized_count ?? 0
            let pendingFinalize = progress?.pending_finalize_count ?? 0

            if finalized >= expected {
                // 只有每个发货单元都 finalized 才是整单已发。
                out[o.order_id] = .sent
            } else if pendingFinalize > 0 {
                out[o.order_id] = .unconfirmed
            } else if finalized > 0 || (successCount > 0 && expected > successCount) {
                // 多件订单发了一部分，不能因为存在一条 success 就整单报绿。
                out[o.order_id] = .partial
            } else if successCount > 0 {
                // 兼容没有 delivery_progress 的旧接口/旧订单。
                out[o.order_id] = successCount >= expected ? .sent : .partial
            } else if reason.contains("商品不属于当前账号") {
                out[o.order_id] = .otherShop
            } else if reason.contains("匹配到2条") || reason.contains("匹配到多条") {
                out[o.order_id] = .multi
            } else if reason.contains("未找到匹配") {
                out[o.order_id] = .noRule
            } else if reason.contains("需人工核对") || reason.contains("未在会话中确认") {
                out[o.order_id] = .unconfirmed
            } else if list.contains(where: { $0.status == "failed" }) {
                // 除“不是本店”外的 failed 都不能静默当跳过。
                out[o.order_id] = .failed
            } else if !list.isEmpty {
                out[o.order_id] = .skipped
            } else {
                out[o.order_id] = .unknown
            }
        }
        ship = out
    }

    func shipState(_ o: Order) -> Ship { ship[o.order_id] ?? .unknown }

    /// 要我去补发的单：整单没有证明发完，且订单还没走完。
    var toFix: [Order] {
        orders.filter { shipState($0).isBad && $0.needsMe }
    }

    /// 旧账：单已终结但没有任何“整单已发完”的证据。只列给人看，不进待办。
    /// 人工核对过、确认买家已收到并结单的，可以点“我已核对”永久移出这张清单；
    /// 不做任何自动判定 —— 「看起来应该发了」正是漏发最容易被忽略的形态。
    var oldSuspects: [Order] {
        orders.filter {
            shipState($0).isBad && !$0.needsMe && !$0.isDead
                && !ackedOldOrders.contains($0.order_id)
        }
    }

    /// 已人工核对过的历史单（存 UserDefaults，重启不丢）。
    private(set) var ackedOldOrders: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "ackedOldOrders") ?? [])

    func ackOldOrder(_ orderId: String) {
        guard !ackedOldOrders.contains(orderId) else { return }
        ackedOldOrders.insert(orderId)
        UserDefaults.standard.set(Array(ackedOldOrders), forKey: "ackedOldOrders")
        uiRevision &+= 1
        dirty()
    }

    func isAckedOld(_ orderId: String) -> Bool { ackedOldOrders.contains(orderId) }

    /// 待发货里排除已经命中“要补发”的单，避免同一单在待办里算两次。
    var pendingShip: Int {
        let fixIDs = Set(toFix.map { $0.order_id })
        return orders.filter {
            $0.order_status == "pending_ship" && !fixIDs.contains($0.order_id)
        }.count
    }

    func shipDetail(_ o: Order) -> String {
        var parts: [String] = []
        if let p = o.delivery_progress {
            let expected = max(1, p.expected_quantity ?? 1)
            let pending = p.pending_finalize_count ?? 0
            let remaining = p.remaining_count ?? 0
            var line = "发货进度：\(p.finalized_count ?? 0)/\(expected) 已发"
            if pending > 0 { line += "，\(pending) 个待补确认" }
            if remaining > 0 { line += "，\(remaining) 个未发" }
            parts.append(line)
        }
        let mine = logs.filter { $0.order_id == o.order_id }
        if mine.isEmpty {
            parts.append("这单没有发货记录")
        } else {
            parts.append(mine.prefix(50).map { l in
                "\(Clock.utcToLocal(l.created_at ?? ""))  \(l.status ?? "")  \(l.reason ?? "")"
            }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }

    // MARK: 会话

    /// 人工标过的「已读」。key = "shop|chat_id"，value = 当时那条摘要的指纹。
    /// 只对最后那一条消息有效：买家再发新消息，指纹变了，提示自动回来。
    /// 存 UserDefaults，重启不丢。
    private(set) var chatReadMarks: [String: String] = {
        let raw = UserDefaults.standard.dictionary(forKey: "chatReadMarks") ?? [:]
        return raw.compactMapValues { $0 as? String }
    }()

    private func chatReadKey(_ shop: String, _ chat: String) -> String { shop + "|" + chat }

    /// 这一条最后消息是否已被人工确认「不用回」。
    func isChatRead(_ shop: String, _ chat: ChatSession) -> Bool {
        chatReadMarks[chatReadKey(shop, chat.chat_id)] == chat.stamp
    }

    /// 真的还要你回：平台判定在等，且这条没被人工标已读。
    /// 界面上的红条、排序、待办数、侧栏徽标全部只认这个，不直接认 chat.waiting。
    func needsReply(_ shop: String, _ chat: ChatSession) -> Bool {
        chat.waiting && !isChatRead(shop, chat)
    }

    /// 手动确认已读 / 撤销。不做任何自动判定 —— 点一下才算数。
    func setChatRead(_ shop: String, _ chat: ChatSession, _ on: Bool) {
        let k = chatReadKey(shop, chat.chat_id)
        if on {
            chatReadMarks[k] = chat.stamp
        } else {
            guard chatReadMarks[k] != nil else { return }
            chatReadMarks.removeValue(forKey: k)
        }
        pruneChatReadMarks()
        UserDefaults.standard.set(chatReadMarks, forKey: "chatReadMarks")
        uiRevision &+= 1
        dirty()
    }

    /// 台账别无限长：攒到一定量只留还在会话列表里的那些。
    private func pruneChatReadMarks() {
        guard chatReadMarks.count > 800 else { return }
        let alive = Set(sessions.flatMap { shop, list in
            list.map { chatReadKey(shop, $0.chat_id) }
        })
        guard !alive.isEmpty else { return }
        chatReadMarks = chatReadMarks.filter { alive.contains($0.key) }
    }

    /// 等你回复的排最前（等得越久越靠上），其余按最新消息。
    var chatList: [(shop: String, chat: ChatSession)] {
        let all = sessions.flatMap { shop, list in
            list.map { (shop: shop, chat: $0) }
        }.filter { $0.chat.worth }
        let wait = all.filter { needsReply($0.shop, $0.chat) }.sorted { $0.chat.minutes > $1.chat.minutes }
        let rest = all.filter { !needsReply($0.shop, $0.chat) }.sorted { $0.chat.minutes < $1.chat.minutes }
        return wait + rest
    }

    /// 不再按“3 天”硬砍等待中的买家；真的需要归档应由明确操作完成，
    /// 不能因为等得久就从待办里消失。
    var waitingChats: [(shop: String, chat: ChatSession)] {
        chatList.filter { needsReply($0.shop, $0.chat) }
    }

    func waiting(_ shop: String) -> Int {
        waitingChats.filter { $0.shop == shop }.count
    }

    var longestWait: Int { waitingChats.map { $0.chat.minutes }.max() ?? 0 }

    var todoCount: Int { toFix.count + pendingShip + waitingChats.count }

    func items(_ shop: String) -> Int { itemCount[shop] ?? 0 }

    func rules(_ shop: String) -> (Int, Int) { ruleCount[shop] ?? (0, 0) }

    /// 四个开关共用一套乐观显示：点下立刻变，请求回来再对齐服务端真值。
    func switchOn(_ shop: String, _ kind: String) -> Bool {
        if let pending = switchOverrides["\(kind):\(shop)"] { return pending }
        switch kind {
        case "ai": return ai[shop]?.ai_enabled ?? false
        case "confirm": return accounts.first { $0.id == shop }?.auto_confirm ?? true
        case "comment": return accounts.first { $0.id == shop }?.auto_comment ?? false
        case "flower": return accounts.first { $0.id == shop }?.auto_red_flower ?? false
        default: return false
        }
    }

    func aiOn(_ shop: String) -> Bool { switchOn(shop, "ai") }

    // MARK: 写

    func actionBusy(_ key: String) -> Bool {
        activeActions.contains(key)
    }

    /// 同一订单/账号/开关只允许一个在途请求，防止双击造成重复发货或重复写配置。
    @discardableResult
    func beginAction(_ key: String) -> Bool {
        guard !activeActions.contains(key) else {
            uiRevision &+= 1
            dirty()
            return false
        }
        activeActions.insert(key)
        uiRevision &+= 1
        dirty()
        return true
    }

    func endAction(_ key: String) {
        activeActions.remove(key)
        uiRevision &+= 1
        dirty()
    }

    private func failed(_ message: String) {
        reportActionError(message)
    }

    /// 供会话页等自己管理错误态的模块上报，保证即使切走页面也不是静默失败。
    func reportActionError(_ message: String) {
        lastError = message
        lastNotice = nil
        uiRevision &+= 1
        dirty()
    }

    func showNotice(_ text: String, seconds: TimeInterval = 8) {
        let token = UUID()
        noticeToken = token
        lastNotice = text
        uiRevision &+= 1
        dirty()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.noticeToken == token else { return }
            self.lastNotice = nil
            self.uiRevision &+= 1
            self.dirty()
        }
    }

    func clearNotice() {
        noticeToken = UUID()
        guard lastNotice != nil else { return }
        lastNotice = nil
        uiRevision &+= 1
        dirty()
    }

    func setEnabled(_ shop: String, _ on: Bool) async {
        let key = "enable:\(shop)"
        guard beginAction(key) else { return }
        defer { endAction(key) }
        do {
            try await Api.shared.enable(shop, on)
            if on { connectStarted[shop] = Date() }
            // 先按目标值改一行，不等整表回来 —— 按钮点下就该变。
            if let i = accounts.firstIndex(where: { $0.id == shop }) {
                accounts[i] = accounts[i].withEnabled(on)
            }
            uiRevision &+= 1
            dirty()
            await refreshAccounts()
            lastError = nil
            showNotice(on ? "账号已启用" : "账号已停用", seconds: 3)
        } catch {
            failed(error.localizedDescription)
        }
    }

    func reconnect(_ shop: String) async {
        let key = "reconnect:\(shop)"
        guard beginAction(key) else { return }
        defer { endAction(key) }

        // 重连不是“启用”。停用账号必须由用户明确点“启用”，
        // 不能因为点了一次重连就悄悄开始收消息。
        guard accounts.first(where: { $0.id == shop })?.enabled ?? true else {
            failed("账号已停用，重连不会自动启用；请先点“启用”。")
            return
        }

        connectStarted[shop] = Date()
        var disabled = false
        do {
            try await Api.shared.enable(shop, false)
            disabled = true
            try await Task.sleep(nanoseconds: 1_200_000_000)
            try await Api.shared.enable(shop, true)
            disabled = false
            lastError = nil
            connectStarted[shop] = Date()
            // 重连后状态要马上反映：先把这一行标成「连接中」，再强制拉一次。
            if let i = accounts.firstIndex(where: { $0.id == shop }) {
                accounts[i] = accounts[i].withEnabled(true)
            }
            uiRevision &+= 1
            dirty()
            reload(force: true)
        } catch {
            var detail = error.localizedDescription
            if disabled {
                do {
                    try await Api.shared.enable(shop, true)
                    detail += "；已自动恢复启用"
                } catch {
                    detail += "；恢复启用也失败，请到账号页手动开启"
                }
            }
            failed("重连失败：" + detail)
            reload(force: true)
        }
    }

    func toggle(_ shop: String, _ kind: String, _ on: Bool) async {
        let key = "toggle:\(shop):\(kind)"
        guard beginAction(key) else { return }
        // 四个开关统一乐观显示：点下立即变，不让它先弹回旧值。
        // 以前只有 AI 这么做，另外三个点完会闪一下回到原状，看着像没生效。
        switchOverrides["\(kind):\(shop)"] = on
        uiRevision &+= 1
        dirty()
        defer { endAction(key) }
        do {
            switch kind {
            case "confirm": try await Api.shared.autoConfirm(shop, on)
            case "comment": try await Api.shared.autoComment(shop, on)
            case "flower": try await Api.shared.autoFlower(shop, on)
            case "ai":
                try await Api.shared.aiOn(shop, on)
                // 写入后立即回读，确认服务端真的保存成目标值。
                let saved = try await Api.shared.ai(shop)
                ai[shop] = saved
                if (saved.ai_enabled ?? false) != on {
                    switchOverrides["\(kind):\(shop)"] = nil
                    throw NetError.bad("AI 开关没有按预期保存")
                }
            default: return
            }
            // 开关类写操作只改一个布尔，重新拉一遍账号表就知道服务端真值了；
            // 这一步很快，换掉的是一次「等 20 秒轮询」的盲等。
            await refreshAccounts()
            switchOverrides["\(kind):\(shop)"] = nil
            lastError = nil
            showNotice(kind == "ai" ? "AI 开关已保存" : "设置已保存", seconds: 3)
            uiRevision &+= 1
            dirty()
        } catch {
            switchOverrides["\(kind):\(shop)"] = nil
            failed(error.localizedDescription)
        }
    }

    func resend(_ o: Order) async -> Bool {
        let key = "resend:\(o.order_id)"
        guard beginAction(key) else { return false }
        defer { endAction(key) }
        do {
            let outcome = try await Api.shared.resend(o.order_id)
            let refreshError = await refreshOrdersAndLogs()
            // 不能只看接口 success：服务端可能处理成功但仍有单元失败，
            // 必须 delivered + fully_delivered + 0 remaining/failed 同时成立。
            if outcome.ok, refreshError == nil {
                lastError = nil
                showNotice(outcome.message, seconds: 15)
            } else {
                var detail = outcome.message
                if outcome.remaining > 0 { detail += "；仍剩 \(outcome.remaining) 个单元未完成" }
                if outcome.failed > 0 { detail += "；\(outcome.failed) 个单元失败" }
                if let refreshError { detail += "；\(refreshError)" }
                lastError = detail
                lastNotice = nil
            }
            return outcome.ok && refreshError == nil
        } catch {
            failed(error.localizedDescription)
            return false
        }
    }

    func send(_ shop: String, _ chatId: String, to: String, text: String) async -> String? {
        do {
            let err = try await Api.shared.send(shop, chatId, to: to, text: text)
            return err.isEmpty ? nil : err
        } catch { return error.localizedDescription }
    }

}
