import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var win: NSWindow!
    private var item: NSStatusItem!
    private let store = Store()
    private var vc: MainVC!

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        buildWindow()
        buildStatusItem()

        store.start()

        // 打开就连服务；服务本来在跑就直接读，不打扰
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if !Service.up { self.store.autoStart() }
        }

        if let p = ProcessInfo.processInfo.environment["ZGT_PAGE"],
           let k = ["overview": PageKind.overview, "orders": .orders, "chats": .chats,
                    "shops": .shops, "settings": .settings][p] {
            vc.goPublic(k)
        }
        if let out = ProcessInfo.processInfo.environment["ZGT_SHOT"] {
            let delay = Double(ProcessInfo.processInfo.environment["ZGT_DELAY"] ?? "8") ?? 8
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.vc.snapshot(to: out)
                if ProcessInfo.processInfo.environment["ZGT_QUIT"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
                }
            }
        }
    }

    // MARK: 窗口

    private func buildWindow() {
        vc = MainVC(store: store)
        vc.onSkinChange = { [weak self] in self?.rebuildForSkin() }
        SkinStore.onSwitch = { [weak self] in self?.rebuildForSkin() }
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(T.S.winW, vf.width - 40)
        let h = min(T.S.winH, vf.height - 40)
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                       styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                       backing: .buffered, defer: false)
        win.title = "掌柜台"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.appearance = SkinStore.appearance
        win.backgroundColor = T.p.bg
        win.contentViewController = vc
        win.minSize = NSSize(width: T.S.minW, height: T.S.minH)
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installWakeObservers()
    }

    /// 系统会把后台 App 的 Timer 降频甚至停掉（App Nap）。
    /// 实测：窗口被盖住后 20 秒轮询静默了 18 分钟，切回来看到的全是旧数字。
    /// 这里在「重新激活 / 窗口重新可见」时强制拉一次，保证你看到的那一刻是新的。
    private func installWakeObservers() {
        let nc = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification,
                     NSWindow.didBecomeKeyNotification,
                     NSWindow.didDeminiaturizeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.store.resumeAfterBackground() }
            }
        }
        // 切到后台时把会话轮询降到 180 秒。App Nap 本来就会把后台 Timer 压到分钟级，
        // 但那是「系统顺手压的」、不可控也不可预期（接电源/有网络活动时不压）。
        // 这里显式降速，是让「后台不该按 30 秒打平台」变成确定行为，而不是碰运气。
        for name in [NSApplication.didResignActiveNotification,
                     NSWindow.didMiniaturizeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.store.enterBackground() }
            }
        }
    }

    /// 自渲染截图，核对界面用，不需要录屏权限
    func snapshot(to path: String) {
        let target = vc.view
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
        target.cacheDisplay(in: target.bounds, to: rep)
        if let d = rep.representation(using: .png, properties: [:]) {
            try? d.write(to: URL(fileURLWithPath: path))
        }
    }

    /// 关窗口不退出：菜单栏还留着
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    /// 退出 App 一律不动服务。App 只是看板，服务独立跑（launchd 托管）。
    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply { .terminateNow }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { win.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    @objc private func showWin() {
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 菜单栏

    private func buildStatusItem() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "storefront", accessibilityDescription: "掌柜台")
            b.image?.isTemplate = true
            b.imagePosition = .imageLeft
            b.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }
        let m = NSMenu()
        m.delegate = self
        item.menu = m
        // 数据轮询也要重画状态项；以前只有展开菜单才更新，
        // 菜单栏会长期停留在启动时的 0/1 或旧的在线数。
        store.onStatusChange = { [weak self] in self?.tune() }
        tune()
    }

    private func tune() {
        guard let b = item.button else { return }
        if !store.serviceUp {
            b.title = " 停"
            b.contentTintColor = .tertiaryLabelColor
            return
        }
        guard !store.accounts.isEmpty else {
            b.title = " …"
            b.contentTintColor = .secondaryLabelColor
            return
        }
        let enabled = store.accounts.filter { $0.enabled ?? true }
        let fine = enabled.filter { $0.link == .fine }.count
        // 发货失败、买家等回话也算「需要你」。原来只看连接和报错，
        // 通知全关之后，关窗期间发货失败完全没有任何提醒。
        let fix = store.toFix.count
        let wait = store.waitingChats.count
        let hasProblem = fine < enabled.count || store.lastError != nil || fix > 0
        var label = " \(fine)/\(enabled.count)"
        if fix > 0 { label += " 补\(fix)" }
        if wait > 0 { label += " 等\(wait)" }
        if hasProblem && fix == 0 && wait == 0 { label += " !" }
        b.title = label
        b.contentTintColor = (hasProblem || wait > 0) ? T.p.warn : T.p.ok
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        tune()

        let head = NSMenuItem(title: store.serviceUp ? "服务在跑 · 本机 \(Cfg.port)" : "服务停着",
                              action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)

        if let error = store.lastError, !error.isEmpty {
            let it = NSMenuItem(title: "  ⚠ \(error)", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
        }

        if store.serviceUp {
            for a in store.accounts {
                let wait = store.waiting(a.id)
                let t = "  \(store.short(a.id)) · \(store.stateText(a))" + (wait > 0 ? "  ·  \(wait) 人等回" : "")
                let it = NSMenuItem(title: t, action: nil, keyEquivalent: "")
                it.isEnabled = false
                it.image = NSImage(systemSymbolName: a.isOnline ? "circle.fill" : "exclamationmark.circle.fill",
                                   accessibilityDescription: nil)
                it.image?.isTemplate = true
                menu.addItem(it)
            }
            if store.revenueFresh {
                let today = store.paidSales.values.reduce(0) { $0 + $1.today }
                let week = store.paidSales.values.reduce(0) { $0 + $1.week }
                let it = NSMenuItem(title: String(format: "  实付 今 ¥%.2f · 本周 ¥%.2f", today, week),
                                    action: nil, keyEquivalent: "")
                it.isEnabled = false
                menu.addItem(it)
            } else {
                let it = NSMenuItem(title: "  实付营收未同步", action: nil, keyEquivalent: "")
                it.isEnabled = false
                menu.addItem(it)
            }
            let todo = store.todoCount
            let t = NSMenuItem(title: todo > 0 ? "  有待处理 \(todo) 件" : "  没有待处理", action: nil, keyEquivalent: "")
            t.isEnabled = false
            menu.addItem(t)
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: "打开掌柜台", action: #selector(showWin), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let power = NSMenuItem(title: store.busy ? "处理中…" : (store.serviceUp ? "停止服务" : "启动服务"),
                               action: #selector(toggleSvc), keyEquivalent: "")
        power.target = self
        power.isEnabled = !store.busy
        menu.addItem(power)

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出掌柜台", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleSvc() { store.toggleService() }

    func applicationWillTerminate(_ n: Notification) { store.stopPolling() }

    // MARK: 主菜单

    private func buildMenu() {
        let main = NSMenu()
        let app = NSMenuItem()
        main.addItem(app)
        let am = NSMenu()
        am.addItem(withTitle: "关于掌柜台", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        am.addItem(.separator())
        am.addItem(withTitle: "隐藏掌柜台", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        am.addItem(.separator())
        am.addItem(withTitle: "退出掌柜台", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = am

        let edit = NSMenuItem()
        main.addItem(edit)
        let em = NSMenu(title: "编辑")
        em.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        em.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        em.addItem(.separator())
        em.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        em.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        em.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        em.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = em

        let view = NSMenuItem()
        main.addItem(view)
        let vm = NSMenu(title: "显示")
        for (i, k) in PageKind.allCases.enumerated() {
            let it = NSMenuItem(title: k.title, action: #selector(jump(_:)), keyEquivalent: "\(i + 1)")
            it.tag = k.rawValue
            it.target = self
            vm.addItem(it)
        }
        vm.addItem(.separator())
        let refresh = NSMenuItem(title: "刷新数据", action: #selector(refreshData), keyEquivalent: "r")
        refresh.target = self
        vm.addItem(refresh)
        let skin = NSMenuItem(title: "切换深浅色", action: #selector(flipSkin), keyEquivalent: "t")
        skin.target = self
        vm.addItem(skin)
        view.submenu = vm

        let win = NSMenuItem()
        main.addItem(win)
        let wm = NSMenu(title: "窗口")
        wm.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        wm.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.submenu = wm

        NSApp.mainMenu = main
    }

    @objc private func jump(_ s: NSMenuItem) {
        guard let k = PageKind(rawValue: s.tag) else { return }
        vc.goPublic(k)
        showWin()
    }

    @objc private func refreshData() {
        store.reload(force: true)
    }

    @objc private func flipSkin() {
        _ = SkinStore.cycle()
        rebuildForSkin()
    }

    /// 换肤不重建窗口：直接把整套界面按新配色重新搭一遍。
    /// 重建窗口会多出窗口、丢位置、菜单栏闪，实测代价更大。
    private func rebuildForSkin() {
        AppSkin.apply()
        win.appearance = SkinStore.appearance
        win.backgroundColor = T.p.bg
        vc.repaintAll()
    }
}

// MARK: 入口

@main
struct Main {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let d = AppDelegate()
        app.delegate = d
        app.setActivationPolicy(.regular)
        app.appearance = SkinStore.appearance
        app.run()
    }
}
