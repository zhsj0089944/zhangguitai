import AppKit

// MARK: - 命中测试的统一做法
//
// hitTest 的入参是**父视图坐标系**，自己再 convert 一次就必然算错（踩过两次）。
// 所以这里一律不碰坐标，只用 super 的结果判断：
//   要吃掉整块的 → super 有结果就返回 self
//   纯排版容器   → super 只命中自己就返回 nil，让点击落到父级
//   纯装饰层     → 永远 nil

/// 纯装饰层：背景、竖条、开关圆点。永远不接管点击。
class Decoration: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 纯排版容器：点在自己身上就放行给父级，点在子控件上就交给子控件。
class Passthrough: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

// MARK: - 基础图形：不拦截点击的叶子节点

/// 文字。只用来显示，永远不接管鼠标 —— 这样整行都能点。
final class L: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(_ text: String, _ size: CGFloat = 12.5, _ weight: NSFont.Weight = .regular,
         color: NSColor? = nil, mono: Bool = false) {
        super.init(frame: .zero)
        stringValue = text
        font = mono ? T.mono(size, weight) : T.font(size, weight)
        textColor = color ?? T.p.text
        lineBreakMode = .byTruncatingTail
        isSelectable = false
        isEditable = false
        drawsBackground = false
        isBezeled = false
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 多行自动换行
    static func wrap(_ text: String, _ size: CGFloat = 11.5, color: NSColor? = nil,
                     width: CGFloat = 600) -> L {
        let v = L(text, size, .regular, color: color)
        v.cell?.wraps = true
        v.cell?.isScrollable = false
        v.maximumNumberOfLines = 0
        v.preferredMaxLayoutWidth = width
        v.lineBreakMode = .byWordWrapping
        return v
    }
}

/// 单行输入框。背景/文字跟随主题，回车或失焦时回调。
/// 注意：不要覆盖 hitTest 去改坐标，输入框必须能正常接管鼠标。
final class Input: NSTextField, NSTextFieldDelegate {

    private var onCommit: ((String) -> Void)?
    /// 输入过程中实时回调（用于「边打边存」，避免用户没失焦就切页丢内容）。
    var onChange: ((String) -> Void)?

    init(_ value: String, placeholder: String = "", width: CGFloat = 220,
         mono: Bool = true, onCommit: ((String) -> Void)? = nil) {
        super.init(frame: .zero)
        self.onCommit = onCommit
        stringValue = value
        placeholderString = placeholder
        font = mono ? T.mono(12) : T.font(12)
        textColor = T.p.text
        drawsBackground = true
        backgroundColor = T.p.field
        isBezeled = true
        bezelStyle = .roundedBezel
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        translatesAutoresizingMaskIntoConstraints = false
        delegate = self
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: width)])
    }

    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(stringValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        onCommit?(stringValue)
    }
}

/// 图标。同样不接管鼠标。
final class I: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(_ symbol: String, size: CGFloat = 13, color: NSColor? = nil) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
        contentTintColor = color ?? T.p.text2
        imageScaling = .scaleProportionallyDown
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size + 3).isActive = true
        heightAnchor.constraint(equalToConstant: size + 3).isActive = true
        // 图标只是装饰，旁边的文字已经说明了意思，读屏时跳过。
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 排版容器。点空处不拦，点控件就交给控件。
final class S: Passthrough {

    static func h(_ views: [NSView], _ gap: CGFloat = 8,
                  align: NSLayoutConstraint.Attribute = .centerY) -> S {
        let s = S(views: views)
        s.orientation = .horizontal
        s.spacing = gap
        s.alignment = align
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    static func v(_ views: [NSView], _ gap: CGFloat = 8,
                  align: NSLayoutConstraint.Attribute = .leading) -> S {
        let s = S(views: views)
        s.orientation = .vertical
        s.spacing = gap
        s.alignment = align
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    /// 撑满宽度的竖排（卡片列表用）
    static func col(_ views: [NSView], _ gap: CGFloat = 12) -> S {
        let s = v(views, gap, align: .width)
        return s
    }
}


final class Dot: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    init(_ color: NSColor, _ size: CGFloat = 7) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = size / 2
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class Line: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    init(_ color: NSColor? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = (color ?? T.p.sep).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - 按钮

/// 自绘按钮。尺寸由「内边距 + 文字实际宽」算，字体变化也不会溢出。
final class B: NSView {

    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    /// 改字后重新算宽度（侧栏启停按钮会从「停止服务」变「启动服务」）
    var textWidth: CGFloat { label.attributedStringValue.size().width }

    enum Style { case plain, filled, accent, danger }

    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let stack = NSStackView()
    private var tracking: NSTrackingArea?
    private var hover = false
    private var press = false
    private var style: Style
    private var fixedW: CGFloat?
    private var fixedH: CGFloat
    private var flexible: Bool

    var action: (() -> Void)?
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.35; refresh() } }
    private(set) var isOn = false

    init(_ title: String, _ symbol: String? = nil, style: Style = .plain,
         size: CGFloat = 12, height: CGFloat = 28, width: CGFloat? = nil,
         flexible: Bool = false, a11y: String? = nil, action: (() -> Void)? = nil) {
        self.style = style
        self.action = action
        self.fixedW = width
        self.fixedH = height
        self.flexible = flexible
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = T.S.radiusC
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        // 读屏读出的名字：优先用调用方给的，其次是按钮文字（图标按钮没有文字时要显式给）。
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(a11y ?? (title.isEmpty ? nil : title))

        label.stringValue = title
        label.font = T.font(size, .medium)
        label.isSelectable = false
        label.isEditable = false
        label.drawsBackground = false
        label.isBezeled = false

        stack.orientation = .horizontal
        stack.spacing = 5
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .medium))
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: size + 2).isActive = true
            icon.heightAnchor.constraint(equalToConstant: size + 2).isActive = true
            stack.addArrangedSubview(icon)
        }
        if !title.isEmpty { stack.addArrangedSubview(label) }
        addSubview(stack)

        let padH: CGFloat = title.isEmpty && symbol != nil ? 0 : 9
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: padH),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -padH),
        ])
        if flexible {
            // 宽度交给父级约束，侧栏折叠时不会和固定宽度打架。
        } else if let w = width {
            widthAnchor.constraint(equalToConstant: w).isActive = true
        } else if title.isEmpty && symbol != nil {
            widthAnchor.constraint(equalToConstant: height).isActive = true
        } else {
            let textW = (title as NSString).size(withAttributes: [.font: T.font(size, .medium)]).width
            let iconW: CGFloat = symbol == nil ? 0 : size + 2 + 5
            widthAnchor.constraint(equalToConstant: ceil(textW + iconW) + padH * 2 + 4).isActive = true
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setOn(_ on: Bool) { isOn = on; refresh() }

    /// 运行态需要临时改底色时，文字/图标颜色必须一起改，避免浅色主题下白底白字。
    func setRuntimeColors(fill: NSColor, border: NSColor?, title: NSColor, iconColor: NSColor) {
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = border == nil ? 0 : 1
        layer?.borderColor = border?.cgColor
        label.textColor = title
        icon.contentTintColor = iconColor
    }

    func setTitle(_ t: String) {
        guard label.stringValue != t else { return }
        label.stringValue = t
        if style == .plain || style == .accent { retitle(t) }
    }

    private func retitle(_ t: String) {
        // 宽度跟着文字走（少量按钮会动态改字）
        for c in constraints where c.firstAttribute == .width && c.secondItem == nil {
            c.isActive = false
        }
        if fixedW != nil || flexible { return }
        let textW = (t as NSString).size(withAttributes: [.font: label.font!]).width
        let iconW: CGFloat = icon.image == nil ? 0 : 22
        widthAnchor.constraint(equalToConstant: ceil(textW + iconW) + 22).isActive = true
    }

    private func refresh() {
        let p = T.p
        switch style {
        case .accent:
            layer?.backgroundColor = p.accent.cgColor
            layer?.borderWidth = 0
            label.textColor = .white
            icon.contentTintColor = .white
        case .filled:
            layer?.backgroundColor = (isOn ? p.accentSoft : (hover ? p.hover : p.field)).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = isOn ? p.accent.withAlphaComponent(0.5).cgColor : p.sep.cgColor
            label.textColor = isOn ? p.accent : p.text
            icon.contentTintColor = isOn ? p.accent : p.text2
        case .danger:
            layer?.backgroundColor = (hover ? p.badSoft : NSColor.clear).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = hover ? p.bad.withAlphaComponent(0.45).cgColor : p.sep.cgColor
            label.textColor = p.bad
            icon.contentTintColor = p.bad
        case .plain:
            layer?.backgroundColor = (hover ? p.hover : p.field.withAlphaComponent(0.6)).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = p.sep.cgColor
            label.textColor = p.text
            icon.contentTintColor = p.text2
        }
        alphaValue = press ? 0.75 : (isEnabled ? 1 : 0.35)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with e: NSEvent) { hover = true; refresh() }
    override func mouseExited(with e: NSEvent) { hover = false; press = false; refresh() }

    override func mouseDown(with e: NSEvent) {
        guard isEnabled else { return }
        press = true
        refresh()
    }

    override func mouseUp(with e: NSEvent) {
        guard isEnabled, press else { press = false; return }
        press = false
        refresh()
        let inside = bounds.contains(convert(e.locationInWindow, from: nil))
        if inside { action?() }
    }
}

/// 一组互斥选项。选中项用强调色实心。
final class Tabs: NSView {

    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 标签栏整体可点：点空白也交给最近的按钮不好算，干脆整体吃掉，
        // 具体选哪个由子按钮自己判定（子按钮在前面，优先命中）
        let hit = super.hitTest(point)
        return hit === self ? self : hit
    }

    private var items: [B] = []
    private var titles: [String] = []
    private(set) var index = 0
    var onChange: ((Int) -> Void)?
    /// 横向滚动容器：标签放不下时内部滚动，不撑破外层布局。
    private let scroller = NSScrollView()

    init(_ titles: [String], index: Int = 0, height: CGFloat = 28, maxWidth: CGFloat = 520) {
        self.titles = titles
        self.index = index
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = T.p.field.cgColor
        layer?.cornerRadius = T.S.radiusC
        layer?.borderWidth = 1
        layer?.borderColor = T.p.sep.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)

        // 标签栏内部改成横向滚动：标签数量随账号数变化，放不下时能滚，
        // 而不是整条顶出容器被裁掉（原来宽度写死成所有标签之和）。
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.drawsBackground = false
        scroller.borderType = .noBorder
        scroller.hasVerticalScroller = false
        scroller.hasHorizontalScroller = true
        scroller.autohidesScrollers = true
        scroller.scrollerStyle = .overlay
        scroller.verticalScrollElasticity = .none
        scroller.horizontalScrollElasticity = .allowed
        addSubview(scroller)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        scroller.documentView = row

        NSLayoutConstraint.activate([
            scroller.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            scroller.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            scroller.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            // 文档视图高度跟随可视区；宽度不约束，由标签内容自己撑开才能横向溢出。
            row.topAnchor.constraint(equalTo: scroller.contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroller.contentView.leadingAnchor),
            row.heightAnchor.constraint(equalTo: scroller.contentView.heightAnchor),
        ])
        var total: CGFloat = 4
        for (i, t) in titles.enumerated() {
            let textW = (t as NSString).size(withAttributes: [.font: T.font(11.5, .medium)]).width
            let w = ceil(textW) + 20
            let b = B(t, nil, style: .filled, size: 11.5,
                      height: height - 4, width: w,
                      action: { [weak self] in self?.pick(i) })
            b.layer?.cornerRadius = 5
            b.layer?.borderWidth = 0
            total += w + 2
            items.append(b)
            row.addArrangedSubview(b)
        }
        // 内容窄时按内容宽度，宽过上限就停在 maxWidth、内部横向滚动。
        // 用优先级而不是硬等号：账号多了不能让整条标签栏把兄弟控件挤出去。
        let fit = widthAnchor.constraint(equalToConstant: total)
        fit.priority = .defaultHigh
        NSLayoutConstraint.activate([
            fit,
            widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
        ])
        paint()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 标签栏整体吃鼠标是为了防穿透，但滚轮/横滑必须转给内部滚动视图，
    /// 否则账号一多就滚不到后面的标签。
    override func scrollWheel(with event: NSEvent) {
        scroller.scrollWheel(with: event)
    }

    private func pick(_ i: Int) {
        guard i != index else { return }
        index = i
        paint()
        onChange?(i)
    }


    private func paint() {
        for (i, b) in items.enumerated() {
            b.setOn(i == index)
        }
    }
}

/// 开关
final class Toggle: NSView {

    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    private let knob = Decoration()
    private var on: Bool
    var onChange: ((Bool) -> Void)?
    var isEnabled = true {
        didSet { alphaValue = isEnabled ? 1 : 0.4 }
    }

    /// 读屏时的名字，由调用方按开关含义填写。
    var a11yLabel: String? { didSet { setAccessibilityLabel(a11yLabel) } }

    init(_ on: Bool) {
        self.on = on
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 36).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
        layer?.cornerRadius = 10
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityValue(on ? 1 : 0)

        knob.wantsLayer = true
        knob.layer?.backgroundColor = NSColor.white.cgColor
        knob.layer?.cornerRadius = 8
        knob.layer?.shadowColor = NSColor.black.cgColor
        knob.layer?.shadowOpacity = 0.22
        knob.layer?.shadowRadius = 1
        knob.layer?.shadowOffset = .zero
        addSubview(knob)
        paint()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        knob.frame = NSRect(x: on ? bounds.width - 18 : 2, y: 2, width: 16, height: 16)
    }

    func set(_ v: Bool, notify: Bool = false) {
        guard v != on else { return }
        on = v
        paint()
        if notify { onChange?(v) }
    }

    private func paint() {
        layer?.backgroundColor = (on ? T.p.accent : T.p.sep).cgColor
        setAccessibilityValue(on ? 1 : 0)
        needsLayout = true
    }

    override func mouseDown(with e: NSEvent) {
        guard isEnabled else { return }
        on.toggle()
        paint()
        onChange?(on)
    }
}


// MARK: - 卡片 / 标签

final class Card: NSView {

    let body = S()

    init(_ views: [NSView] = [], pad: CGFloat = T.S.cardPad, gap: CGFloat = 10,
         fill: NSColor? = nil, accent: NSColor? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = (fill ?? T.p.card).cgColor
        layer?.cornerRadius = T.S.radius
        layer?.borderWidth = 1
        layer?.borderColor = T.p.sep.cgColor
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        body.orientation = .vertical
        body.spacing = gap
        body.alignment = .width
        body.translatesAutoresizingMaskIntoConstraints = false

        var topInset = pad
        if let accent {
            let strip = Decoration()
            strip.wantsLayer = true
            strip.layer?.backgroundColor = accent.cgColor
            strip.translatesAutoresizingMaskIntoConstraints = false
            addSubview(strip)
            NSLayoutConstraint.activate([
                strip.leadingAnchor.constraint(equalTo: leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: trailingAnchor),
                strip.topAnchor.constraint(equalTo: topAnchor),
                strip.heightAnchor.constraint(equalToConstant: 3),
            ])
            topInset = pad + 3
        }

        addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            body.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
        ])
        for v in views { add(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func add(_ v: NSView) {
        body.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }
}

/// 小标签
final class Tag: NSView {
    private let label: NSTextField
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(_ text: String, _ color: NSColor, _ bg: NSColor, size: CGFloat = 10.5) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = bg.cgColor
        layer?.cornerRadius = T.S.radiusTag
        translatesAutoresizingMaskIntoConstraints = false

        label.font = T.font(size, .medium)
        label.textColor = color
        label.isSelectable = false
        label.isEditable = false
        label.drawsBackground = false
        label.isBezeled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 19),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - 可点击行

/// 整行可点。子视图全是 L / I / S，不会抢走鼠标。
final class TapRow: NSView {

    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    /// 行内需要自己收点击的控件（比如「已读」按钮）。
    /// 除这些以外，点哪都算整行点击 —— 和原来的行为完全一致。
    /// 注意：这里只用 super.hitTest 的返回值 + 视图树往上找，绝不在 hitTest 里算坐标。
    private var controls: [NSView] = []

    func putControl(_ v: NSView) { controls.append(v) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var node: NSView? = hit
        while let cur = node, cur !== self {
            if let c = controls.first(where: { $0 === cur }) { return c }
            node = cur.superview
        }
        return self
    }

    private let bg = Decoration()
    private(set) var selected = false
    private var hover = false
    private var tracking: NSTrackingArea?
    var onTap: (() -> Void)?
    var accentBar: NSColor? { didSet { paintAccent() } }
    /// 选中时的底色，默认浅强调色（导航行用实心强调色）
    var selectedFill: NSColor? { didSet { paint() } }
    private let bar = NSView()

    init(selected: Bool = false, corner: CGFloat = 6) {
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        bg.wantsLayer = true
        bg.layer?.cornerRadius = corner
        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.autoresizingMask = [.width, .height]
        addSubview(bg)

        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = true
        addSubview(bar)

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            bg.topAnchor.constraint(equalTo: topAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            bar.widthAnchor.constraint(equalToConstant: 3),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        paint()
    }

    required init?(coder: NSCoder) { fatalError() }

    func put(_ content: NSView, left: CGFloat = 8, right: CGFloat = 8,
             top: CGFloat = 0, bottom: CGFloat = 0) {
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -right),
            content.topAnchor.constraint(equalTo: topAnchor, constant: top),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottom),
        ])
    }

    func setSelected(_ v: Bool) { selected = v; paint() }

    private func paintAccent() {
        bar.layer?.backgroundColor = (accentBar ?? .clear).cgColor
        bar.isHidden = accentBar == nil
    }

    private func paint() {
        let p = T.p
        if selected {
            bg.layer?.backgroundColor = p.accentSoft.cgColor
        } else if hover {
            bg.layer?.backgroundColor = p.hover.cgColor
        } else {
            bg.layer?.backgroundColor = .clear
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with e: NSEvent) { hover = true; paint() }
    override func mouseExited(with e: NSEvent) { hover = false; paint() }
    override func mouseDown(with e: NSEvent) { onTap?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - 滚动区

/// 竖向滚动，换内容时保留滚动位置。
final class Scroller: NSView {

    private let scroll = NSScrollView()
    private let doc = Flipped()
    private let stack = NSStackView()
    private let pad: CGFloat
    private var content: [NSView] = []

    init(pad: CGFloat = T.S.page, gap: CGFloat = 12) {
        self.pad = pad
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = gap
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc

        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -pad),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -pad),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var offset: CGFloat {
        get { scroll.contentView.bounds.origin.y }
        set {
            scroll.layoutSubtreeIfNeeded()
            let maxY = max(0, doc.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(newValue, maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func show(_ views: [NSView], gap: CGFloat? = nil) {
        let keep = offset
        if let g = gap { stack.spacing = g }
        // 换内容时把旧视图彻底拆干净：光 removeFromSuperview 会留下约束，
        // 那些约束仍然攥着旧视图不放（实测反复切页内存会涨到 200MB+ 不降）。
        for old in stack.arrangedSubviews {
            old.removeFromSuperview()
            old.removeConstraints(old.constraints)
            old.subviews.forEach { $0.removeConstraints($0.constraints) }
        }
        content = views
        for v in views {
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        layoutSubtreeIfNeeded()
        offset = keep
    }
}

final class Flipped: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 空态 / 骨架

enum Blank {

    static func card(_ title: String, _ desc: String, buttons: [B] = []) -> NSView {
        var rows: [NSView] = [L(title, 13, .semibold), L.wrap(desc, 11.5, color: T.p.text2, width: 520)]
        if !buttons.isEmpty {
            let h = S.h(buttons, 8)
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(h)
            NSLayoutConstraint.activate([
                h.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
                h.topAnchor.constraint(equalTo: holder.topAnchor),
                h.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            ])
            rows.append(holder)
        }
        let c = Card(rows, pad: 24, gap: 10)
        c.body.alignment = .centerX
        return c
    }

    static func skeleton(_ rows: [CGFloat]) -> NSView {
        var bars: [NSView] = []
        for w in rows {
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.backgroundColor = T.p.hover.cgColor
            bar.layer?.cornerRadius = 4
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.heightAnchor.constraint(equalToConstant: 12).isActive = true
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                bar.topAnchor.constraint(equalTo: holder.topAnchor),
                bar.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                bar.widthAnchor.constraint(equalTo: holder.widthAnchor, multiplier: w),
            ])
            bars.append(holder)
        }
        return Card(bars, pad: 18, gap: 12)
    }
}

// MARK: - 确认对话框

/// 所有「会真的停服务 / 停店 / 重复发货」的操作统一走这里，
/// 默认按钮是安全的那个（取消），危险按钮必须明确点击。
enum Confirm {
    @MainActor
    static func ask(title: String, detail: String, action: String,
                    destructive: Bool = true) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = destructive ? .warning : .informational
        alert.addButton(withTitle: "取消")          // 第一个按钮 = 回车默认项，走安全分支
        alert.addButton(withTitle: action)
        return alert.runModal() == .alertSecondButtonReturn
    }
}

// MARK: - 小工具

enum W {
    /// 定宽容器（表格列对齐只能靠它）
    static func fix(_ v: NSView, _ w: CGFloat) -> NSView {
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        v.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(v)
        NSLayoutConstraint.activate([
            holder.widthAnchor.constraint(equalToConstant: w),
            v.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            v.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor),
            v.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        holder.setContentCompressionResistancePriority(.required, for: .horizontal)
        holder.setContentHuggingPriority(.required, for: .horizontal)
        return holder
    }

    static func right(_ text: String, size: CGFloat = 11.5,
                      color: NSColor? = nil, mono: Bool = true, width: CGFloat) -> NSView {
        let l = L(text, size, .regular, color: color, mono: mono)
        l.alignment = .right
        return fix(l, width)
    }

    static func money(_ v: Double, size: CGFloat = 11.5, color: NSColor? = nil, width: CGFloat = 68) -> NSView {
        right(String(format: "¥%.2f", v), size: size, color: color, width: width)
    }

    static func dotTag(_ text: String, _ color: NSColor, _ bg: NSColor) -> Tag {
        Tag(text, color, bg)
    }
}

// MARK: - 表格行：自己算列宽，保证表头和每一行严格对齐

final class TableRow: NSView {

    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    /// 除了「商品」列，其余列宽固定；商品列吃掉剩下的宽度
    struct Spec {
        var time: CGFloat = 78
        var shop: CGFloat = 28
        var buyer: CGFloat = 76
        var money: CGFloat = 62
        var state: CGFloat = 56
        var ship: CGFloat = 78
        var gap: CGFloat = 8
        var inset: CGFloat = 12
    }

    var spec = Spec()
    private var cells: [NSView] = []
    var onTap: (() -> Void)?
    var accentBar: NSColor? { didSet { paintBar() } }

    private let bg = Decoration()
    private let bar = Decoration()
    private var hover = false
    private var tracking: NSTrackingArea?
    private(set) var selected = false
    var selectedFill: NSColor?

    override var isFlipped: Bool { true }

    init(_ spec: Spec = Spec(), height: CGFloat = T.S.row) {
        self.spec = spec
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: height).isActive = true

        bg.wantsLayer = true
        bg.layer?.cornerRadius = 5
        addSubview(bg)

        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        bar.isHidden = true
        addSubview(bar)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 依次塞进 7 个单元格：时间 / 店 / 商品 / 买家 / 金额 / 状态 / 发货
    func fill(_ views: [NSView]) {
        cells = views
        cells.forEach { addSubview($0) }
        needsLayout = true
    }

    func setSelected(_ v: Bool) { selected = v }

    override func layout() {
        super.layout()
        let s = spec
        bg.frame = bounds
        bar.frame = NSRect(x: 1, y: 5, width: 3, height: max(0, bounds.height - 10))

        let w = bounds.width
        guard w > 0 else { return }
        var x = s.inset
        let fixed = s.time + s.shop + s.buyer + s.money + s.state + s.ship + s.gap * 6
        let titleW = max(60, w - s.inset * 2 - fixed)
        let widths: [CGFloat] = [s.time, s.shop, titleW, s.buyer, s.money, s.state, s.ship]

        for (i, v) in cells.enumerated() where i < widths.count {
            let cw = widths[i]
            v.frame = NSRect(x: x, y: 0, width: cw, height: bounds.height)
            v.needsLayout = true
            v.layoutSubtreeIfNeeded()
            x += cw + s.gap
        }

        let p = T.p
        if selected {
            bg.layer?.backgroundColor = (selectedFill ?? p.accentSoft).cgColor
        } else if hover {
            bg.layer?.backgroundColor = p.hover.cgColor
        } else {
            bg.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    private func paintBar() {
        bar.layer?.backgroundColor = (accentBar ?? .clear).cgColor
        bar.isHidden = accentBar == nil
        needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with e: NSEvent) { hover = true; needsLayout = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsLayout = true }
    override func mouseDown(with e: NSEvent) { onTap?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// 单元格：内容靠左或靠右，垂直居中。用 frame 布局，因为父级 TableRow 是手动排的。
final class Cell: NSView {
    private let child: NSView
    private let right: Bool
    private let pad: CGFloat

    override var isFlipped: Bool { true }

    init(_ v: NSView, right: Bool = false, pad: CGFloat = 0) {
        child = v
        self.right = right
        self.pad = pad
        super.init(frame: .zero)
        // 父级 TableRow 是手动排 frame 的，这里不能开 Auto Layout，否则 frame 不生效
        translatesAutoresizingMaskIntoConstraints = true
        child.translatesAutoresizingMaskIntoConstraints = true
        addSubview(child)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // 直接把整列交给内容，让文字自己按 alignment 排（右侧列右对齐）。
        // 不要按 intrinsicContentSize 收缩 —— 会把文字挤成省略号。
        let h = max(12, min(bounds.height, child.intrinsicContentSize.height))
        child.frame = NSRect(x: pad, y: (bounds.height - h) / 2,
                             width: max(0, bounds.width - pad * 2), height: h)
    }
}
