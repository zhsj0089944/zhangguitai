import AppKit

/// 会话页。左边列表按「等你回话的时间」排，右边聊天。
@MainActor
final class PageChats: Page {

    static var keyword = ""
    /// nil = 全部；否则是后台返回的账号 ID。
    static var shop: String?
    static var onlyWait = false
    static var pickedChat: String?
    static var pickedShop: String?

    let store: Store
    let view: NSView = Flipped()
    var sig = ""

    private let left = NSView()
    private let right = NSView()
    private let listBox = Scroller(pad: 6, gap: 2)
    private var msgs: [ChatMessage] = []
    private var loadingMsg = false
    /// 发送状态必须按会话隔离。共用一个 Bool 会在切换会话后
    /// 让旧请求的失败/成功落到新会话头上。
    private var sendingChats: Set<String> = []
    private var sendErrors: [String: String] = [:]
    private var loadError: String?
    private var loadNotice: String?
    private var messagesHasMore = false
    /// 已经拉过消息的会话和该会话最后一条的时间，用来判断是否要补拉消息。
    private var loadedKey = ""
    private var loadedStamp = ""
    /// 每次请求递增；切会话后旧请求即使晚到也不能覆盖新会话。
    private var msgGeneration = 0
    /// 草稿按 shop|chat 保存。自动切会话（筛选/当前会话掉出列表）时
    /// 绝不能把上一位买家的话带到下一位输入框里。
    static var drafts: [String: String] = [:]
    /// 输入框的文本变更观察者，页面重建时要解绑
    private var draftWatcher: NSObjectProtocol?
    /// 只随时间变的文字（「等 5 分钟」），原地改字，不重建整页。
    private let ticking = Ticking()

    private func chatKey(_ shop: String, _ chat: String) -> String { shop + "|" + chat }

    private var currentKey: String? {
        guard let shop = PageChats.pickedShop, let chat = PageChats.pickedChat else { return nil }
        return chatKey(shop, chat)
    }

    private func draft(_ key: String) -> String { PageChats.drafts[key] ?? "" }

    private func setDraft(_ text: String, for key: String) {
        if text.isEmpty { PageChats.drafts[key] = nil }
        else { PageChats.drafts[key] = text }
    }

    init(store: Store) {
        self.store = store
        view.translatesAutoresizingMaskIntoConstraints = false

        for v in [left, right] {
            v.wantsLayer = true
            v.layer?.backgroundColor = T.p.card.cgColor
            v.layer?.cornerRadius = T.S.radius
            v.layer?.borderWidth = 1
            v.layer?.borderColor = T.p.sep.cgColor
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        right.layer?.masksToBounds = true

        view.addSubview(left)
        view.addSubview(right)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: T.S.page),
            left.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            left.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            left.widthAnchor.constraint(equalToConstant: 290),

            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 10),
            right.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -T.S.page),
            right.topAnchor.constraint(equalTo: left.topAnchor),
            right.bottomAnchor.constraint(equalTo: left.bottomAnchor),
        ])
    }

    func signature() -> String {
        let k = store.sessions.flatMap { shop, list in
            list.map { "\(shop)|\($0.chat_id)|\($0.created_at ?? "")|\($0.direction ?? 0)|\($0.content ?? "")|\($0.unread_count ?? 0)|\($0.content_type ?? 0)" }
        }.sorted().joined(separator: "\n")
        let key = currentKey ?? ""
        let meta = store.sessionMeta.map { "\($0.key):\($0.value.source ?? ""):\($0.value.remoteError ?? ""):\($0.value.hasMore)" }.joined()
        // 不含 minuteBucket：每行「等 3 分钟」靠 tick() 原地改，
        // 否则整页每分钟重建一次，列表滚动位置和输入框光标都会丢。
        return "\(store.serviceUp)|\(store.loading)|\(store.lastError ?? "")|\(store.lastNotice ?? "")|\(meta)|\(k)|\(PageChats.keyword)|\(PageChats.shop ?? "")|\(PageChats.onlyWait)|\(PageChats.pickedChat ?? "")|\(msgs.count)|\(messagesHasMore)|\(loadingMsg)|\(sendingChats.contains(key))|\(sendErrors[key] ?? "")|\(loadError ?? "")|\(loadNotice ?? "")|\(loadedKey)|\(loadedStamp)|\(store.uiRevision)"
    }

    func tick() { ticking.tick() }

    func build() {
        ticking.reset()
        paintSurfaces()
        guard store.serviceUp else {
            left.subviews.forEach { $0.removeFromSuperview() }
            right.subviews.forEach { $0.removeFromSuperview() }
            listBox.removeFromSuperview()
            let btn = B("启动服务", "power", style: .accent, action: { [weak self] in self?.store.toggleService() })
            let blank = Blank.card("服务没开着", "会话要连本机服务才能拉，先把服务起来。", buttons: [btn])
            right.addSubview(blank)
            NSLayoutConstraint.activate([
                blank.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 20),
                blank.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -20),
                blank.centerYAnchor.constraint(equalTo: right.centerYAnchor),
            ])
            return
        }
        buildList()
        buildThread()
    }

    private func paintSurfaces() {
        for v in [left, right] {
            v.layer?.backgroundColor = T.p.card.cgColor
            v.layer?.borderColor = T.p.sep.cgColor
        }
    }

    // MARK: 左列

    private func visible() -> [(shop: String, chat: ChatSession)] {
        var all = store.chatList
        if PageChats.onlyWait { all = all.filter { store.needsReply($0.shop, $0.chat) } }
        if let shop = PageChats.shop { all = all.filter { $0.shop == shop } }
        let q = PageChats.keyword.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            all = all.filter { ($0.chat.who + ($0.chat.content ?? "")).lowercased().contains(q) }
        }
        return all
    }

    private func buildList() {
        left.subviews.forEach { $0.removeFromSuperview() }

        let accountIndex = PageChats.shop.flatMap { id in
            store.accounts.firstIndex { $0.id == id }
        }
        // 左列固定 290pt，标签栏上限留出左右各 8pt 的内边距，账号多了内部横向滚动。
        let tabs = Tabs(["全部", "等人回"] + store.accounts.map { store.short($0.id) },
                        index: PageChats.onlyWait ? 1 : (accountIndex.map { $0 + 2 } ?? 0),
                        maxWidth: 274)
        tabs.onChange = { [weak self] i in
            guard let self else { return }
            PageChats.onlyWait = (i == 1)
            let acc = i - 2
            PageChats.shop = (i >= 2 && acc < store.accounts.count) ? store.accounts[acc].id : nil
            self.force()
        }
        let head = NSView()
        head.translatesAutoresizingMaskIntoConstraints = false
        head.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: head.leadingAnchor, constant: 8),
            // 上限之外再兜一道：标签栏不能越过 head 右边界，否则会盖到右侧正文上。
            tabs.trailingAnchor.constraint(lessThanOrEqualTo: head.trailingAnchor, constant: -8),
            tabs.topAnchor.constraint(equalTo: head.topAnchor, constant: 8),
            tabs.bottomAnchor.constraint(equalTo: head.bottomAnchor, constant: -4),
        ])

        listBox.removeFromSuperview()
        left.addSubview(head)
        left.addSubview(listBox)
        NSLayoutConstraint.activate([
            head.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            head.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            head.topAnchor.constraint(equalTo: left.topAnchor),
            listBox.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            listBox.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            listBox.topAnchor.constraint(equalTo: head.bottomAnchor),
            listBox.bottomAnchor.constraint(equalTo: left.bottomAnchor, constant: -4),
        ])

        let list = visible()
        let failedShops = store.sessionMeta.filter { _, meta in
            !(meta.remoteError ?? "").isEmpty
        }
        if list.isEmpty {
            let emptyText: String
            if store.loading && store.sessions.isEmpty {
                emptyText = "正在读取会话…"
            } else if let first = failedShops.first {
                emptyText = "会话没取到：\(first.value.remoteError ?? "未知原因")。点右上刷新重试。"
            } else if let e = store.lastError, store.sessions.isEmpty {
                emptyText = "会话没取到：\(e)。点右上刷新重试。"
            } else {
                emptyText = store.sessions.isEmpty ? "还没有会话。买家发消息后会出现。" : "这个筛选下没有会话。"
            }
            let hint = L.wrap(emptyText, 11, color: T.p.text2, width: 250)
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(hint)
            NSLayoutConstraint.activate([
                hint.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 8),
                hint.topAnchor.constraint(equalTo: holder.topAnchor, constant: 10),
                hint.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            ])
            var emptyRows: [NSView] = []
            if let e = store.lastError, !e.isEmpty {
                emptyRows.append(L.wrap(e, 9.5, color: T.p.warn, width: 250))
            }
            emptyRows.append(holder)
            listBox.show(emptyRows)
            return
        }

        var rows: [NSView] = []
        if let e = store.lastError {
            rows.append(L.wrap(e, 9.5, color: T.p.warn, width: 250))
        }
        for meta in failedShops.values where !(meta.remoteError ?? "").isEmpty {
            rows.append(L.wrap("当前显示的是缓存：\(meta.remoteError ?? "")", 9.5, color: T.p.warn, width: 250))
        }
        for (shop, chat) in list {
            rows.append(chatRow(shop, chat))
        }
        if store.sessionMeta.values.contains(where: { $0.hasMore }) {
            // 这里不写具体条数：limit 调过（200 → 100），写死数字就会变成
            // 主动告诉用户一个错的数，而且只在「确实超过」的人那儿出现。
            rows.append(L.wrap("平台还有更早的会话没加载。", 9.5, color: T.p.text2, width: 250))
        }
        listBox.show(rows, gap: 2)
    }

    private func chatRow(_ shop: String, _ chat: ChatSession) -> NSView {
        let p = T.p
        // 红条、「等 X 分钟」、排序只认 needsReply：人工标过已读的那一条不再算等待。
        let waiting = store.needsReply(shop, chat)
        let read = !waiting && store.isChatRead(shop, chat)

        let name = L(chat.who, 12, .medium)
        let shopTag = Tag(store.short(shop), p.text2, p.text2.withAlphaComponent(0.10), size: 9)

        let tail = waiting ? "等 " + Clock.ago(chat.minutes) : chat.when
        let time = L(tail, 9.5, .regular,
                     color: waiting && chat.minutes > 5 ? p.warn : p.text2, mono: true)
        let top = S.h([name, shopTag, Flex(), time], 6)
        let preview = L(chat.content ?? "—", 10.5, .regular, color: p.text2)

        if waiting {
            // 「等 5 分钟」随时间变。原地改这一格，列表不重建、滚动不动。
            let rowRef = chat
            ticking.add(time) {
                "等 " + Clock.ago(rowRef.minutes)
            }
        }

        let col = S.v([top, preview], 3)
        let row = TapRow(selected: PageChats.pickedChat == chat.chat_id && PageChats.pickedShop == shop, corner: 5)
        // 右侧那条给「已读」按钮 / 「已读」小标留位，别压在预览文字上。
        row.put(col, left: 8, right: (waiting || read) ? 48 : 8, top: 7, bottom: 7)
        if waiting && chat.minutes > 5 { row.accentBar = p.warn }
        row.onTap = { [weak self] in
            guard let self else { return }
            if PageChats.pickedChat == chat.chat_id && PageChats.pickedShop == shop { return }
            PageChats.pickedChat = chat.chat_id
            PageChats.pickedShop = shop
            self.msgs = []
            self.loadedKey = ""
            self.loadedStamp = ""
            self.loadError = nil
            self.msgGeneration &+= 1
            self.force()
        }

        // 只有真的在等你回的行才给按钮：点一下才算已读，点行本身只切会话。
        if waiting {
            let ack = B("已读", nil, style: .plain, size: 9.5, height: 20, width: 40,
                        a11y: "把 \(chat.who) 标为已读") { [weak self] in
                guard let self else { return }
                // 先把选中钉在这个会话上：标完它就不再算「等人回」，
                // 右侧不能顺手跳到别人身上，撤销按钮得留在原地。
                PageChats.pickedShop = shop
                PageChats.pickedChat = chat.chat_id
                self.store.setChatRead(shop, chat, true)
                self.store.showNotice("已标为已读：\(chat.who)。买家再发消息会重新提示。", seconds: 5)
            }
            ack.toolTip = "只对最后这一条生效；买家再发新消息会重新提示"
            row.addSubview(ack)
            NSLayoutConstraint.activate([
                ack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6),
                ack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
            row.putControl(ack)
        } else if read {
            // 标过的留个淡标记，免得以后忘了这条为什么不在「等人回」里。
            let done = Tag("已读", p.text2, p.text2.withAlphaComponent(0.10), size: 9)
            row.addSubview(done)
            NSLayoutConstraint.activate([
                done.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6),
                done.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
        }
        return row
    }

    private func force() {
        sig = ""
        build()
    }

    // MARK: 右列

    private func current() -> (shop: String, chat: ChatSession)? {
        let list = visible()
        if let s = PageChats.pickedShop, let c = PageChats.pickedChat,
           let hit = list.first(where: { $0.shop == s && $0.chat.chat_id == c })?.chat {
            return (s, hit)
        }
        // 刚标完已读的会话会掉出「等人回」筛选，但右侧不该跟着跳走：
        // 头部的撤销按钮要留在原地，否则点错一次就没地方反悔了。
        if let s = PageChats.pickedShop, let c = PageChats.pickedChat,
           let hit = store.chatList.first(where: { $0.shop == s && $0.chat.chat_id == c })?.chat,
           store.isChatRead(s, hit) {
            return (s, hit)
        }
        if let first = list.first(where: { store.needsReply($0.shop, $0.chat) }) { return first }
        return list.first
    }

    private func buildThread() {
        right.subviews.forEach { $0.removeFromSuperview() }

        guard let (shop, chat) = current() else {
            let hint = L.wrap("左边挑一个会话。列表按「谁等得久」排，最上面那个最该先回。",
                              11.5, color: T.p.text2, width: 380)
            right.addSubview(hint)
            NSLayoutConstraint.activate([
                hint.centerXAnchor.constraint(equalTo: right.centerXAnchor),
                hint.centerYAnchor.constraint(equalTo: right.centerYAnchor),
            ])
            return
        }

        let p = T.p
        PageChats.pickedShop = shop
        PageChats.pickedChat = chat.chat_id
        let key = chatKey(shop, chat.chat_id)
        let didSwitch = loadedKey != key
        if didSwitch {
            // 自动切会话时先把上一段的画面彻底清掉，避免短暂显示错人的聊天记录。
            loadedKey = key
            loadedStamp = ""
            msgs = []
            loadError = nil
            loadNotice = nil
            messagesHasMore = false
        }
        let isSending = sendingChats.contains(key)

        // 头
        let title = L(chat.who, 13, .semibold)
        let cachedTitle = chat.item_id.flatMap { store.itemTitle[$0] }
        let remoteTitle = (chat.item_title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let item = cachedTitle
            ?? (remoteTitle.isEmpty ? nil : remoteTitle)
            ?? chat.item_id
            ?? "—"
        let sub = L("\(store.short(shop))店 · \(item)", 10, .regular, color: p.text2)
        let titles = S.v([title, sub], 1)
        let stamp = chat.created_at ?? ""
        // 点这个要真的打一次平台拿最新消息，并且全程有反馈：
        // 图标位置换成「刷新中…」，拉完给出「刚刚更新」。
        let refresh = B(loadingMsg ? "刷新中…" : "", "arrow.clockwise",
                        style: .plain, size: 10, height: 24, width: loadingMsg ? 62 : 24,
                        action: { [weak self] in
                            guard let self, !self.loadingMsg else { return }
                            self.loadMsgs(shop, chat.chat_id, stamp: stamp, userInitiated: true)
                        })
        refresh.isEnabled = !loadingMsg
        // 标过已读的会话在这儿留个记号，点一下就能撤销 —— 列表里那行已经不再算等待，
        // 撤销入口必须看得见，否则误点一次就再也找不回来。
        var headViews: [NSView] = [titles, Flex()]
        if store.isChatRead(shop, chat) {
            let undo = B("已读 ✓", nil, style: .plain, size: 10, height: 24, width: 54,
                         a11y: "取消已读，重新算作等你回") { [weak self] in
                guard let self else { return }
                PageChats.pickedShop = shop
                PageChats.pickedChat = chat.chat_id
                self.store.setChatRead(shop, chat, false)
                self.store.showNotice("已恢复提示：\(chat.who)", seconds: 4)
            }
            undo.toolTip = "这条你标过已读。点一下撤销，重新算作等你回话"
            headViews.append(undo)
        }
        headViews.append(refresh)
        let head = S.h(headViews, 6)
        let headWrap = NSView()
        headWrap.translatesAutoresizingMaskIntoConstraints = false
        headWrap.addSubview(head)
        NSLayoutConstraint.activate([
            head.leadingAnchor.constraint(equalTo: headWrap.leadingAnchor, constant: 14),
            head.trailingAnchor.constraint(equalTo: headWrap.trailingAnchor, constant: -12),
            head.topAnchor.constraint(equalTo: headWrap.topAnchor, constant: 10),
            head.bottomAnchor.constraint(equalTo: headWrap.bottomAnchor, constant: -10),
            head.heightAnchor.constraint(greaterThanOrEqualToConstant: 26),
        ])
        let hair = Line()

        // 消息
        let box = Scroller(pad: 12, gap: 8)
        var bubbles: [NSView] = []
        if let error = sendErrors[key], !error.isEmpty {
            bubbles.append(L.wrap("发送失败：\(error)（草稿还在输入框）", 11, color: p.bad, width: 360))
        }
        if let e = loadError {
            bubbles.append(L.wrap("消息刷新失败：\(e)。下方可能不是最新，点右上重试。", 11, color: p.warn, width: 360))
        }
        if let notice = loadNotice, !notice.isEmpty {
            bubbles.append(L.wrap(notice, 10, color: p.text2, width: 360))
        }
        if let meta = store.sessionMeta[shop], !(meta.remoteError ?? "").isEmpty {
            bubbles.append(L.wrap("当前会话列表使用缓存：\(meta.remoteError ?? "")", 10, color: p.warn, width: 360))
        }
        if loadingMsg && msgs.isEmpty {
            bubbles.append(Blank.skeleton([0.5, 0.7, 0.4]))
        } else if msgs.isEmpty {
            if loadError == nil && loadNotice == nil {
                bubbles.append(L.wrap("这个会话没有消息。买家发来后会显示。", 11, color: p.text2, width: 360))
            }
        } else {
            for m in msgs.reversed() { bubbles.append(bubble(m)) }
            if messagesHasMore {
                bubbles.append(L.wrap("当前只显示最近 100 条消息，更早消息未加载。", 9.5, color: p.text2, width: 360))
            }
        }
        box.show(bubbles, gap: 8)

        // 快捷话术
        let quick = ["多少钱", "怎么用", "链接打不开"]
        var qbs: [NSView] = []
        for q in quick {
            qbs.append(B(q, nil, style: .plain, size: 10.5, height: 22, action: { [weak self] in
                self?.setDraft(q, for: key)
                self?.force()
            }))
        }
        let quickRow = S.h(qbs, 6)

        // 输入
        let input = NSView()
        input.wantsLayer = true
        input.layer?.backgroundColor = p.bg.cgColor
        input.layer?.cornerRadius = 7
        input.layer?.borderWidth = 1
        input.layer?.borderColor = p.sep.cgColor
        input.translatesAutoresizingMaskIntoConstraints = false

        let field = ComposeTextView()
        field.onSubmit = { [weak self] in
            guard let self else { return }
            self.sendButtonAction(shop: shop, chat: chat, key: key)
        }
        field.string = draft(key)
        field.font = T.font(12)
        field.textColor = p.text
        field.drawsBackground = false
        field.isRichText = false
        field.insertionPointColor = p.accent
        field.textContainerInset = NSSize(width: 4, height: 5)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = field
        scroll.translatesAutoresizingMaskIntoConstraints = false
        input.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: input.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: input.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: input.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: input.bottomAnchor, constant: -4),
        ])
        // 每次重建页面都会新建一个输入框。观察者必须跟着这个视图走，
        // 否则旧的会一直挂在 NotificationCenter 上（内存泄漏 + 幽灵回调）。
        if let old = draftWatcher { NotificationCenter.default.removeObserver(old) }
        draftWatcher = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: field, queue: .main
        ) { [weak self] note in
            guard let tv = note.object as? NSTextView else { return }
            Task { @MainActor in
                self?.setDraft(tv.string, for: key)
            }
        }

        let send = B(isSending ? "发送中…" : "发送",
                     "paperplane", style: .accent, size: 11.5, height: 46, action: { [weak self] in
            self?.sendButtonAction(shop: shop, chat: chat, key: key)
        })
        send.isEnabled = !isSending
        let compose = NSStackView()
        compose.orientation = .horizontal
        compose.spacing = 8
        compose.alignment = .bottom
        compose.translatesAutoresizingMaskIntoConstraints = false
        compose.addArrangedSubview(input)
        compose.addArrangedSubview(send)

        let tip = L("发出去就是你自己回的，跟手机上打的一样。", 9.5, .regular, color: p.text2)

        right.addSubview(headWrap)
        right.addSubview(hair)
        right.addSubview(box)
        right.addSubview(quickRow)
        right.addSubview(compose)
        right.addSubview(tip)
        NSLayoutConstraint.activate([
            headWrap.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            headWrap.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            headWrap.topAnchor.constraint(equalTo: right.topAnchor),

            hair.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            hair.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            hair.topAnchor.constraint(equalTo: headWrap.bottomAnchor),

            box.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            box.topAnchor.constraint(equalTo: hair.bottomAnchor),
            box.bottomAnchor.constraint(equalTo: quickRow.topAnchor, constant: -6),

            quickRow.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 12),
            quickRow.trailingAnchor.constraint(lessThanOrEqualTo: right.trailingAnchor, constant: -12),
            quickRow.bottomAnchor.constraint(equalTo: compose.topAnchor, constant: -6),

            compose.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 12),
            compose.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -12),
            compose.bottomAnchor.constraint(equalTo: tip.topAnchor, constant: -5),
            input.heightAnchor.constraint(equalToConstant: 46),

            tip.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 13),
            tip.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: -9),
        ])

        if didSwitch {
            loadMsgs(shop, chat.chat_id, stamp: stamp)
        } else if !loadingMsg && stamp != loadedStamp {
            // 轮询先更新了左侧会话摘要，这里补拉右侧消息。
            // 注意：回调成功前不能先推进 loadedStamp，否则失败一次就永远不重试。
            loadMsgs(shop, chat.chat_id, stamp: stamp)
        }
    }

    private func bubble(_ m: ChatMessage) -> NSView {
        let p = T.p
        let text = L.wrap(m.content ?? "", 12, color: p.text, width: 380)
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = (m.mine ? p.accentSoft : p.bg).cgColor
        box.layer?.cornerRadius = 10
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 9),
            text.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -9),
            text.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            text.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
        ])

        var items: [NSView] = [box]
        if let s = m.source {
            items.append(L("来源：\(s) · \(Clock.monthDayTime(m.created_at))", 9, .regular, color: p.text2))
        } else {
            items.append(L(Clock.monthDayTime(m.created_at), 9, .regular, color: p.text2))
        }
        let col = S.v(items, 2, align: m.mine ? .trailing : .leading)
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: holder.topAnchor),
            col.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            col.leadingAnchor.constraint(greaterThanOrEqualTo: holder.leadingAnchor),
            col.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor),
        ])
        if m.mine {
            col.trailingAnchor.constraint(equalTo: holder.trailingAnchor).isActive = true
        } else {
            col.leadingAnchor.constraint(equalTo: holder.leadingAnchor).isActive = true
        }
        return holder
    }

    /// 发送按钮和回车共用的唯一入口，避免两份逻辑分叉。
    private func sendButtonAction(shop: String, chat: ChatSession, key: String) {
        guard !sendingChats.contains(key) else { return }
        let snapshot = draft(key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snapshot.isEmpty else { return }

        // 必须在启动异步任务前置位，否则两次触发会各发一条。
        sendingChats.insert(key)
        sendErrors[key] = nil
        force()
        Task {
            let err = await store.send(shop, chat.chat_id,
                                       to: chat.buyer_id ?? chat.sender_id ?? "",
                                       text: snapshot)
            sendingChats.remove(key)
            if let err {
                // 失败与“当前看哪个会话”无关：错误按会话保存，草稿绝不丢。
                sendErrors[key] = err
                store.reportActionError("回复 \(chat.who) 失败：\(err)")
            } else {
                sendErrors[key] = nil
                // 只清掉“刚发出去的那段”。发送期间用户补打的下一句必须保留。
                if draft(key) == snapshot {
                    setDraft("", for: key)
                }
                if currentKey == key {
                    loadMsgs(shop, chat.chat_id)
                }
            }
            force()
        }
    }

    private func loadMsgs(_ shop: String, _ chat: String, stamp: String? = nil,
                          userInitiated: Bool = false) {
        msgGeneration &+= 1
        let generation = msgGeneration
        loadingMsg = true
        loadError = nil
        loadNotice = nil
        // 不在 build 回调里同步重建自己，下一轮主线程再刷新加载态。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.loadingMsg else { return }
            self.force()
        }
        Task {
            do {
                let got = try await Api.shared.messages(shop, chat)
                guard generation == self.msgGeneration else { return }
                self.msgs = got.messages
                self.messagesHasMore = got.hasMore
                if let remoteError = got.remoteError, !remoteError.isEmpty {
                    self.loadNotice = "远端消息没拉成，当前显示本地缓存：\(remoteError)"
                } else if got.source == "local_cache" {
                    self.loadNotice = "当前显示本地缓存消息。"
                } else if userInitiated {
                    // 点了才说；轮询自动拉的时候不要刷一行字打扰人。
                    self.loadNotice = "已是最新 · 刚刚更新"
                }
                if let stamp { self.loadedStamp = stamp }
            } catch {
                guard generation == self.msgGeneration else { return }
                // 旧消息继续显示，但必须有醒目的“可能不是最新”提示；
                // 不推进 loadedStamp，下一轮轮询仍会自动重试。
                self.loadError = error.localizedDescription
            }
            guard generation == self.msgGeneration else { return }
            self.loadingMsg = false
            self.force()
        }
    }
}

/// 回车发送，Shift+回车换行。
/// 注意中文输入法：组词期间回车是用来确认候选词的，必须放行，
/// 否则拼音一打完就把半截话发给买家。
final class ComposeTextView: NSTextView {

    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76   // 主回车 / 小键盘回车
        let shift = event.modifierFlags.contains(.shift)
        if isReturn && !shift && !hasMarkedText() {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }
}
