import AppKit
import ApplicationServices

// ax-dump：把 Claude / Codex 当前窗口的辅助功能结构导出到「下载」，只读，不点击、不改任何东西。
//
// 用法：
//   .build/release/ax-dump claude     # 导出 Claude（App 要开着，不用切到前台）
//   .build/release/ax-dump codex      # 导出 Codex
// 结果：~/Downloads/ax-dump-claude.txt / ax-dump-codex.txt
//
// 每行一个控件：缩进 = 层级；角色 / 子角色、DOM id 与 class、ARIA 角色、标题（截断）、屏幕位置大小、
// 能执行的动作（AXPress 等）、是否可聚焦 / 已选中。文字内容最多 40 个字，用来认出是哪一块，不导出完整聊天内容。

let targets = ["claude": "com.anthropic.claudefordesktop", "codex": "com.openai.codex"]
let name = CommandLine.arguments.dropFirst().first?.lowercased() ?? ""
guard let bundleID = targets[name] else {
    print("用法：ax-dump claude 或 ax-dump codex")
    exit(1)
}
guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) else {
    print("⚠️ 需要「辅助功能」权限（系统设置 → 隐私与安全性 → 辅助功能，打开你的终端）")
    exit(1)
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    print("⚠️ \(name) 没有在运行，先把它打开")
    exit(1)
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)
// Electron / Chromium 只有在有辅助工具声明自己存在后才会建完整的结构，等它 2 秒。
AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
Thread.sleep(forTimeInterval: 2)

func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
}
func text(_ element: AXUIElement, _ attribute: String, limit: Int = 40) -> String? {
    guard let s = copy(element, attribute) as? String, !s.isEmpty else { return nil }
    let oneLine = s.replacingOccurrences(of: "\n", with: " ")
    return oneLine.count > limit ? String(oneLine.prefix(limit)) + "…" : oneLine
}
func bool(_ element: AXUIElement, _ attribute: String) -> Bool? { copy(element, attribute) as? Bool }
func frame(_ element: AXUIElement) -> CGRect? {
    guard let p = copy(element, kAXPositionAttribute), let s = copy(element, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}
func actions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else { return [] }
    return list.filter { !["AXShowMenu", "AXScrollToVisible"].contains($0) }
}
func attributeNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(element, &names) == .success, let list = names as? [String] else { return [] }
    return list
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    (copy(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

var windowValue: CFTypeRef?
AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue)
if windowValue == nil { AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowValue) }
guard let windowValue else {
    print("⚠️ 读不到 \(name) 的窗口")
    exit(1)
}
let window = windowValue as! AXUIElement

var lines: [String] = []
var roleCounts: [String: Int] = [:]
var attributeSamples: [String: Set<String>] = [:]
var count = 0
let maxNodes = 30_000

func walk(_ element: AXUIElement, depth: Int) {
    guard count < maxNodes, depth < 80 else { return }
    count += 1
    let role = text(element, kAXRoleAttribute) ?? "?"
    roleCounts[role, default: 0] += 1
    if attributeSamples[role] == nil || attributeSamples[role]!.count < 3 {
        attributeSamples[role, default: []].formUnion(attributeNames(element))
    }

    var parts = [role]
    if let sub = text(element, kAXSubroleAttribute) { parts.append("/\(sub)") }
    if let aria = text(element, "AXARIARole") { parts.append("aria=\(aria)") }
    if let id = text(element, "AXDOMIdentifier") { parts.append("#\(id)") }
    if let classes = copy(element, "AXDOMClassList") as? [String], !classes.isEmpty {
        parts.append("." + classes.prefix(4).joined(separator: "."))
    }
    if let identifier = text(element, kAXIdentifierAttribute) { parts.append("id=\(identifier)") }
    for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute] {
        if let value = text(element, attribute) { parts.append("\"\(value)\"") }
    }
    if ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading"].contains(role), let value = text(element, kAXValueAttribute) {
        parts.append("value=\"\(value)\"")
    }
    if let f = frame(element) {
        parts.append(String(format: "@(%.0f,%.0f %.0f×%.0f)", f.minX, f.minY, f.width, f.height))
    }
    let acts = actions(element)
    if !acts.isEmpty { parts.append("[" + acts.joined(separator: ",") + "]") }
    if bool(element, kAXFocusedAttribute) == true { parts.append("FOCUSED") }
    if bool(element, kAXSelectedAttribute) == true { parts.append("SELECTED") }
    lines.append(String(repeating: "  ", count: depth) + parts.joined(separator: " "))
    for child in children(element) { walk(child, depth: depth + 1) }
}

let started = Date()
walk(window, depth: 0)

var header: [String] = []
header.append("# ax-dump \(name) (\(bundleID))  \(Date())")
header.append("# 节点数 \(count)，用时 \(String(format: "%.1f", Date().timeIntervalSince(started))) 秒")
header.append("# 各角色数量：")
for (role, n) in roleCounts.sorted(by: { $0.value > $1.value }) { header.append("#   \(role): \(n)") }
header.append("# 各角色支持的属性（抽样）：")
for (role, names) in attributeSamples.sorted(by: { $0.key < $1.key }) {
    header.append("#   \(role): " + names.sorted().joined(separator: ", "))
}
header.append("")

let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/ax-dump-\(name).txt")
try (header + lines).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
print("✅ 已导出 \(count) 个节点 → \(url.path)")
