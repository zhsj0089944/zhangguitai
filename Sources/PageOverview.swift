import AppKit

/// 页面之间的跳转。总览的待办点一下能直接跳到订单/会话并带上筛选。
@MainActor
enum Jump {
    static var to: ((PageKind, String?) -> Void)?
}

// MARK: - 总览

@MainActor
final class PageOverview: ScrollPage {

    /// 只随「时间」变化的文字。放进 signature 会导致整页每分钟重建，
    /// 滚动位置被重置；改成原地改字。
    private let ticking = Ticking()

    override func signature() -> String {
        let acc = store.accounts.map { "\($0.id)\($0.enabled ?? true)\($0.isOnline)\(store.stateText($0))" }.joined()
        let money = store.accounts.map { a in
            if let v = store.salesOf(a.id) {
                return "\(a.id):\(v.today),\(v.week),\(v.month)"
            }
            return "\(a.id):未同步"
        }.joined()
        let counts = store.accounts.map {
            "\($0.id):\(store.items($0.id)):\(store.rules($0.id).0)/\(store.rules($0.id).1):\(store.waiting($0.id))"
        }.joined()
        let logDigest = store.logs.map {
            "\($0.id ?? 0)|\($0.order_id ?? "")|\($0.status ?? "")|\($0.reason ?? "")"
        }.joined(separator: "\n")
        // 不再含 minuteBucket：它每分钟变一次，逼着整页重建。
        return "\(store.serviceUp)|\(store.loading)|\(store.refreshing)|\(store.revenueRefreshing)|\(acc)|\(money)|\(store.revenueFresh)|\(store.revenueAvailable)|\(store.revenueWarning ?? "")|\(counts)|\(store.orders.count)|\(store.orders.map { $0.order_id + ($0.order_status ?? "") }.joined())|\(logDigest)|\(store.waitingChats.count)|\(store.oldSuspects.count)|\(store.lastNotice ?? "")|\(store.lastError ?? "")|\(store.uiRevision)"
    }

    func tick() { ticking.tick() }

    override func build() {
        ticking.reset()
        guard requireService() else { return }
        if store.loading && store.accounts.isEmpty {
            scroll.show([Blank.skeleton([0.5, 1, 0.7])])
            return
        }
        guard !store.accounts.isEmpty else {
            let msg = store.lastError ?? "服务起来了但没返回账号。"
            scroll.show([Blank.card("读不到店铺", msg,
                                    buttons: [B("重试", "arrow.clockwise", style: .plain, action: { [weak self] in
                                        self?.store.reload(force: true)
                                    })])])
            return
        }

        var rows: [NSView] = []
        if let error = store.lastError {
            rows.append(warningCard(error))
        }
        if store.revenueAvailable, let revenue = store.revenueWarning {
            rows.append(revenueCard(revenue))
        }
        if let notice = store.lastNotice {
            rows.append(noticeCard(notice))
        }
        // 账号卡片排布：账号少时一行排完，多了按网格换行。
        // 原来是一行 fillEqually 排所有账号 —— 4 个账号时每张卡只剩 1/4 宽，
        // 营收、规则数、状态标签全挤成一团。账号数量现在跟着后台走，必须能换行。
        let perRow = store.accounts.count <= 2 ? max(1, store.accounts.count) : 3
        var cursor = 0
        while cursor < store.accounts.count {
            let end = min(cursor + perRow, store.accounts.count)
            let slice = Array(store.accounts[cursor..<end])

            let line = NSStackView()
            line.orientation = .horizontal
            line.spacing = T.S.gap
            line.distribution = .fillEqually
            line.alignment = .top
            line.translatesAutoresizingMaskIntoConstraints = false

            var lineCards: [NSView] = []
            for a in slice {
                let c = shopCard(a)
                line.addArrangedSubview(c)
                lineCards.append(c)
            }
            // 最后一行不满时用空占位撑住，避免剩下那张卡横向拉满。
            for _ in slice.count..<perRow {
                let filler = NSView()
                filler.translatesAutoresizingMaskIntoConstraints = false
                line.addArrangedSubview(filler)
            }
            if let first = lineCards.first {
                for c in lineCards.dropFirst() {
                    c.heightAnchor.constraint(equalTo: first.heightAnchor).isActive = true
                }
            }
            rows.append(line)
            cursor = end
        }
        rows.append(todoCard())
        scroll.show(rows)
    }

    private func warningCard(_ text: String) -> NSView {
        let p = T.p
        let retry = B("重试", "arrow.clockwise", style: .plain, size: 10.5, height: 24,
                      action: { [weak self] in self?.store.reload(force: true) })
        return Card([
            S.h([Dot(p.warn, 6), L(text, 11, .regular, color: p.warn), Flex(), retry], 8),
        ], pad: 12, gap: 0)
    }

    /// 营收未同步时给一条能点的：直接去平台重拉台账。
    /// 光提示「未同步」而不给办法，等于让你自己去跑脚本。
    private func revenueCard(_ text: String) -> NSView {
        let p = T.p
        let busy = store.revenueRefreshing
        let action = B(busy ? "正在拉取…" : "立刻同步",
                       busy ? nil : "arrow.clockwise", style: .plain, size: 10.5, height: 24,
                       action: { [weak self] in
                           Task { await self?.store.refreshRevenue() }
                       })
        action.isEnabled = !busy
        return Card([
            S.h([Dot(p.warn, 6),
                 L(text + (store.revenueUpdatedAt.map { "（数据截至 \($0)）" } ?? ""),
                   11, .regular, color: p.warn),
                 Flex(), action], 8),
        ], pad: 12, gap: 0)
    }

    private func noticeCard(_ text: String) -> NSView {
        let p = T.p
        let close = B("知道了", nil, style: .plain, size: 10.5, height: 24,
                      action: { [weak self] in self?.store.clearNotice() })
        return Card([
            S.h([Dot(p.ok, 6), L(text, 11, .regular, color: p.ok), Flex(), close], 8),
        ], pad: 12, gap: 0)
    }

    private func shopCard(_ a: Account) -> NSView {
        let p = T.p
        let link = a.link
        let online = a.isOnline
        let busyConnecting = store.connecting(a)

        let dot = Dot(online ? p.ok : (busyConnecting ? p.text2 : Look.linkColor(link)), 8)
        let name = L(store.name(a.id), 14.5, .semibold)
        let tag = Tag(store.stateText(a),
                      Look.linkColor(link),
                      busyConnecting ? p.text2.withAlphaComponent(0.10) : Look.linkBg(link))
        let head = S.h([dot, name, tag, Flex()], 8)

        let revenue = store.salesOf(a.id)
        let (rn, ra) = store.rules(a.id)
        let info = L("\(a.id) · \(store.items(a.id)) 件商品 · \(ra)/\(rn) 条发货规则", 10.5, .regular, color: p.text2)

        let nums = S.h([
            num("今日", revenue?.today, synced: revenue != nil),
            num("本周", revenue?.week, synced: revenue != nil),
            num("本月", revenue?.month, synced: revenue != nil),
        ], 8)
        nums.distribution = .fillEqually
        let revenueTime = store.revenueUpdatedAt.map { " · 截至 \($0)" } ?? ""

        let noteText = busyConnecting ? "正在连接，半分钟左右，这会儿不算异常" : link.hint
        let noteColor = (online || busyConnecting) ? p.text2 : Look.linkColor(link)
        let note = L(noteText, 10.5, .regular, color: noteColor)

        let reconnect = B("重连", nil, style: .plain, size: 11, height: 22, action: { [weak self] in
            Task { await self?.store.reconnect(a.id) }
        })
        let foot = S.h([note, Flex(), reconnect], 8)

        var cardRows: [NSView] = [head, info]
        // 后台没有实付营收接口时整块收起，避免别人看到一个永远「未同步」的空区。
        if store.revenueAvailable {
            cardRows.append(nums)
            if revenue != nil {
                cardRows.append(L("平台实付口径\(revenueTime)", 9.5, .regular, color: p.text2))
            }
        }
        cardRows.append(foot)
        return Card(cardRows, pad: 14, gap: 9)
    }

    private func num(_ title: String, _ v: Double?, synced: Bool) -> NSView {
        let p = T.p
        let label = L(title, 10, .regular, color: p.text2)
        let text = synced ? String(format: "¥%.2f", v ?? 0) : "未同步"
        let value = L(text, synced ? 17 : 12, .semibold,
                      // 营收是正常数字，不是告警。红色只留给「出事」，这里用中性主色。
                      color: synced ? p.text : p.text2,
                      mono: synced)
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = p.bg.cgColor
        box.layer?.cornerRadius = 6
        box.translatesAutoresizingMaskIntoConstraints = false
        let col = S.v([label, value], 2)
        box.addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 9),
            col.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -7),
            col.topAnchor.constraint(equalTo: box.topAnchor, constant: 7),
            col.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -7),
        ])
        return box
    }

    private func todoCard() -> NSView {
        let p = T.p
        let title = L("需要我处理的", 13, .semibold)
        var rows: [NSView] = [S.h([title, Flex()], 8)]

        let wait = store.waitingChats
        let fix = store.toFix
        let pending = store.pendingShip

        if wait.isEmpty && fix.isEmpty && pending == 0 {
            rows.append(S.h([Dot(p.ok, 6),
                             L("暂时没有。没有等你回的买家，也没有发货失败的单。", 11.5, .regular, color: p.text2)], 8))
        } else {
            if !wait.isEmpty {
                let row = todoRow("\(wait.count) 个买家在等你回话，最久的等了 \(Clock.ago(store.longestWait))",
                                  p.warn, "去回") { Jump.to?(.chats, "wait") }
                // 「等了 3 小时」会随时间变。以前靠整页每分钟重建来刷新，
                // 现在只原地改这一句，滚动位置不会被顶回去。
                if let label = row.textLabel {
                    ticking.add(label) { [weak store] in
                        guard let store else { return "" }
                        return "\(wait.count) 个买家在等你回话，最久的等了 \(Clock.ago(store.longestWait))"
                    }
                }
                rows.append(row.view)
            }
            if !fix.isEmpty {
                rows.append(todoRow("\(fix.count) 单货没发成，买家可能拿不到东西", p.warn, "去补") { Jump.to?(.orders, "fault") }.view)
            }
            if pending > 0 {
                rows.append(todoRow("\(pending) 单还挂着待发货", p.warn, "去看看") { Jump.to?(.orders, "pending") }.view)
            }
        }

        let old = store.oldSuspects.count
        if old > 0 {
            let row = TapRow()
            let text = L("另有 \(old) 单已完结，但没有任何“整单发完”的证据", 10.5, .regular, color: p.text2)
            row.put(S.h([text, Flex(), L("核对", 10.5, .regular, color: p.text2)], 8), left: 4, right: 4, top: 6, bottom: 6)
            row.onTap = { Jump.to?(.orders, "old") }
            rows.append(row)
        }

        return Card(rows, pad: 16, gap: 8)
    }

    /// 一行可点的待办。返回行本身和它的文字标签 —— 标签要留着后面原地改。
    struct TodoRow {
        let view: NSView
        let textLabel: NSTextField?
    }

    private func todoRow(_ text: String, _ color: NSColor, _ action: String, tap: @escaping () -> Void) -> TodoRow {
        let row = TapRow(corner: 6)
        let label = L(text, 12)
        let go = L(action + " ›", 11.5, .medium, color: T.p.accent)
        row.put(S.h([Dot(color, 6), label, Flex(), go], 8), left: 4, right: 4, top: 8, bottom: 8)
        row.onTap = tap
        return TodoRow(view: row, textLabel: label)
    }
}

/// 弹性占位
final class Flex: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
}
