import AppKit

/// 账号页。每店一张卡，「假在线」在卡头就能看出来。
@MainActor
final class PageShops: ScrollPage {

    override func signature() -> String {
        let k = store.accounts.map {
            "\($0.id)\($0.enabled ?? true)\($0.auto_confirm ?? false)\($0.auto_comment ?? false)\($0.auto_red_flower ?? false)\($0.isOnline)\($0.runtime_status?.message_stream_status ?? "")\($0.heartbeat)\($0.lastTalk)\(store.stateText($0))\(store.aiOn($0.id))"
        }.joined()
        // 四个开关的乐观值也要进指纹，否则点完这一帧不重绘。
        let sw = store.accounts.map {
            "\($0.id):\(store.switchOn($0.id, "confirm"))\(store.switchOn($0.id, "comment"))" +
            "\(store.switchOn($0.id, "flower"))\(store.switchOn($0.id, "ai"))"
        }.joined()
        return "\(store.serviceUp)|\(store.loading)|\(k)|\(sw)|\(store.waitingChats.count)|\(store.lastError ?? "")|\(store.uiRevision)"
    }

    override func build() {
        guard requireService() else { return }
        if store.loading && store.accounts.isEmpty {
            scroll.show([Blank.skeleton([0.4, 1, 0.6])])
            return
        }
        guard !store.accounts.isEmpty else {
            let msg = store.lastError ?? "服务在跑，但没有返回账号。"
            scroll.show([Blank.card("读不到店铺", msg,
                                    buttons: [B("重试", "arrow.clockwise", style: .plain, action: { [weak self] in
                                        self?.store.reload(force: true)
                                    })])])
            return
        }

        var rows: [NSView] = []
        if let e = store.lastError {
            let retry = B("重试", "arrow.clockwise", style: .plain, size: 10.5, height: 24,
                          action: { [weak self] in self?.store.reload(force: true) })
            rows.append(Card([S.h([Dot(T.p.warn, 6), L(e, 11, .regular, color: T.p.warn), Flex(), retry], 8)],
                             pad: 12, gap: 0))
        }
        for a in store.accounts { rows.append(card(a)) }
        scroll.show(rows)
    }

    private func card(_ a: Account) -> NSView {
        let p = T.p
        let link = a.link
        let on = a.isOnline
        let conn = store.connecting(a)
        let enabled = a.enabled ?? true

        let strip: NSColor? = on ? nil : (conn ? nil : Look.linkColor(link))
        let c = Card([], pad: 16, gap: 12, accent: strip)

        // 卡头
        let head = S.h([
            Dot(on ? p.ok : (conn ? p.text2 : Look.linkColor(link)), 8),
            L(store.name(a.id), 14.5, .semibold),
            L(a.id, 10.5, .regular, color: p.text2),
            Tag(store.stateText(a), Look.linkColor(link),
                conn ? p.text2.withAlphaComponent(0.10) : Look.linkBg(link)),
            Flex(),
        ], 8)
        c.add(head)

        let noteText: String
        if !enabled {
            noteText = "这个账号停用了 —— 不收买家消息，也不会自动发货。"
        } else if conn {
            noteText = "正在连，半分钟左右。这会儿不算异常。"
        } else {
            noteText = link.hint
        }
        c.add(L(noteText, 11, .regular, color: on ? p.text2 : Look.linkColor(link)))

        // 两个数：心跳、上次买家说话
        let hb = bigNum("最近一次心跳", a.heartbeat, warn: (a.runtime_status?.last_heartbeat_age_seconds ?? 0) > 60)
        let talk = bigNum("买家上次说话", a.lastTalk,
                          warn: (a.runtime_status?.last_user_chat_age_seconds ?? 0) > 3600)
        let nums = S.h([hb, talk], 8)
        nums.distribution = .fillEqually
        c.add(nums)

        c.add(Line())

        // 开关
        c.add(sw(a, "confirm", "自动确认发货", store.switchOn(a.id, "confirm"), "买家付完自动点已发货", "要手动确认"))
        c.add(sw(a, "comment", "自动评价", store.switchOn(a.id, "comment"), "完结的单自动给好评", "关着"))
        c.add(sw(a, "flower", "自动要小红花", store.switchOn(a.id, "flower"), "发货后顺手要一朵", "关着"))
        c.add(sw(a, "ai", "AI 回复", store.switchOn(a.id, "ai"), "关键词没命中时交给 AI", "只走关键词"))

        c.add(Line())

        // 动作
        let waiting = store.waiting(a.id)
        let chatBtn = B(waiting > 0 ? "\(waiting) 人等回话" : "会话", "bubble.left",
                        style: waiting > 0 ? .accent : .plain, size: 11, height: 26,
                        action: { [weak self] in
                            // 直接按账号 ID 过滤，账号数量由后台决定。
                            PageChats.shop = a.id
                            PageChats.onlyWait = waiting > 0
                            PageChats.pickedChat = nil
                            PageChats.pickedShop = nil
                            Jump.to?(.chats, nil)
                            _ = self
                        })
        let again = B(store.actionBusy("reconnect:\(a.id)") ? "重连中…" : "重连",
                      "arrow.triangle.2.circlepath", style: .plain,
                      size: 11, height: 26, action: { [weak self] in
                          Task { await self?.store.reconnect(a.id) }
                      })
        again.isEnabled = enabled
            && !store.actionBusy("reconnect:\(a.id)")
            && !store.actionBusy("enable:\(a.id)")
        again.toolTip = enabled ? "断开后重连" : "账号已停用，请先点“启用”"
        let power = B(store.actionBusy("enable:\(a.id)") ? "处理中…" : (enabled ? "停用" : "启用"),
                      "power", style: enabled ? .danger : .accent,
                      size: 11, height: 26, action: { [weak self] in
                          // 停用 = 这一店不收消息、不自动发货，必须确认；启用不用。
                          if enabled {
                              let ok = Confirm.ask(
                                  title: "停用 \(self?.store.name(a.id) ?? a.id)？",
                                  detail: "停用后这一店不收买家消息，也不会自动发货，直到你重新点“启用”。",
                                  action: "停用")
                              guard ok else { return }
                          }
                          Task { await self?.store.setEnabled(a.id, !enabled) }
                      })
        power.isEnabled = !store.actionBusy("enable:\(a.id)") && !store.actionBusy("reconnect:\(a.id)")
        c.add(S.h([chatBtn, again, Flex(), power], 8))

        return c
    }

    private func bigNum(_ title: String, _ value: String, warn: Bool) -> NSView {
        let p = T.p
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = p.bg.cgColor
        box.layer?.cornerRadius = 6
        box.translatesAutoresizingMaskIntoConstraints = false
        let col = S.v([L(title, 10, .regular, color: p.text2),
                       L(value, 15, .semibold, color: warn ? p.warn : p.text, mono: true)], 2)
        box.addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 9),
            col.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -7),
            col.topAnchor.constraint(equalTo: box.topAnchor, constant: 7),
            col.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -7),
        ])
        return box
    }

    private func sw(_ a: Account, _ key: String, _ title: String,
                    _ on: Bool, _ onText: String, _ offText: String) -> NSView {
        let p = T.p
        let busyKey = "toggle:\(a.id):\(key)"
        let busy = store.actionBusy(busyKey)
        let toggle = Toggle(on)
        toggle.a11yLabel = title
        toggle.isEnabled = !busy
        toggle.onChange = { [weak self] v in
            Task { await self?.store.toggle(a.id, key, v) }
        }
        let label = L(title, 11.5)
        let hint = L(busy ? "保存中…" : (on ? onText : offText), 10.5, .regular, color: p.text2)
        let row = S.h([W.fix(label, 96), toggle, hint, Flex()], 10)
        return row
    }

}
