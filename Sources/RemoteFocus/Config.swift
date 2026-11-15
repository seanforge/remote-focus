import CoreGraphics

/// SayAll 给自己发出的每个合成事件都打上这个标记（源码 KeyboardInjector.syntheticEventMarker = "XIAO"）。
/// 带这个标记的事件 = 来自遥控器。
let sayAllMarker: Int64 = 0x5849_414F
/// 本程序自己发出的事件用这个标记，事件监听里直接放行，避免自己拦自己。
let ownMarker: Int64 = 0x5246_4F43 // "RFOC"

enum Key {
    static let left: CGKeyCode = 123
    static let right: CGKeyCode = 124
    static let down: CGKeyCode = 125
    static let up: CGKeyCode = 126
    static let escape: CGKeyCode = 53
    static let backspace: CGKeyCode = 51
}

struct Shortcut {
    let key: CGKeyCode
    let flags: CGEventFlags
}

/// 每个 App 的会话切换快捷键。
struct AppProfile {
    let bundleID: String
    let name: String
    let previousSession: Shortcut
    let nextSession: Shortcut
}

enum Config {
    static let apps: [AppProfile] = [
        AppProfile(
            bundleID: "com.anthropic.claudefordesktop",
            name: "Claude",
            previousSession: Shortcut(key: Key.up, flags: .maskAlternate),          // ⌥↑
            nextSession: Shortcut(key: Key.down, flags: .maskAlternate)             // ⌥↓
        ),
        AppProfile(
            bundleID: "com.openai.codex",
            name: "Codex",
            // 官方文档里 ⌘⇧[ ] 也行，但光标在 Codex 输入框里时会被吃掉；实测 ⌘⌥← / ⌘⌥→ 可用。
            previousSession: Shortcut(key: Key.left, flags: [.maskCommand, .maskAlternate]),     // ⌘⌥←
            nextSession: Shortcut(key: Key.right, flags: [.maskCommand, .maskAlternate])         // ⌘⌥→
        ),
    ]

    static func profile(for bundleID: String?) -> AppProfile? {
        guard let bundleID else { return nil }
        return apps.first { $0.bundleID == bundleID }
    }

    // 点按 / 按住的区分照 SayAll 的连发节奏（按下 0.35 秒后开始，每 0.1 秒一次），写在 main.swift 的 handle 里。
    /// 按住时连续切会话的间隔。
    static let sessionHoldInterval: Double = 0.3
    /// 长内容还没看完时，↑↓ 每按一下滚多少像素（按住会连发，连续滚）。
    static let readScrollPixels: Int32 = 80
    /// 替 App 滚动后，内容位置多久没变才算「滚到头了」。比 App 更新位置的延迟长，比 SayAll 连发后人能感知的停顿短。
    static let scrollSettleSeconds: Double = 0.35
}
