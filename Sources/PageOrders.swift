import AppKit

/// 订单页。上面筛选，中间表格，点一行右边开详情。
@MainActor
final class PageOrders: Page {

    static var keyword = ""
    /// nil = 全部；否则是后台返回的账号 ID（cookie_id），不写死序号。
    static var shop: String?
    static var filter = "all"    // all fault old pending shipped completed cancelled
    static var picked: String?

    let store: Store
    let view: NSView = Flipped()
    var sig = ""

    private let bar = NSView()
    private let table = Scroller(pad: 0, gap: 0)
    private let panel = NSView()
    private var panelW: NSLayoutConstraint!

    // 列宽：商品列吃掉剩下的
    private let colTime: CGFloat = 78
    private let colShop: CGFloat = 28
    private let colBuyer: CGFloat = 76
    private let colMoney: CGFloat = 62
    private let colState: CGFloat = 56
    private let colShip: CGFloat = 78
    private let colGap: CGFloat = 8

    init(store: Store) {
        self.store = store
        view.translatesAutoresizingMaskIntoConstraints = false

        bar.translatesAutoresizingMaskIntoConstraints = false
        table.translatesAutoresizingMaskIntoConstraints = false

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.backgroundColor = T.p.card.cgColor
        panel.layer?.cornerRadius = T.S.radius
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = T.p.sep.cgColor
        panel.layer?.masksToBounds = true

        view.addSubview(bar)
        view.addSubview(table)
        view.addSubview(panel)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: T.S.page),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -T.S.page),
            bar.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            bar.heightAnchor.constraint(equalToConstant: 30),

            table.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: T.S.page - 4),
            table.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),

            panel.topAnchor.constraint(equalTo: table.topAnchor),
            panel.bottomAnchor.constraint(equalTo: table.bottomAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -T.S.page),
        ])
        panelW = panel.widthAnchor.constraint(equalToConstant: 0)
        panelW.isActive = true
        table.trailingAnchor.constraint(equalTo: panel.leadingAnchor, constant: -8).isActive = true
    }

    func signature() -> String {
        let ordersDigest = store.orders.map {
            let p = $0.delivery_progress
            return "\($0.order_id)|\($0.order_status ?? "")|\($0.amount ?? "")|\($0.item_id ?? "")|\(p?.finalized_count ?? -1)|\(p?.pending_finalize_count ?? -1)|\(p?.remaining_count ?? -1)"
        }.joined(separator: "\n")
        let logsDigest = store.logs.map {
            "\($0.id ?? 0)|\($0.order_id ?? "")|\($0.status ?? "")|\($0.reason ?? "")"
        }.joined(separator: "\n")
        return "\(store.serviceUp)|\(store.loading)|\(ordersDigest)|\(logsDigest)|\(store.lastError ?? "")|\(store.lastNotice ?? "")|\(store.uiRevision)|\(PageOrders.keyword)|\(PageOrders.shop ?? "")|\(PageOrders.filter)|\(PageOrders.picked ?? "")"
    }

    func build() {
        store.rebuildShipState()
        panel.layer?.backgroundColor = T.p.card.cgColor
        panel.layer?.borderColor = T.p.sep.cgColor
        guard store.serviceUp else {
            panelW.constant = 0
            table.show([Blank.card("服务没开着", "订单都在本机服务里，服务停了这里就是空的。",
                                   buttons: [B("启动服务", "power", style: .accent, action: { [weak self] in
                                       self?.store.toggleService()
                                   })])])
            buildBar()
            return
        }
        buildBar()
        if store.loading && store.orders.isEmpty {
            panelW.constant = 0
            table.show([Blank.skeleton([0.3, 1, 1, 0.8])])
            return
        }
        buildTable()
        buildPanel()
    }

    // MARK: 顶部筛选

    private func buildBar() {
        bar.subviews.forEach { $0.removeFromSuperview() }

        let shopTitles = ["全部"] + store.accounts.map { store.short($0.id) }
        let shopIndex = PageOrders.shop.flatMap { id in
            store.accounts.firstIndex { $0.id == id }
        }.map { $0 + 1 } ?? 0
        // 顶栏还要放状态筛选和导出按钮，账号标签栏上限收窄一点，账号多了内部滚动。
        let shopTabs = Tabs(shopTitles, index: shopIndex, maxWidth: 420)
        shopTabs.onChange = { [weak self] i in
            guard let self else { return }
            PageOrders.shop = (i >= 1 && i - 1 < store.accounts.count) ? store.accounts[i - 1].id : nil
            PageOrders.picked = nil
            self.force()
        }

        let items: [(String, String)] = [
            ("all", "全部"), ("fault", "要补发"), ("old", "旧账"),
            ("pending", "待发货"), ("shipped", "已发货"), ("completed", "已完成"),
        ]
        let stateTabs = Tabs(items.map { $0.1 },
                             index: items.firstIndex { $0.0 == PageOrders.filter } ?? 0)
        stateTabs.onChange = { [weak self] i in
            guard i >= 0, i < items.count else { return }
            PageOrders.filter = items[i].0
            PageOrders.picked = nil
            self?.force()
        }

        let export = B("导出", "square.and.arrow.up", style: .plain, size: 11, height: 26,
                       action: { [weak self] in self?.exportCSV() })

        let row = S.h([shopTabs, stateTabs, Flex(), export], 8)
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
    }

    private func force() {
        sig = ""
        build()
    }

    // MARK: 表格

    private func filtered() -> [Order] {
        let q = PageOrders.keyword.trimmingCharacters(in: .whitespaces).lowercased()
        return store.orders.filter { o in
            // 选了某个账号才按归属过滤；账号列表来自后台，数量不固定。
            if let shop = PageOrders.shop, o.cookie_id != shop { return false }

            switch PageOrders.filter {
            case "fault":
                guard store.shipState(o).isBad, o.needsMe else { return false }
            case "old":
                guard store.shipState(o).isBad, !o.needsMe else { return false }
            case "pending":
                guard o.order_status == "pending_ship" else { return false }
            case "all":
                break
            default:
                guard o.order_status == PageOrders.filter else { return false }
            }

            if !q.isEmpty {
                let hay = ((store.itemTitle[o.item_id ?? ""] ?? "") + (o.buyer_nick ?? "") + o.order_id).lowercased()
                guard hay.contains(q) else { return false }
            }
            return true
        }
    }

    private func buildTable() {
        let list = filtered()
        var rows: [NSView] = []

        let fix = list.filter { store.shipState($0).isBad && $0.needsMe }.count
        let caption = L("共 \(list.count) 单" + (fix > 0 ? " · \(fix) 单要补发" : ""), 10.5, .regular, color: T.p.text2)
        let capHolder = NSView()
        capHolder.translatesAutoresizingMaskIntoConstraints = false
        capHolder.addSubview(caption)
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: capHolder.leadingAnchor, constant: 10),
            caption.topAnchor.constraint(equalTo: capHolder.topAnchor, constant: 2),
            caption.bottomAnchor.constraint(equalTo: capHolder.bottomAnchor, constant: -6),
        ])
        rows.append(capHolder)
        if let e = store.lastError, !list.isEmpty {
            let retry = B("重试", "arrow.clockwise", style: .plain, size: 10.5, height: 24,
                          action: { [weak self] in self?.store.reload(force: true) })
            rows.append(Card([S.h([Dot(T.p.warn, 6), L(e, 10.5, .regular, color: T.p.warn), Flex(), retry], 8)],
                             pad: 10, gap: 0))
        }
        if let notice = store.lastNotice, !notice.isEmpty {
            let close = B("知道了", nil, style: .plain, size: 10.5, height: 24,
                          action: { [weak self] in self?.store.clearNotice() })
            rows.append(Card([S.h([Dot(T.p.ok, 6), L(notice, 10.5, .regular, color: T.p.ok), Flex(), close], 8)],
                             pad: 10, gap: 0))
        }

        if list.isEmpty {
            let failed = store.orders.isEmpty && store.lastError != nil
            let title = failed ? "订单没取到" : (store.orders.isEmpty ? "还没有订单" : "这个筛选下没有单")
            let detail = failed
                ? (store.lastError ?? "刷新重试。")
                : (store.orders.isEmpty ? "服务起来后会自动同步历史订单。" : "换个筛选看看。")
            let buttons = (store.orders.isEmpty || failed)
                ? [B("刷新", "arrow.clockwise", style: .plain, action: { [weak self] in
                    self?.store.reload(force: true)
                })]
                : [B("看全部", nil, style: .plain, action: { [weak self] in
                    PageOrders.filter = "all"
                    self?.force()
                })]
            rows.append(Blank.card(title, detail, buttons: buttons))
        } else {
            let card = Card([], pad: 0, gap: 0)
            var inner: [NSView] = [headerRow()]
            inner.append(Line())
            for o in list {
                inner.append(row(o))
                inner.append(Line(T.p.sep.withAlphaComponent(0.5)))
            }
            card.body.spacing = 0
            for v in inner { card.add(v) }
            rows.append(card)
        }
        table.show(rows, gap: 0)
    }

    private var spec: TableRow.Spec {
        var s = TableRow.Spec()
        s.time = colTime
        s.shop = colShop
        s.buyer = colBuyer
        s.money = colMoney
        s.state = colState
        s.ship = colShip
        s.gap = colGap
        s.inset = 12
        return s
    }

    /// 表头也是 TableRow，列宽完全一致 —— 这才是真正的对齐
    private func headerRow() -> NSView {
        let head = TableRow(spec, height: 26)
        head.fill([
            Cell(L("时间", 10, .regular, color: T.p.text2)),
            Cell(L("店", 10, .regular, color: T.p.text2)),
            Cell(L("商品", 10, .regular, color: T.p.text2)),
            Cell(L("买家", 10, .regular, color: T.p.text2)),
            Cell(moneyText("标价", 10, T.p.text2), right: true),
            Cell(L("状态", 10, .regular, color: T.p.text2)),
            Cell(L("发货", 10, .regular, color: T.p.text2)),
        ])
        return head
    }

    private func moneyText(_ s: String, _ size: CGFloat, _ color: NSColor) -> NSTextField {
        let l = L(s, size, .regular, color: color, mono: true)
        l.alignment = .right
        return l
    }

    private func row(_ o: Order) -> NSView {
        let p = T.p
        let ship = store.shipState(o)
        let live = o.needsMe
        let selected = PageOrders.picked == o.order_id

        let time = L(o.when, 10.5, .regular, color: p.text2, mono: true)
        let shop = L(store.short(o.cookie_id ?? ""), 10.5, .regular, color: p.text2)

        let titleText = store.itemTitle[o.item_id ?? ""] ?? "商品已不在库里"
        let title = L(titleText, 11.5, .regular, color: o.isDead ? p.text2 : p.text)
        if o.isDead {
            title.attributedStringValue = NSAttributedString(string: titleText, attributes: [
                .font: T.font(11.5), .foregroundColor: p.text2,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: p.text2,
            ])
        }

        let buyer = L(o.buyer_nick ?? "—", 10.5, .regular, color: p.text2)

        let moneyText = L(String(format: "¥%.2f", o.amountValue), 11.5,
                          .regular, color: (ship.isBad && live) ? p.warn : p.text, mono: true)
        moneyText.alignment = .right

        let (sc, sb) = Look.statusColor(o.order_status ?? "")
        let stateTag = Tag(o.statusText, sc, sb, size: 10)

        let (dc, db) = Look.shipColor(ship, live: live)
        let shipTag = Tag(ship.text, dc, db, size: 10)

        let rowView = TableRow(spec)
        rowView.fill([
            Cell(time), Cell(shop), Cell(title), Cell(buyer),
            Cell(moneyText, right: true), Cell(stateTag), Cell(shipTag),
        ])
        rowView.setSelected(selected)
        if ship.isBad && live { rowView.accentBar = p.warn }
        rowView.onTap = { [weak self] in
            PageOrders.picked = (PageOrders.picked == o.order_id) ? nil : o.order_id
            self?.force()
        }
        return rowView
    }


    // MARK: 右侧详情

    private func buildPanel() {
        panel.subviews.forEach { $0.removeFromSuperview() }
        guard let o = store.orders.first(where: { $0.order_id == PageOrders.picked }) else {
            panelW.constant = 0
            return
        }
        panelW.constant = 272

        let p = T.p
        let inner = Scroller(pad: 12, gap: 9)
        panel.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            inner.topAnchor.constraint(equalTo: panel.topAnchor),
            inner.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])

        let ship = store.shipState(o)
        var rows: [NSView] = []

        let close = B("", "xmark", style: .plain, size: 10, height: 24, width: 24, a11y: "关闭详情",
                      action: { [weak self] in
                          PageOrders.picked = nil
                          self?.force()
                      })
        rows.append(S.h([L("订单详情", 12.5, .semibold), Flex(), close], 6))

        func kv(_ k: String, _ v: String, mono: Bool = false) -> NSView {
            let key = L(k, 10.5, .regular, color: p.text2)
            let val = L(v, 11, .regular, color: p.text, mono: mono)
            val.cell?.wraps = true
            val.maximumNumberOfLines = 3
            return S.h([W.fix(key, 46), val], 6, align: .top)
        }
        rows.append(kv("时间", o.when, mono: true))
        rows.append(kv("店铺", store.short(o.cookie_id ?? "") + " · " + store.name(o.cookie_id ?? "")))
        rows.append(kv("商品", store.itemTitle[o.item_id ?? ""] ?? "—"))
        rows.append(kv("买家", o.buyer_nick ?? "—"))
        rows.append(kv("标价", String(format: "¥%.2f（不是实付）", o.amountValue), mono: true))
        rows.append(kv("状态", o.statusText))
        rows.append(kv("单号", o.order_id, mono: true))
        rows.append(Line())

        rows.append(L("发货记录", 11.5, .semibold))
        let note = L.wrap(store.shipDetail(o), 10, color: p.text2, width: 240)
        note.font = T.mono(10)
        let noteBox = NSView()
        noteBox.wantsLayer = true
        noteBox.layer?.backgroundColor = p.bg.cgColor
        noteBox.layer?.cornerRadius = 6
        noteBox.translatesAutoresizingMaskIntoConstraints = false
        noteBox.addSubview(note)
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: noteBox.leadingAnchor, constant: 8),
            note.trailingAnchor.constraint(equalTo: noteBox.trailingAnchor, constant: -8),
            note.topAnchor.constraint(equalTo: noteBox.topAnchor, constant: 7),
            note.bottomAnchor.constraint(equalTo: noteBox.bottomAnchor, constant: -7),
        ])
        rows.append(noteBox)

        if ship.isBad && o.needsMe {
            rows.append(L.wrap("整单还没有证明发完（可能部分成功、待确认或没有记录）—— 买家可能收不到，补一下。",
                               10.5, color: p.warn, width: 240))
            let resendBtn = B(store.actionBusy("resend:\(o.order_id)") ? "正在补发…" : "补发到买家会话",
                              "paperplane", style: .accent, size: 11,
                              action: { [weak self] in self?.resend(o) })
            resendBtn.isEnabled = !store.actionBusy("resend:\(o.order_id)")
            rows.append(resendBtn)
        } else if ship.isBad && !o.needsMe {
            // 早期订单（发货单元追踪上线前）本来就没有逐单元记录，
            // 一直挂着会天天报「旧账」。核对过就点掉，存 UserDefaults，重启不丢。
            if store.isAckedOld(o.order_id) {
                rows.append(L("这单你已核对过，不再提示。", 10.5, .regular, color: p.text2))
            } else {
                rows.append(L.wrap("单已完结，但日志里没有“整单发完”的证据（多半是逐单元追踪上线前的早期单）。核对买家确实收到后，点下面这条把它移出旧账。",
                                   10.5, color: p.text2, width: 240))
                let ack = B("我已核对，别再提示", "checkmark.circle", style: .plain, size: 11,
                            action: { [weak self] in
                                self?.store.ackOldOrder(o.order_id)
                                self?.force()
                            })
                rows.append(ack)
            }
            let resendBtn = B(store.actionBusy("resend:\(o.order_id)") ? "正在补发…" : "还是补发一次",
                              nil, style: .plain, size: 11,
                              action: { [weak self] in
                                  // 旧账单可能已经发过，再发一次买家会收到两份。必须确认。
                                  let ok = Confirm.ask(
                                      title: "再补发一次这单？",
                                      detail: "这单已经结束，日志里没有“整单发完”的记录。如果买家其实已经收到货，再发一次会变成重复发货。确认买家没收到再点。",
                                      action: "还是补发")
                                  guard ok else { return }
                                  self?.resend(o)
                              })
            resendBtn.isEnabled = !store.actionBusy("resend:\(o.order_id)")
            rows.append(resendBtn)
        } else if ship == .sent {
            rows.append(L("已经发好了，不用管。", 10.5, .regular, color: p.text2))
        } else if o.isDead {
            rows.append(L("单已取消或退款，不用补。", 10.5, .regular, color: p.text2))
        }

        rows.append(Line())
        let copy = B("复制单号", "doc.on.doc", style: .plain, size: 10.5, height: 24, action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(o.order_id, forType: .string)
        })
        let open = B("打开旧版网页后台", "safari", style: .plain, size: 10.5, height: 24, action: {
            if let u = URL(string: Cfg.base) { NSWorkspace.shared.open(u) }
        })
        rows.append(S.h([copy, open, Flex()], 6))

        inner.show(rows, gap: 9)
    }

    private func resend(_ o: Order) {
        Task { _ = await store.resend(o) }
    }

    // MARK: 导出

    private func exportCSV() {
        let list = filtered()
        var lines = ["时间,店铺,商品,买家,库内标价(非实付),状态,发货,单号"]
        lines += list.map { o in
            let cols = [
                o.when, store.short(o.cookie_id ?? ""),
                store.itemTitle[o.item_id ?? ""] ?? "", o.buyer_nick ?? "",
                String(format: "%.2f", o.amountValue), o.statusText,
                store.shipState(o).text, o.order_id,
            ]
            return cols.map(csvCell).joined(separator: ",")
        }
        let text = "\u{FEFF}" + lines.joined(separator: "\n")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "订单-\(Clock.today()).csv"
        panel.title = "导出订单"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            store.showNotice("订单已导出：\(url.lastPathComponent)")
        } catch {
            let alert = NSAlert()
            alert.messageText = "导出失败"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// 防 CSV 公式注入，同时正确转义双引号。
    private func csvCell(_ raw: String) -> String {
        var value = raw
        if let first = value.first, "=+-@".contains(first) {
            value = "'" + value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
