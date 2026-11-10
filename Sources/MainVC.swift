import AppKit

enum PageKind: Int, CaseIterable {
    case overview, orders, chats, shops, settings

    var title: String {
        switch self {
        case .overview: return "总览"
        case .orders: return "订单"
        case .chats: return "会话"
        case .shops: return "账号"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "house"
        case .orders: return "shippingbox"
        case .chats: return "bubble.left.and.bubble.right"
        case .shops: return "person.crop.circle"
        case .settings: return "gearshape"
        }
    }
}

/// 切外观：换整套配色并让窗口跟着变
@MainActor
enum AppSkin {
    static func apply() {
        NSApp.appearance = SkinStore.appearance
        for w in NSApp.windows {
            w.appearance = SkinStore.appearance
        }
    }
}

@MainActor
final class MainVC: NSViewController {

    private let store: Store
    private var pages: [PageKind: Page] = [:]
    private var now: PageKind = .overview

    private var root: NSView!
    private var side: NSView!
    private var sideW: NSLayoutConstraint!
    private var navRows: [TapRow] = []
    private var navLabels: [L] = []
    private var navIcons: [I] = []
    private var navBadge: Tag?

    private var skinBtn: B?
    private var refreshBtn: B?
    private var stampL: L?
    private var ticker: Timer?
    private var sideCollapsed = false
    private var titleL: L!
    private var rightBar: NSStackView!
    private var host: NSView!
    private var dot: NSView!
    private var statusL: L!
    private var powerBtn: B!
    private var brand: L!

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        root = NSView(frame: NSRect(x: 0, y: 0, width: T.S.winW, height: T.S.winH))
        root.wantsLayer = true
        root.layer?.backgroundColor = T.p.bg.cgColor

        side = buildSide()
        let main = buildMain()

        root.addSubview(side)
        root.addSubview(main)
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            side.topAnchor.constraint(equalTo: root.topAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            main.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            main.topAnchor.constraint(equalTo: root.topAnchor),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        sideW = side.widthAnchor.constraint(equalToConstant: T.S.side)
        sideW.isActive = true

        view = root

        pages = [
            .overview: PageOverview(store: store),
            .orders: PageOrders(store: store),
            .chats: PageChats(store: store),
            .shops: PageShops(store: store),
            .settings: PageSettings(store: store),
        ]

        Jump.to = { [weak self] kind, filter in
            guard let self else { return }
            self.go(kind, filter: filter)
        }

        store.onChange = { [weak self] in
            guard let self else { return }
            self.paintChrome()
            self.paintBar()
            self.mount()
        }
        show(.overview)
        paintChrome()
        paintBar()
        startTicker()
    }

    /// 每 20 秒轻刷一次「3 分钟前」这类相对时间。
    /// 只改文字不改结构，所以不会跳滚动位置、不打断输入。
    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pages[self?.now ?? .overview]?.tick() }
        }
    }

    // MARK: 侧栏

    private func buildSide() -> NSView {
        let p = T.p
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = p.side.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false

        brand = L("掌柜台", 14, .semibold)
        let logo = I("storefront", size: 14, color: p.text)
        let brandRow = S.h([logo, brand, Flex()], 8)

        var nav: [NSView] = []
        for k in PageKind.allCases {
            let icon = I(k.icon, size: 13, color: p.text2)
            let label = L(k.title, 12.5)
            let row = S.h([icon, label, Flex()], 10)
            let tap = TapRow(corner: 6)
            tap.put(row, left: 9, right: 9, top: 0, bottom: 0)
            tap.heightAnchor.constraint(equalToConstant: 30).isActive = true
            tap.onTap = { [weak self] in self?.show(k) }
            navRows.append(tap)
            navLabels.append(label)
            navIcons.append(icon)
            nav.append(tap)
        }
        let navStack = S.v(nav, 3)

        // 底部：服务状态 + 启停
        dot = Dot(p.text2, 7)
        statusL = L("检查中", 10.5, .regular, color: p.text2)
        powerBtn = B("启动服务", "power", style: .accent, size: 11.5, height: 30,
                     flexible: true,
                     action: { [weak self] in self?.store.toggleService() })

        let foot = S.v([
            S.h([dot, statusL, Flex()], 6),
            powerBtn,
        ], 7)

        bar.addSubview(brandRow)
        bar.addSubview(navStack)
        bar.addSubview(foot)
        NSLayoutConstraint.activate([
            brandRow.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            brandRow.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            brandRow.topAnchor.constraint(equalTo: bar.topAnchor, constant: 46),
            brandRow.heightAnchor.constraint(equalToConstant: 22),

            navStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            navStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            navStack.topAnchor.constraint(equalTo: brandRow.bottomAnchor, constant: 16),

            foot.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            foot.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            foot.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -14),
        ])
        for r in navRows {
            r.widthAnchor.constraint(equalTo: navStack.widthAnchor).isActive = true
        }
        powerBtn.leadingAnchor.constraint(equalTo: foot.leadingAnchor).isActive = true
        powerBtn.trailingAnchor.constraint(equalTo: foot.trailingAnchor).isActive = true
        return bar
    }

    // MARK: 主区

    private func buildMain() -> NSView {
        let p = T.p
        let main = NSView()
        main.wantsLayer = true
        main.layer?.backgroundColor = p.bg.cgColor
        main.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        let fold = B("", "sidebar.left", style: .plain, size: 11, height: 26, width: 28, a11y: "折叠或展开侧栏",
                     action: { [weak self] in self?.foldSide() })
        titleL = L("总览", 14, .semibold)
        rightBar = S.h([], 6)

        buildRightBar()
        let row = S.h([fold, titleL, Flex(), rightBar], 10)
        bar.addSubview(row)
        let hair = Line()

        host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false

        main.addSubview(bar)
        main.addSubview(hair)
        main.addSubview(host)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            bar.topAnchor.constraint(equalTo: main.topAnchor, constant: 30),
            bar.heightAnchor.constraint(equalToConstant: T.S.bar),

            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            hair.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            hair.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            hair.topAnchor.constraint(equalTo: bar.bottomAnchor),

            host.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            host.topAnchor.constraint(equalTo: hair.bottomAnchor),
            host.bottomAnchor.constraint(equalTo: main.bottomAnchor),
        ])
        return main
    }

    /// 顶栏右侧：按钮只建一次，之后只更新文字和可用状态。
    /// 每 20 秒重建一次会白白造几万个对象（实测切 50 次内存从 109 涨到 231MB）。
    private func buildRightBar() {
        let skinBtn = B("浅色", "sun.max", style: .plain, size: 11, height: 26, action: {
            SkinStore.use(SkinStore.current == .dark ? .light : .dark)
        })
        skinBtn.toolTip = "切换深浅色（⌘T）"
        let refresh = B("刷新", "arrow.clockwise", style: .plain, size: 11, height: 26,
                        action: { [weak self] in
                            // 主动刷新要立刻有反应：按钮变「正在刷新…」，
                            // 不等 20 秒轮询、也不因为「正好有一轮在跑」被丢掉。
                            self?.store.reload(force: true)
                        })
        refresh.toolTip = "立刻重取一次数据（⌘R）"
        let stamp = L("", 10, .regular, color: T.p.text2, mono: true)

        rightBar.addArrangedSubview(skinBtn)
        rightBar.addArrangedSubview(refresh)
        rightBar.addArrangedSubview(stamp)

        self.skinBtn = skinBtn
        self.refreshBtn = refresh
        self.stampL = stamp
    }

    private func paintBar() {
        guard titleL != nil else { return }
        titleL.stringValue = now.title
        guard let skinBtn, let refreshBtn, let stampL else { return }

        skinBtn.setTitle(SkinStore.current == .dark ? "浅色" : "深色")
        refreshBtn.isEnabled = !store.busy
        if store.refreshing {
            refreshBtn.setTitle("刷新中…")
        } else {
            refreshBtn.setTitle("刷新")
        }
        if let success = store.lastSuccessfulUpdate {
            stampL.stringValue = "数据 " + Clock.hms(success)
            stampL.textColor = store.lastError == nil ? T.p.text2 : T.p.warn
        } else if store.lastUpdate != nil {
            stampL.stringValue = "尚无成功数据"
            stampL.textColor = T.p.warn
        } else {
            stampL.stringValue = ""
        }
    }


    /// 按当前配色把侧栏 / 顶栏 / 当前页全部重搭一遍。
    /// 不换 root 实例（窗口已经持有它），只把里面的东西全部拆掉重搭。
    func repaintAll() {
        let keep = now
        let pagesBak = pages
        root.subviews.forEach { $0.removeFromSuperview() }
        navRows = []; navLabels = []; navIcons = []; navBadge = nil
        skinBtn = nil; refreshBtn = nil; stampL = nil
        root.layer?.backgroundColor = T.p.bg.cgColor

        side = buildSide()
        let main = buildMain()
        root.addSubview(side)
        root.addSubview(main)
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            side.topAnchor.constraint(equalTo: root.topAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            main.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            main.topAnchor.constraint(equalTo: root.topAnchor),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        sideW = side.widthAnchor.constraint(equalToConstant: sideCollapsed ? T.S.sideMini : T.S.side)
        sideW.isActive = true
        if sideCollapsed {
            brand.isHidden = true
            statusL.isHidden = true
            navLabels.forEach { $0.isHidden = true }
        }

        pages = pagesBak
        for p in pages.values { p.sig = "" }
        paintChrome()
        paintBar()
        goPublic(keep)
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
    }

    /// 由 AppDelegate 挂上：重建窗口并回到当前页
    var onSkinChange: (() -> Void)?
    var currentPage: PageKind { now }

    // MARK: 切页

    private func show(_ kind: PageKind) {
        guard now != kind else { return }
        now = kind
        store.setChatPageVisible(kind == .chats)
        paintNav()
        mount()
        paintBar()
    }

    private func go(_ kind: PageKind, filter: String?) {
        if let f = filter {
            switch kind {
            case .orders:
                PageOrders.filter = f
                PageOrders.picked = nil
                PageOrders.keyword = ""
            case .chats:
                PageChats.onlyWait = (f == "wait")
                PageChats.keyword = ""
                PageChats.pickedChat = nil
                PageChats.pickedShop = nil
            default: break
            }
        }
        if now == kind {
            (pages[kind] as? PageOrders)?.sig = ""
            (pages[kind] as? PageChats)?.sig = ""
        }
        now = kind
        store.setChatPageVisible(kind == .chats)
        paintNav()
        mount()
        paintBar()
    }

    private func mount() {
        guard let page = pages[now] else { return }
        if host.subviews.first === page.view {
            page.rebuildIfNeeded()
            paintNav()
            return
        }
        host.subviews.forEach { $0.removeFromSuperview() }
        page.rebuildIfNeeded()
        let v = page.view
        v.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            v.topAnchor.constraint(equalTo: host.topAnchor),
            v.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        paintNav()
    }

    private func paintNav() {
        let p = T.p
        guard navRows.count == navLabels.count, navRows.count == navIcons.count else { return }
        for (i, row) in navRows.enumerated() {
            let on = i == now.rawValue
            row.setSelected(on)
            row.selectedFill = on ? p.accent.withAlphaComponent(0.16) : nil
            navLabels[i].textColor = on ? p.text : p.text2
            navLabels[i].font = T.font(12.5, on ? .medium : .regular)
            navIcons[i].contentTintColor = on ? p.accent : p.text2
        }
        paintBadge()
    }

    private func paintBadge() {
        navBadge?.removeFromSuperview()
        navBadge = nil
        let n = store.todoCount
        guard n > 0, !navRows.isEmpty else { return }
        let tag = Tag("\(n)", T.p.warn, T.p.warnSoft, size: 9.5)
        navRows[0].addSubview(tag)
        NSLayoutConstraint.activate([
            tag.trailingAnchor.constraint(equalTo: navRows[0].trailingAnchor, constant: -8),
            tag.centerYAnchor.constraint(equalTo: navRows[0].centerYAnchor),
        ])
        navBadge = tag
    }

    // MARK: 底部状态

    private func paintChrome() {
        guard statusL != nil else { return }
        let p = T.p
        dot.layer?.backgroundColor = (store.serviceUp ? p.ok : p.text2).cgColor

        if store.busy {
            statusL.stringValue = store.busyText
            statusL.textColor = p.text2
        } else if let e = store.lastError, !e.isEmpty {
            statusL.stringValue = e
            statusL.textColor = p.warn
        } else if let notice = store.lastNotice, !notice.isEmpty {
            statusL.stringValue = notice
            statusL.textColor = p.ok
        } else if store.serviceUp {
            let cpu = store.health?.system?.cpu_percent.map { String(format: " · %.0f%%", $0) } ?? ""
            statusL.stringValue = "服务运行中" + cpu
            statusL.textColor = p.text2
        } else {
            statusL.stringValue = "服务已停止"
            statusL.textColor = p.text2
        }

        let title = store.busy ? "处理中" : (store.serviceUp ? "停止服务" : "启动服务")
        powerBtn.setTitle(sideCollapsed ? "" : title)
        powerBtn.isEnabled = !store.busy
        // 浅色主题下必须同时换文字色，否则白底白字看不见。
        if store.serviceUp {
            powerBtn.setRuntimeColors(fill: p.field, border: p.sep, title: p.text, iconColor: p.text2)
        } else {
            powerBtn.setRuntimeColors(fill: p.accent, border: nil, title: .white, iconColor: .white)
        }
        paintBadge()
    }

    /// 给外部（菜单、启动参数）切页
    func goPublic(_ kind: PageKind) {
        now = kind
        paintNav()
        mount()
        paintBar()
    }



    func snapshot(to path: String) {
        let target = view
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
        target.cacheDisplay(in: target.bounds, to: rep)
        if let d = rep.representation(using: .png, properties: [:]) {
            try? d.write(to: URL(fileURLWithPath: path))
        }
    }

    @objc private func foldSide() {
        let mini = sideW.constant > 100
        sideCollapsed = mini
        sideW.constant = mini ? T.S.sideMini : T.S.side
        brand.isHidden = mini
        statusL.isHidden = mini
        for (i, label) in navLabels.enumerated() {
            label.isHidden = mini
            navIcons[i].isHidden = false
        }
        powerBtn.setTitle(mini ? "" : (store.serviceUp ? "停止服务" : "启动服务"))
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.14
            self.side.superview?.layoutSubtreeIfNeeded()
        }
    }
}
