import AppKit

/// 设置页。只有四件事：服务、外观、登录、数据。
@MainActor
final class PageSettings: ScrollPage {

    private var captcha = false
    private var captchaLoaded = false
    private var captchaKnown = false
    private var captchaError: String?
    private var captchaBusy = false
    private var actionNote: (text: String, ok: Bool)?

    override func signature() -> String {
        // 只跟服务状态走。开关类状态由用户自己操作后强制重建，别被轮询刷掉。
        "\(store.serviceUp)|\(store.busy)|\(store.lastError ?? "")|\(store.uiRevision)|\(captcha)|\(captchaKnown)|\(captchaError ?? "")|\(captchaBusy)|\(actionNote?.text ?? "")|\(actionNote?.ok ?? false)|\(SkinStore.current.rawValue)"
    }

    override func build() {
        var rows: [NSView] = []
        if let e = store.lastError {
            rows.append(Card([S.h([Dot(T.p.warn, 6), L(e, 11, .regular, color: T.p.warn), Flex()], 8)],
                             pad: 12, gap: 0))
        }
        rows.append(serviceGroup())
        rows.append(skinGroup())
        rows.append(loginGroup())
        rows.append(pathGroup())
        rows.append(dataGroup())
        rows.append(aboutCard())
        scroll.show(rows)
        loadCaptchaOnce()
    }

    // MARK: 服务

    private func serviceGroup() -> NSView {
        let p = T.p
        let c = Card([], pad: 16, gap: 12)

        let tag = Tag(store.serviceUp ? "运行中" : "已停止",
                      store.serviceUp ? p.ok : p.text2,
                      store.serviceUp ? p.ok.withAlphaComponent(0.13) : p.text2.withAlphaComponent(0.10))
        let toggle = B(store.serviceUp ? "停止服务" : "启动服务", "power",
                       style: store.serviceUp ? .danger : .accent, height: T.S.ctrlH2,
                       action: { [weak self] in self?.store.toggleService() })
        toggle.isEnabled = !store.busy
        let restart = B("重启", "arrow.triangle.2.circlepath", style: .plain, height: T.S.ctrlH2,
                        action: { [weak self] in self?.store.restartService() })
        restart.isEnabled = store.serviceUp && !store.busy

        c.add(L("后台服务", 13, .semibold))
        c.add(S.h([tag, toggle, restart, Flex()], 8))
        c.add(L.wrap(store.serviceUp
                     ? "服务在跑，自动发货、自动回复、心跳都在工作。关掉这个窗口不影响它。"
                     : "服务停着，买家下单不会自动发货。点「启动服务」，十几秒就好。",
                     11, color: store.serviceUp ? p.text2 : p.warn, width: 700))

        c.add(Line())

        let openLog = B("看运行记录", "folder", style: .plain, size: 11, height: 26, action: {
            let dir = Cfg.logs
            if FileManager.default.fileExists(atPath: dir.path) {
                NSWorkspace.shared.open(dir)
            } else {
                let alert = NSAlert()
                alert.messageText = "还没有运行记录"
                alert.informativeText = "服务启动并运行过之后，这里才会出现记录。"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        })
        let openWeb = B("打开旧版网页后台", "safari", style: .plain, size: 11, height: 26, action: {
            if let u = URL(string: Cfg.base) { NSWorkspace.shared.open(u) }
        })
        c.add(S.h([openLog, openWeb, Flex()], 8))
        return c
    }


    // MARK: 外观

    private func skinGroup() -> NSView {
        let c = Card([], pad: 16, gap: 10)
        c.add(L("界面", 13, .semibold))

        let items: [(Skin, String)] = [(.dark, "深色"), (.light, "浅色")]
        var btns: [NSView] = []
        for (skin, title) in items {
            let b = B(title, skin == .dark ? "moon" : "sun.max",
                      style: .filled, size: 11.5, height: 28)
            b.setOn(SkinStore.current == skin)
            b.action = { SkinStore.use(skin) }
            btns.append(b)
        }
        c.add(S.h(btns, 8))
        c.add(L("深色是默认。换浅色只影响这个窗口，不影响后台服务。", 10.5, .regular, color: T.p.text2))
        return c
    }

    // MARK: 登录

    private func loginGroup() -> NSView {
        let p = T.p
        let c = Card([], pad: 16, gap: 10)
        c.add(L("登录", 13, .semibold))

        let has = Cfg.password() != nil
        c.add(S.h([Dot(has ? p.ok : p.warn, 6),
                   L(has ? "已配置登录信息，打开就是登录状态，不用你输" : "登录信息缺失，数据取不出来",
                     11, .regular, color: has ? p.text2 : p.warn)], 7))

        if captchaKnown {
            let t = Toggle(captcha)
            t.a11yLabel = "登录验证码"
            t.isEnabled = !captchaBusy
            t.onChange = { [weak self] v in
                guard let self, !self.captchaBusy else { return }
                self.captchaBusy = true
                self.force()
                Task {
                    do {
                        try await Api.shared.captcha(v)
                        self.captcha = v
                        self.captchaError = nil
                    } catch {
                        self.captchaError = error.localizedDescription
                    }
                    self.captchaBusy = false
                    self.force()
                }
            }
            c.add(S.h([L("登录验证码", 11.5), W.fix(t, 40), Flex()], 8))
        } else if captchaBusy {
            c.add(S.h([Dot(p.text2, 6), L("正在读取验证码设置…", 11, .regular, color: p.text2), Flex()], 7))
        } else if let e = captchaError {
            let retry = B("重试", "arrow.clockwise", style: .plain, size: 10.5, height: 24,
                          action: { [weak self] in self?.retryCaptcha() })
            c.add(S.h([Dot(p.warn, 6), L("验证码设置没取到：\(e)", 11, .regular, color: p.warn),
                       Flex(), retry], 7))
        } else {
            c.add(S.h([Dot(p.text2, 6), L("验证码状态未知", 11, .regular, color: p.text2), Flex()], 7))
        }
        if let e = captchaError, captchaKnown {
            c.add(L("上一次修改没生效：\(e)", 10.5, .regular, color: p.warn))
        }
        c.add(L("服务只在这台电脑上运行，外网连不进来，所以登录验证码一般用不上。保持关闭即可。", 10.5, .regular, color: p.text2))
        c.add(L("后台一重启，登录状态就失效。这里会自动重新登，不会让你再输一遍。",
                10.5, .regular, color: p.text2))
        return c
    }

    private func retryCaptcha() {
        captchaLoaded = false
        captchaKnown = false
        captchaError = nil
        force()
    }

    private func loadCaptchaOnce() {
        guard !captchaLoaded else { return }
        captchaLoaded = true
        captchaBusy = true
        captchaError = nil
        Task {
            do {
                captcha = try await Api.shared.captchaOn()
                captchaKnown = true
            } catch {
                captchaKnown = false
                captchaError = error.localizedDescription
            }
            captchaBusy = false
            force()
        }
    }

    // MARK: 项目目录

    private func pathGroup() -> NSView {
        let p = T.p
        let c = Card([], pad: 16, gap: 10)
        c.add(L("项目目录", 13, .semibold))

        let path = L(Cfg.root.path, 11, .regular, color: p.text2, mono: true)
        path.lineBreakMode = .byTruncatingMiddle
        let pick = B("选择…", "folder", style: .plain, size: 11, height: 26,
                     action: { [weak self] in self?.pickRoot() })
        c.add(S.h([path, Flex(), pick], 8))
        c.add(L.wrap("后台代码和 .env 所在的目录（默认 ~/Documents/xianyu）。换目录后会自动重连新的后台；后台端口不是 8090 的话也要在这里改。",
                     10.5, color: p.text2, width: 700))
        return c
    }

    private func pickRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "用这个目录"
        panel.directoryURL = Cfg.root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Cfg.root = url
        store.reload(force: true)
        force()
    }

    // MARK: 数据

    private func dataGroup() -> NSView {
        let c = Card([], pad: 16, gap: 10)
        c.add(L("数据", 13, .semibold))
        c.add(kv("数据库", fileSize(Cfg.db)))
        c.add(kv("日志目录", dirSize(Cfg.logs)))

        let backup = B("导出配置备份", "square.and.arrow.up", style: .plain, size: 11, height: 26,
                       action: { [weak self] in self?.exportBackup() })
        let clear = B("清空内存日志", "trash", style: .danger, size: 11, height: 26,
                      action: { [weak self] in self?.clearLogs() })
        c.add(S.h([backup, clear, Flex()], 8))
        if let note = actionNote {
            c.add(L(note.text, 10.5, .regular, color: note.ok ? T.p.ok : T.p.warn))
        }
        c.add(L("导出的是账号连接、关键词、商品资料和 AI 配置。账号 Cookie 是加密存的；AI 的 API Key 是明文，备份文件请当密钥文件保管，别发给别人。订单、发货规则、卡券不在这个备份里。",
                10.5, .regular, color: T.p.text2))
        c.add(L("清日志只清屏幕上的实时记录，不删文件。", 10.5, .regular, color: T.p.text2))
        return c
    }

    private func aboutCard() -> NSView {
        let c = Card([], pad: 16, gap: 6)
        c.add(L("掌柜台", 12, .semibold))
        c.add(L("闲鱼店铺的一个窗口。真正干活的后台跟它分开跑 —— 关掉这个窗口，自动发货照常。",
                10.5, .regular, color: T.p.text2))
        return c
    }

    // MARK: 小件

    private func kv(_ key: String, _ value: String) -> NSView {
        let k = L(key, 11, .regular, color: T.p.text2)
        let v = L(value, 11, .regular, color: T.p.text, mono: true)
        v.lineBreakMode = .byTruncatingMiddle
        return S.h([W.fix(k, 60), v, Flex()], 8)
    }

    private func fileSize(_ url: URL) -> String {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = a[.size] as? Int64 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private func dirSize(_ url: URL) -> String {
        var total: Int64 = 0
        if let files = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            for f in files {
                let p = url.appendingPathComponent(f)
                if let a = try? FileManager.default.attributesOfItem(atPath: p.path), let n = a[.size] as? Int64 {
                    total += n
                }
            }
        }
        return total == 0 ? "—" : ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func force() {        sig = ""
        build()
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "掌柜台配置备份-\(Clock.today()).json"
        panel.title = "导出配置备份"
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    try await Api.shared.exportBackup(to: url)
                    actionNote = ("已导出到 \(url.lastPathComponent)", true)
                } catch {
                    actionNote = ("导出失败：\(error.localizedDescription)", false)
                }
                force()
            }
        }
    }

    private func clearLogs() {
        let alert = NSAlert()
        alert.messageText = "清空内存里的日志？"
        alert.informativeText = "只清屏幕上这些实时记录，电脑里的日志文件不动。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "算了")
        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                do {
                    try await Api.shared.clearLogs()
                    actionNote = ("实时日志已清空", true)
                    store.reload(force: true)
                } catch {
                    actionNote = ("清空失败：\(error.localizedDescription)", false)
                }
                force()
            }
        }
    }
}
