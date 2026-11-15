import AppKit
import ApplicationServices

// RemoteFocus —— 小米遥控器 + SayAll 的「切栏」外挂
//
// 照 iPadOS 焦点组 / macOS 全键盘控制 / WAI-ARIA 的通用约定：
//   一个键在「组」之间跳，组里的方向键和确认键交给 App 自己。
//
//   点 + / −      把系统键盘焦点移到下一个 / 上一个栏（栏 = App 自己标注的辅助功能区域，有几个算几个）
//   长按 + / −    上一个 / 下一个会话（唯一按 App 区分的：Claude ⌥↑↓ / Codex ⌘⌥←→）
//   返回键        焦点在文字里 = 删字（原样）；在别处 = Esc 退一级（关菜单、回到打开它的地方），同电视遥控器
//   ↑↓            原样给 App；只有焦点那一项被屏幕截断（还没看完）时，先替它滚，看完再交给 App
//   ←→、OK、Esc……   本程序完全不拦，原样到 App。
//
// 本程序没在运行时，遥控器照常可用：音量键是 SayAll 的上下滚动。

typealias Front = (app: NSRunningApplication, profile: AppProfile)

final class Controller {
    private let ax = AXHelper()
    private let hud = HUD()
    private var lastSection: Section?
    private var burst: (up: Bool, times: [Date], work: DispatchWorkItem)?
    private var hold: (up: Bool, lastEvent: Date, lastSwitch: Date)?
    private let verbose: Bool

    init(verbose: Bool) {
        self.verbose = verbose
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.ax.invalidate()
            self.lastSection = nil
            if let app, Config.profile(for: app.bundleIdentifier) != nil {
                self.ax.wakeAccessibility(pid: app.processIdentifier)   // 提前唤醒，第一次用时不卡
            }
        }
        for app in NSWorkspace.shared.runningApplications where Config.profile(for: app.bundleIdentifier) != nil {
            ax.wakeAccessibility(pid: app.processIdentifier)
        }
    }

    private func log(_ message: @autoclosure () -> String) {
        if verbose { print("[remote-focus] \(message())"); fflush(stdout) }
    }

    private var frontmost: Front? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let profile = Config.profile(for: app.bundleIdentifier) else { return nil }
        return (app, profile)
    }

    /// 现在焦点在哪一站：从系统键盘焦点沿界面结构往上找（你用鼠标、Tab 挪了焦点也跟得上）。
    private func indexOfFocus(in layout: AXHelper.Layout, pid: pid_t) -> Int? {
        if let focused = ax.focusedElement(pid: pid), let i = ax.sectionIndex(of: focused, in: layout.sections) { return i }
        if let last = lastSection?.element,
           let i = layout.sections.firstIndex(where: { $0.element.map { CFEqual($0, last) } ?? false }) { return i }
        return nil
    }

    private func step(up: Bool, count: Int = 1) {
        guard let front = frontmost else { return }
        let pid = front.app.processIdentifier
        ax.invalidate()                                   // 每次都重新看（侧栏、Artifact 可能刚开关过）
        guard let layout = ax.layout(pid: pid) else { log("读不到窗口结构"); return }
        let sections = layout.sections
        guard !sections.isEmpty else { log("这个窗口里没找到栏"); return }
        let n = sections.count
        let start = indexOfFocus(in: layout, pid: pid) ?? (up ? -1 : n)
        let next = ((start + (up ? count : -count)) % n + n) % n
        let target = sections[next]
        lastSection = target
        log("栏：" + sections.map(\.label).joined(separator: " | ") + "  → \(target.label)")

        if target.isInput, let element = target.element {
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        } else if let focused = ax.focus(section: target) {
            log("  设焦点 → \(ax.describe(focused))")
        } else {
            log("  这个栏里没有能接键盘焦点的东西")
        }
        // 输入框自己有光标，不再画东西；栏这种没有原生高亮的容器才闪框和名字。
        if !target.isInput { hud.showSection(target.rect, label: target.label) }

        // 回读：系统说「设好了」不代表焦点真的到了（比如嵌在里面的网页）。日志里写实际落在哪。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let actual = self.ax.focusedElement(pid: pid).map { self.ax.describe($0) } ?? "（读不到）"
            self.log("  实际焦点 → \(actual)")
        }
    }

    // MARK: 事件入口。返回 nil = 吞掉。
    //   遥控器 + / −（SayAll 发成滚轮）：切栏 / 切会话
    //   遥控器返回键（SayAll 发成 Backspace）：在文字里删字，别处退一级（Esc），和电视遥控器的返回键一样
    //   其他键一个都不碰

    private var swallowBackspaceUp = false

    func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
        if type == .keyDown || type == .keyUp {
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if code == Key.up || code == Key.down { return handleVertical(type: type, event: event, down: code == Key.down) }
            return handleBack(type: type, event: event)
        }
        guard type == .scrollWheel,
              event.getIntegerValueField(.eventSourceUserData) == sayAllMarker,
              let front = frontmost else { return event }
        let delta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        guard delta != 0 else { return event }
        let up = delta > 0
        let now = Date()

        // 按住：SayAll 连发，按间隔一个一个切会话。
        if let current = hold, current.up == up, now.timeIntervalSince(current.lastEvent) < 0.3 {
            hold?.lastEvent = now
            if now.timeIntervalSince(current.lastSwitch) >= Config.sessionHoldInterval {
                hold?.lastSwitch = now
                switchSession(up: up, front: front)
            }
            return nil
        }
        hold = nil

        // 按住的特征（SayAll 源码）：按下发一次，0.35 秒后开始连发、每 0.1 秒一次。
        // 所以「第二下隔 0.25–0.5 秒、第三下紧跟着 0.15 秒内」= 按住；否则每一下都是单独的点按。
        // 双击 = 连点两下 = 切两栏，不会被当成按住。
        if let b = burst, b.up != up { flushBurst() }
        if burst != nil, burst!.up == up {
            burst!.work.cancel()
            burst!.times.append(now)
        } else {
            burst = (up, [now], DispatchWorkItem {})
        }
        let times = burst!.times
        if times.count >= 3 {
            let first = times[1].timeIntervalSince(times[0])
            let repeatGap = times[2].timeIntervalSince(times[1])
            if (0.25...0.5).contains(first), repeatGap <= 0.15 {
                burst = nil
                hold = (up, now, now)
                switchSession(up: up, front: front)
                return nil
            }
        }
        let work = DispatchWorkItem { [weak self] in self?.flushBurst() }
        burst!.work = work
        // 只按了一下：要等过 0.35 秒的连发起点才能确定不是按住；已经有两下：再等一个连发间隔就够。
        DispatchQueue.main.asyncAfter(deadline: .now() + (times.count == 1 ? 0.42 : 0.2), execute: work)
        return nil
    }

    /// 把攒着的点按一次性兑现：点几下切几栏。
    private func flushBurst() {
        guard let b = burst else { return }
        b.work.cancel()
        burst = nil
        step(up: b.up, count: b.times.count)
    }

    // MARK: ↑↓：焦点那一项还没看完就先滚，看完再交给 App

    /// 上一次替 App 滚的时候，那一项里内容的位置。一直没变 = 滚不动了，就交给 App，免得卡住。
    /// （不能只比这一项自己的框：一条长消息铺满屏幕时，滚动前后它的可见框是一样的。）
    private var lastReadScroll: (element: AXUIElement, signature: [CGRect], since: Date)?

    /// 在按键监听里只做最轻的判断：遥控器的 ↑↓ 先拦下，耗时的判断放到主线程后面做。
    /// 监听回调太慢时 macOS 会临时关掉监听，按键会直接穿过去（快速连按跳走就是这么来的）。
    private func handleVertical(type: CGEventType, event: CGEvent, down: Bool) -> CGEvent? {
        guard event.getIntegerValueField(.eventSourceUserData) == sayAllMarker,
              event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty,
              let front = frontmost else { return event }
        let pid = front.app.processIdentifier
        if type == .keyUp { return nil }                      // 按下时已经接管，抬起一并吞掉（交还时会补发完整的一次按键）
        if ax.isEditingText(pid: pid) {
            Poster.key(Shortcut(key: down ? Key.down : Key.up, flags: []))   // 文字里：原样（补发按下 + 抬起）
            return nil
        }
        DispatchQueue.main.async { [weak self] in self?.decideVertical(down: down, pid: pid) }
        return nil
    }

    /// 焦点那一项往这个方向还没看完 → 替它滚；否则把这一下 ↑↓ 原样补发给 App。
    private func decideVertical(down: Bool, pid: pid_t) {
        let key = down ? "↓" : "↑"
        let passToApp = { [self] (reason: String) in
            Poster.key(Shortcut(key: down ? Key.down : Key.up, flags: []))
            log("\(key) 交给 App（\(reason)）")
        }
        guard let focused = ax.focusedElement(pid: pid),
              let item = ax.visibleFrame(of: focused),
              let layout = ax.layout(pid: pid),
              let index = ax.sectionIndex(of: focused, in: layout.sections) else { return passToApp("焦点不在任何栏里") }
        let section = layout.sections[index]
        // 焦点就是栏本身（可滚动区域）时，方向键本来就是原生滚动。
        if let element = section.element, CFEqual(element, focused) { return passToApp("焦点是滚动区域本身") }

        // Chromium 报的位置已经裁到可见区域：贴着边 = 那个方向还有没露出来的部分。
        // 浮在这一栏下半部分的输入框会挡住内容，可见范围的底边要算到输入框卡片的上沿。
        var view = section.rect
        for input in layout.sections where input.isInput {
            guard let element = input.element, input.rect.intersects(view), input.rect.minY > view.midY else { continue }
            let top = ax.overlayTop(of: element, within: view)
            if top < view.maxY { view.size.height = top - view.minY }
        }
        let cutOff = down ? item.maxY >= view.maxY - 3 : item.minY <= view.minY + 3
        guard cutOff else { lastReadScroll = nil; return passToApp("这一项已经完整可见") }

        // 「到头了」= 内容位置一直没变超过一小段时间。快速连按时 App 还没来得及更新位置，不能马上当成到头。
        let signature = ax.contentSignature(of: focused)
        let now = Date()
        if let last = lastReadScroll, CFEqual(last.element, focused), last.signature == signature {
            if now.timeIntervalSince(last.since) >= Config.scrollSettleSeconds {
                lastReadScroll = nil
                return passToApp("滚不动了，还被挡着的部分无法露出")
            }
        } else {
            lastReadScroll = (focused, signature, now)        // 内容动了（或刚开始）：重新计时
        }
        let visible = item.intersection(view)
        Poster.scroll(pixels: down ? -Config.readScrollPixels : Config.readScrollPixels,
                      at: CGPoint(x: visible.midX, y: visible.midY))
        log("\(key) 替你滚（这一项还没看完）")
    }

    private func handleBack(type: CGEventType, event: CGEvent) -> CGEvent? {
        guard event.getIntegerValueField(.eventSourceUserData) == sayAllMarker,
              CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == Key.backspace,
              event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty,
              let front = frontmost else { return event }
        if type == .keyUp {
            if swallowBackspaceUp { swallowBackspaceUp = false; return nil }
            return event
        }
        if ax.isEditingText(pid: front.app.processIdentifier) { return event }
        swallowBackspaceUp = true
        Poster.key(Shortcut(key: Key.escape, flags: []))
        log("返回 → Esc（焦点不在文字里）")
        return nil
    }

    private func switchSession(up: Bool, front: Front) {
        Poster.key(up ? front.profile.previousSession : front.profile.nextSession)
        ax.invalidate()
        hud.toast(up ? "🗂 上一个会话" : "🗂 下一个会话")
        log("切会话：\(up ? "上一个" : "下一个")（\(front.profile.name)）")
    }
}

// MARK: - 启动

let verbose = CommandLine.arguments.contains("--verbose") || CommandLine.arguments.contains("-v")

let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
if !trusted {
    print("""
    ⚠️ 需要「辅助功能」权限：系统设置 → 隐私与安全性 → 辅助功能，
       打开你运行本程序的那个终端（Terminal / iTerm / Warp…），然后重新运行。
    """)
    exit(1)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let controller = Controller(verbose: verbose)

// 只听：滚轮（+ / −）和按键（只为认出遥控器的返回键；其他键原样放行）。
let mask = (1 << CGEventType.scrollWheel.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
var tapRef: CFMachPort?
let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tapRef { CGEvent.tapEnable(tap: tapRef, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard let result = controller.handle(type: type, event: event) else { return nil }
    return Unmanaged.passUnretained(result)
}
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                  eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: nil) else {
    print("⚠️ 无法监听键盘事件：请在 系统设置 → 隐私与安全性 → 输入监控 里也打开你的终端，然后重新运行。")
    exit(1)
}
tapRef = tap
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

print("✅ RemoteFocus 已启动。只在 Claude / Codex 在前台时生效；Ctrl+C 退出。\(verbose ? "（详细日志已开）" : "")")
application.run()
