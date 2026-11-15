import AppKit

/// 屏幕提示只有两样，都不抢焦点、不挡鼠标：
///   1. 栏的细框：切栏时闪一下
///   2. 栏名小标签：贴在栏的左上角（名字来自 App 自己的辅助功能标签，不是预设的）
/// 没有顶部列表。
final class HUD {
    private let sectionFrame = HUD.makeFrame(color: .systemBlue, width: 2)
    private let pill: NSPanel
    private let pillLabel = NSTextField(labelWithString: "")
    private var fadeWork: [ObjectIdentifier: DispatchWorkItem] = [:]

    init() {
        pill = HUD.makePanel()
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.masksToBounds = true
        pill.contentView = blur
        pillLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(pillLabel)
        NSLayoutConstraint.activate([
            pillLabel.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            pillLabel.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
        ])
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    private static func makeFrame(color: NSColor, width: CGFloat) -> NSPanel {
        let panel = makePanel()
        let border = NSView()
        border.wantsLayer = true
        border.layer?.borderColor = color.cgColor
        border.layer?.borderWidth = width
        border.layer?.cornerRadius = 8
        panel.contentView = border
        return panel
    }

    /// 切栏：栏闪框 + 左上角贴名字。
    func showSection(_ rect: CGRect, label: String) {
        flash(sectionFrame, rect: rect, hold: 0.5)
        showPill(label, at: CGPoint(x: rect.minX + 10, y: rect.minY + 10), hold: 1.2)
    }

    /// 屏幕上方居中一句话（长按切会话时用）。
    func toast(_ text: String) {
        guard let screen = NSScreen.main else { return }
        let top = CGPoint(x: screen.frame.midX, y: 60)
        showPill(text, at: top, hold: 0.8, centered: true)
    }

    private func showPill(_ text: String, at point: CGPoint, hold: Double, centered: Bool = false) {
        pillLabel.stringValue = text
        let size = CGSize(width: pillLabel.intrinsicContentSize.width + 24, height: 28)
        let origin = CGPoint(x: centered ? point.x - size.width / 2 : point.x, y: point.y)
        flash(pill, rect: CGRect(origin: origin, size: size), hold: hold)
    }

    private func flash(_ panel: NSPanel, rect: CGRect, hold: Double) {
        let key = ObjectIdentifier(panel)
        fadeWork[key]?.cancel()
        panel.setFrame(HUD.cocoaRect(rect), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: { if panel.alphaValue == 0 { panel.orderOut(nil) } })
        }
        fadeWork[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    /// 辅助功能坐标（左上角原点）→ Cocoa 窗口坐标（主屏左下角原点）。
    private static func cocoaRect(_ rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
