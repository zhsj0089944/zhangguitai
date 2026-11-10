import AppKit

/// 深色 / 浅色。默认深色。
enum Skin: String, CaseIterable {
    case dark, light

    var title: String {
        switch self {
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }
}

/// 一套配色。数值来自设计稿 tokens.json。
struct Palette {
    let bg: NSColor
    let card: NSColor
    let side: NSColor
    let sep: NSColor
    let hover: NSColor
    let field: NSColor
    let text: NSColor
    let text2: NSColor
    let accent: NSColor
    let accentSoft: NSColor
    let ok: NSColor
    let warn: NSColor
    let warnSoft: NSColor
    let bad: NSColor
    let badSoft: NSColor
}

extension NSColor {
    convenience init(hex: String, alpha: CGFloat = 1) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = CGFloat((v >> 16) & 0xFF) / 255
        let g = CGFloat((v >> 8) & 0xFF) / 255
        let b = CGFloat(v & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

enum SkinStore {

    private static let d = UserDefaults.standard

    static var current: Skin {
        get {
            d.synchronize()
            return Skin(rawValue: d.string(forKey: "skin") ?? "") ?? .dark
        }
        set {
            d.set(newValue.rawValue, forKey: "skin")
            d.synchronize()
        }
    }

    static var isDark: Bool { current == .dark }

    /// 只做两档：深 ↔ 浅。三档（带跟随系统）在这一版是多余的。
    static func cycle() -> Skin {
        current = (current == .dark) ? .light : .dark
        return current
    }

    static var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    /// 换肤的统一出口。由 AppDelegate 挂上「重建整个窗口」——
    /// 颜色都是静态 hex，只重建当前页会留下侧栏和顶栏还是旧色。
    static var onSwitch: (() -> Void)?

    /// 切到指定档并重画整个窗口
    static func use(_ skin: Skin) {
        guard skin != current else { return }
        current = skin
        onSwitch?()
    }
}

/// 全局取色入口。所有颜色都从这里拿，别在页面里写死。
enum T {

    static var dark: Palette {
        Palette(
            bg: NSColor(hex: "#1C1C1E"), card: NSColor(hex: "#2A2A2D"), side: NSColor(hex: "#232326"),
            sep: NSColor(hex: "#3A3A3D"), hover: NSColor(hex: "#34343A"), field: NSColor(hex: "#3A3A3F"),
            text: NSColor(hex: "#F2F2F4"), text2: NSColor(hex: "#9A9AA2"),
            accent: NSColor(hex: "#0A84FF"), accentSoft: NSColor(hex: "#0A84FF", alpha: 0.18),
            ok: NSColor(hex: "#30D158"), warn: NSColor(hex: "#FF9F0A"), warnSoft: NSColor(hex: "#FF9F0A", alpha: 0.14),
            bad: NSColor(hex: "#FF453A"), badSoft: NSColor(hex: "#FF453A", alpha: 0.14)
        )
    }

    static var light: Palette {
        Palette(
            bg: NSColor(hex: "#F5F5F7"), card: NSColor(hex: "#FFFFFF"), side: NSColor(hex: "#ECECEF"),
            sep: NSColor(hex: "#DEDEE3"), hover: NSColor(hex: "#EAEAEF"), field: NSColor(hex: "#FFFFFF"),
            text: NSColor(hex: "#1D1D1F"), text2: NSColor(hex: "#6E6E73"),
            accent: NSColor(hex: "#0A6CD8"), accentSoft: NSColor(hex: "#0A6CD8", alpha: 0.12),
            ok: NSColor(hex: "#1E9E4A"), warn: NSColor(hex: "#C77400"), warnSoft: NSColor(hex: "#FF9F0A", alpha: 0.14),
            bad: NSColor(hex: "#D0342C"), badSoft: NSColor(hex: "#FF453A", alpha: 0.10)
        )
    }

    static var p: Palette { SkinStore.isDark ? dark : light }

    // 尺寸表。改这里就能整体调，页面里别再写魔数。
    enum S {
        static let side: CGFloat = 200
        static let sideMini: CGFloat = 60
        static let bar: CGFloat = 50           // 顶栏
        static let row: CGFloat = 34           // 表格行
        static let cardPad: CGFloat = 16
        static let gap: CGFloat = 12
        static let ctrlH: CGFloat = 30         // 按钮/输入框高
        static let ctrlH2: CGFloat = 32        // 主按钮高
        static let radius: CGFloat = 10
        static let radiusC: CGFloat = 7
        static let radiusTag: CGFloat = 5
        static let page: CGFloat = 20          // 内容左右留白
        static let winW: CGFloat = 1180
        static let winH: CGFloat = 760
        static let minW: CGFloat = 1000
        static let minH: CGFloat = 640
    }

    enum F {
        static let title: CGFloat = 17
        static let section: CGFloat = 13
        static let body: CGFloat = 12.5
        static let small: CGFloat = 11
        static let tiny: CGFloat = 10.5
        static let num: CGFloat = 18
    }

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}
