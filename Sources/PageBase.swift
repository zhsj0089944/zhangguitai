import AppKit

/// 页面协议。`sig` 记录上次构建时的数据指纹，轮询没变化就不重建 —— 否则输入框和滚动位置会丢。
@MainActor
protocol Page: AnyObject {
    var view: NSView { get }
    var sig: String { get set }
    func signature() -> String
    func build()
    /// 只更新「3 分钟前」这类随时间变的文字，不重建整页。
    /// 以前是靠把分钟数塞进 signature 让整页每分钟重建一次来刷新，
    /// 代价是滚动位置、展开状态、输入焦点全被清掉 —— 看着像在闪。
    func tick()
}

extension Page {
    func rebuildIfNeeded() {
        let s = signature()
        guard s != sig else { return }
        sig = s
        build()
    }

    func tick() {}
}

/// 随时间变的文字。构建页面时登记，之后原地改字符串，不碰视图结构。
@MainActor
final class Ticking {
    private var items: [(NSTextField, () -> String)] = []

    func reset() { items.removeAll() }

    func add(_ field: NSTextField, _ text: @escaping () -> String) {
        items.append((field, text))
    }

    func tick() {
        for (field, text) in items {
            let next = text()
            if field.stringValue != next { field.stringValue = next }
        }
    }
}

/// 一条竖滚动页面的通用骨架
@MainActor
class ScrollPage: Page {
    let store: Store
    let view: NSView = Flipped()
    let scroll: Scroller
    var sig = ""

    init(store: Store, gap: CGFloat = 12) {
        self.store = store
        scroll = Scroller(pad: T.S.page, gap: gap)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func signature() -> String { "" }
    func build() {}
}

// MARK: - 服务没开

extension ScrollPage {
    func requireService() -> Bool {
        guard store.serviceUp else {
            let btn = B("启动服务", "power", style: .accent, action: { [weak self] in
                self?.store.toggleService()
            })
            scroll.show([Blank.card("服务没开着",
                                    "所有数据都从本机服务取，服务停了这里就是空的。点下面启动，十几秒就好。",
                                    buttons: [btn])])
            return false
        }
        return true
    }
}

// MARK: - 状态色

enum Look {

    static func statusColor(_ s: String) -> (NSColor, NSColor) {
        let p = T.p
        switch s {
        case "completed": return (p.text2, p.text2.withAlphaComponent(0.10))
        case "shipped": return (p.accent, p.accentSoft)
        case "pending_ship": return (p.warn, p.warnSoft)
        case "refunding": return (p.warn, p.warnSoft)
        case "partial_success", "partial_pending_finalize": return (p.warn, p.warnSoft)
        case "pending_payment": return (p.text2, p.text2.withAlphaComponent(0.10))
        default: return (p.text2, p.text2.withAlphaComponent(0.10))
        }
    }

    static func shipColor(_ s: Ship, live: Bool) -> (NSColor, NSColor) {
        let p = T.p
        if s == .sent { return (p.ok, p.ok.withAlphaComponent(0.13)) }
        if s.isBad { return live ? (p.warn, p.warnSoft) : (p.text2, p.text2.withAlphaComponent(0.08)) }
        return (p.text2, p.text2.withAlphaComponent(0.08))
    }

    static func linkColor(_ l: Account.Link) -> NSColor {
        let p = T.p
        switch l {
        case .fine: return p.ok
        case .fake: return p.warn
        case .retrying: return p.warn
        case .down: return p.bad
        case .off: return p.text2
        }
    }

    static func linkBg(_ l: Account.Link) -> NSColor {
        let p = T.p
        switch l {
        case .fine: return p.ok.withAlphaComponent(0.13)
        case .fake: return p.warnSoft
        case .retrying: return p.warnSoft
        case .down: return p.badSoft
        case .off: return p.text2.withAlphaComponent(0.10)
        }
    }
}
