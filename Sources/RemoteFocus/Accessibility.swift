import AppKit
import ApplicationServices

/// 一个可切换的栏。rect 用屏幕坐标（左上角为原点，和辅助功能接口、CGEvent 一致）。
/// 输入框也是一站：界面上有几个输入框（主对话、side chat…）就有几站。
struct Section {
    let element: AXUIElement?
    let rect: CGRect
    let label: String
    var isInput: Bool = false
    var order: Int = 0          // 文档顺序（= Tab 顺序 / 读屏软件里地标的顺序）
}

/// 只读 App 自己暴露的辅助功能信息，不认具体 App：
///   栏 = App 标注的 ARIA landmark / 有名字的区域；输入框 = 可编辑的多行文本区；顺序 = 界面结构里的先后。
final class AXHelper {
    struct Layout {
        let window: CGRect
        let sections: [Section]          // 界面上实际存在的栏和输入框，从左到右、从上到下
    }

    private var cache: (pid: pid_t, layout: Layout, at: Date)?
    private let cacheLifetime: TimeInterval = 1.5
    private let maximumNodes = 20_000

    func wakeAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        let result = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if result == .attributeUnsupported {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    func invalidate() { cache = nil }

    func layout(pid: pid_t) -> Layout? {
        if let cache, cache.pid == pid, Date().timeIntervalSince(cache.at) < cacheLifetime { return cache.layout }
        wakeAccessibility(pid: pid)
        guard let window = focusedWindow(pid: pid), let w = frame(of: window) else { return nil }

        var candidates: [Section] = []
        var inputs: [Section] = []

        // 一次深度优先遍历（= 文档顺序）：同时找输入框和所有栏。
        var stack: [AXUIElement] = [window]
        var visited = 0
        while let element = stack.popLast(), visited < maximumNodes {
            visited += 1
            let role = string(element, kAXRoleAttribute) ?? ""
            let subrole = string(element, kAXSubroleAttribute) ?? ""

            // 输入框 = 可编辑的多行文本区（标准角色 AXTextArea + 内容可写）。
            // 搜索框、改名框是单行（AXTextField），只读的文本区内容不可写，都自然排除，不看名字。
            if role == "AXTextArea", isEditable(element), let f = visibleFrame(of: element) {
                let name = [labelOf(element), string(element, kAXPlaceholderValueAttribute) ?? ""].first { !$0.isEmpty } ?? ""
                inputs.append(Section(element: element, rect: f.intersection(w),
                                      label: name.isEmpty ? "输入框" : name, isInput: true, order: visited))
            }

            // 栏 = ARIA landmark（导航 / 主区 / 侧栏 / region…），或带名字的 application 分组。
            let isLandmark = subrole.hasPrefix("AXLandmark")
            let isNamedGroup = subrole == "AXApplicationGroup" && !labelOf(element).isEmpty
            if isLandmark || isNamedGroup, let f = visibleFrame(of: element) {
                let rect = f.intersection(w)
                if rect.height >= w.height * 0.25, rect.width >= 60 {
                    var label = labelOf(element)
                    if label.isEmpty { label = String(subrole.dropFirst("AXLandmark".count)) }
                    if label.isEmpty { label = "区域" }
                    candidates.append(Section(element: element, rect: rect, label: label, order: visited))
                }
            }
            stack.append(contentsOf: children(of: element).reversed())
        }

        let sections = (reduce(candidates) + inputs).sorted { $0.order < $1.order }
        let result = Layout(window: w, sections: sections)
        cache = (pid, result, Date())
        return result
    }

    /// 去掉重复和「外壳」：几乎重合的两块留有名字的那块；包着别的栏的大容器去掉，只留最里面能独立看的那几块。
    private func reduce(_ input: [Section]) -> [Section] {
        var list: [Section] = []
        for s in input.sorted(by: { area($0.rect) > area($1.rect) }) {
            if let i = list.firstIndex(where: { nearlySame($0.rect, s.rect) }) {
                let kept = list[i]
                if isGeneric(kept.label) && !isGeneric(s.label) { list[i] = s }
                continue
            }
            list.append(s)
        }
        // 「外壳」= 里面的栏几乎把它铺满（比如只是包着侧栏两半的容器、包着对话区的主区）：去掉外壳，留里面的。
        // 里面只有一小块栏（比如对话里一张可滚动表格）的不是外壳，两个都留。
        let all = list
        list = all.filter { outer in
            let inners = all.filter { inner in
                guard let a = inner.element, let b = outer.element, !CFEqual(a, b) else { return false }
                return outer.rect.insetBy(dx: -2, dy: -2).contains(inner.rect)
            }
            let topInners = inners.filter { x in !inners.contains { y in
                !CFEqual(x.element!, y.element!) && y.rect.insetBy(dx: -2, dy: -2).contains(x.rect) } }
            let covered = topInners.reduce(0) { $0 + area($1.rect) }
            return covered < area(outer.rect) * 0.8
        }
        return list
    }

    private func isGeneric(_ label: String) -> Bool {
        ["Main", "Region", "Navigation", "Complementary", "Banner", "ContentInfo", "区域"].contains(label)
    }
    private func area(_ r: CGRect) -> CGFloat { r.width * r.height }
    private func nearlySame(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        guard !i.isNull else { return false }
        return area(i) / max(area(a), area(b)) > 0.85
    }

    // MARK: 焦点（和系统的键盘焦点是同一个东西）

    /// 进一个栏时把系统键盘焦点放到哪：
    ///   1. 栏里被 App 标成选中 / 当前的那项（比如当前会话）
    ///   2. 栏的「主体内容」：占了这一栏一大半、能接焦点的那块（网页文档、可滚动区域）。
    ///      焦点在这上面，方向键就是浏览器原生的滚动。
    ///   3. 栏本身能接焦点 → 给栏本身
    ///   4. 栏里第一个看得见、能接焦点的东西
    /// 之后方向键、OK 都原样交给 App，由它和浏览器按标准规则处理。
    func focus(section: Section) -> AXUIElement? {
        guard let root = section.element else { return nil }
        let sectionArea = section.rect.width * section.rect.height
        var firstFocusable: AXUIElement?
        var selected: AXUIElement?
        var firstRow: AXUIElement?
        var body: (element: AXUIElement, area: CGFloat)?
        var stack: [AXUIElement] = [root]
        var visited = 0
        while let element = stack.popLast(), visited < maximumNodes, selected == nil {
            visited += 1
            if !CFEqual(element, root), canFocus(element), let f = visibleFrame(of: element), f.intersects(section.rect) {
                if isCurrent(element) { selected = element }
                // 兜底优先选「一行」（列表里的项），不要选到下拉菜单、开关这类控件上。
                let role = string(element, kAXRoleAttribute) ?? ""
                let isRow = ["AXButton", "AXLink", "AXRow", "AXCell"].contains(role) && f.width >= section.rect.width * 0.6
                if isRow, firstRow == nil { firstRow = element }
                if firstFocusable == nil { firstFocusable = element }
                let visibleArea = f.intersection(section.rect).width * f.intersection(section.rect).height
                // 一样大时取更里面的那个：网页里嵌网页（Artifact）时，要落到真正的那份文档上，而不是外面的壳。
                if visibleArea >= sectionArea * 0.5, body == nil || visibleArea >= body!.area * 0.98 {
                    body = (element, visibleArea)
                }
            }
            stack.append(contentsOf: children(of: element).reversed())
        }
        for candidate in [selected, body?.element, canFocus(root) ? root : nil, firstRow, firstFocusable].compactMap({ $0 }) {
            if AXUIElementSetAttributeValue(candidate, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
                return candidate
            }
        }
        return nil
    }

    /// 焦点是否在可编辑的文字里（返回键在这里是删字，在别处是退一级）。
    func isEditingText(pid: pid_t) -> Bool {
        guard let focused = focusedElement(pid: pid) else { return false }
        let role = string(focused, kAXRoleAttribute) ?? ""
        return ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) && isEditable(focused)
    }

    /// 内容可编辑：值可写，或者 Chromium 标了它在可编辑区域里（contenteditable 的输入框走这条）。
    func isEditable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, "AXEditableAncestor" as CFString, &value) == .success && value != nil
    }

    /// 一项里前几个可见的末端元素（文字等）的位置，用来判断「滚了以后内容动没动」。
    func contentSignature(of element: AXUIElement) -> [CGRect] {
        var result: [CGRect] = []
        var stack = children(of: element).reversed() as [AXUIElement]
        var visited = 0
        while let node = stack.popLast(), visited < 400, result.count < 4 {
            visited += 1
            // 只看最末端的元素（文字、图片）：外层包装铺满屏幕时，裁过的框滚前滚后一样，看不出动没动。
            let kids = children(of: node)
            if kids.isEmpty, let f = visibleFrame(of: node) { result.append(f) }
            stack.append(contentsOf: kids.reversed())
        }
        return result
    }

    /// 浮在内容上面的输入框：从文本区往外找它整张卡片（还在这一栏的下半部分、没变成整栏那么大的最外一层），返回卡片上沿。
    func overlayTop(of input: AXUIElement, within view: CGRect) -> CGFloat {
        var top = frame(of: input)?.minY ?? view.maxY
        var current = parent(of: input)
        var depth = 0
        while let node = current, depth < 12, let f = frame(of: node) {
            guard f.minY > view.midY, f.height < view.height * 0.5 else { break }
            top = min(top, f.minY)
            current = parent(of: node)
            depth += 1
        }
        return top
    }

    /// 某个控件属于哪一站：沿界面结构往上找，碰到的第一个栏 / 输入框就是。
    func sectionIndex(of element: AXUIElement, in sections: [Section]) -> Int? {
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 200 {
            if let i = sections.firstIndex(where: { $0.element.map { CFEqual($0, node) } ?? false }) { return i }
            current = parent(of: node)
            depth += 1
        }
        return nil
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// App 里当前拿着键盘焦点的控件。
    func focusedElement(pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func canFocus(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable) == .success && settable.boolValue
    }

    /// App 标成「当前」的项：选中（aria-selected）或 aria-current（当前页面 / 当前会话常用这个）。
    func isCurrent(_ element: AXUIElement) -> Bool {
        if isSelected(element) { return true }
        if let current = string(element, "AXARIACurrent"), !current.isEmpty, current != "false" { return true }
        return false
    }

    func isSelected(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) == true
    }

    // MARK: 工具

    /// 日志用：角色 + 标签。
    func describe(_ element: AXUIElement) -> String {
        let role = string(element, kAXRoleAttribute) ?? "?"
        let label = labelOf(element)
        return label.isEmpty ? role : "\(role) 「\(label.prefix(30))」"
    }

    func labelOf(_ element: AXUIElement) -> String {
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute] {
            if let s = string(element, attribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        }
        return ""
    }

    private func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// 真实在屏幕上（屏幕外的元素系统报高度 1）。
    func visibleFrame(of element: AXUIElement) -> CGRect? {
        guard let f = frame(of: element), f.height > 2, f.width > 2 else { return nil }
        return f
    }

    func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }
}

// MARK: - 发事件

enum Poster {
    static func key(_ shortcut: Shortcut) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.key, keyDown: down) else { continue }
            event.flags = shortcut.flags
            event.setIntegerValueField(.eventSourceUserData, value: ownMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    /// 在指定屏幕位置投递一次像素滚轮；正数 = 往上（看更早的内容）。不移动鼠标指针。
    static func scroll(pixels: Int32, at point: CGPoint) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: pixels, wheel2: 0, wheel3: 0) else { return }
        event.location = point
        event.setIntegerValueField(.eventSourceUserData, value: ownMarker)
        event.post(tap: .cghidEventTap)
    }
}
