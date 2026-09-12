import AppKit
import SwiftUI
import Combine

/// 全局键盘监听的归属者：随 App 生命周期存在（而非某个 View 的 onAppear/onDisappear）。
/// 此前键盘监听装在 ContentView.onAppear、onDisappear 里卸载，导致窗口/视图身份变化或
/// onDisappear 触发后未重装时，Delete/⌘Z/Esc/↑↓ 等一组快捷键整批失效。改为 App 级单例式
/// 安装，彻底摆脱视图生命周期的干扰。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private weak var doc: DocumentStore?
    private weak var seals: SealStore?
    private weak var settings: StampSettings?
    /// 脏标记订阅持有（避免被回收）
    private var cancellables: [AnyCancellable] = []
    /// bind 仅执行一次的幂等守卫（App.body 每次重算都会调到，不能重复订阅）
    private var didBind = false
    /// 供窗口关闭代理读取当前文档（避免循环依赖）
    static var docRef: DocumentStore?

    /// 由 PDFSealApp 在 body 中调用，但内部幂等（仅首次真正订阅）。
    /// ⚠️ 曾在 body 中裸调导致死循环：每次 body 重算都新建 sink，Combine 订阅即重放当前值
    /// 把 isDirty 置 true → 视图失效 → 再重算 body → 再建 sink…，无限重绘 + 订阅集合膨胀。
    /// 故用 didBind 守卫只订阅一次，并用 dropFirst() 跳过订阅时的初始重放（避免启动即误报未保存）。
    func bind(doc: DocumentStore, seals: SealStore, settings: StampSettings) {
        guard !didBind else { return }
        didBind = true
        self.doc = doc
        self.seals = seals
        self.settings = settings
        AppDelegate.docRef = doc
        installIfNeeded()
        // 任何「文档内容」变更（骑缝章数组 / 正文章数组 / 水印配置）即标记未保存；
        // 选中状态(选章)等不改变文档内容的变动不触发，避免误报。
        // dropFirst() 跳过订阅瞬间对当前值的重放，否则会把 isDirty 从 false 误置 true。
        settings.$qifengStamps.dropFirst().sink { [weak doc] _ in doc?.isDirty = true }.store(in: &cancellables)
        settings.$fullStamps.dropFirst().sink { [weak doc] _ in doc?.isDirty = true }.store(in: &cancellables)
        settings.$watermark.dropFirst().sink { [weak doc] _ in doc?.isDirty = true }.store(in: &cancellables)
    }

    private func installIfNeeded() {
        // 监听器必须同时具备 store 引用且尚未安装，才安装一次；重复调用为无操作。
        guard keyMonitor == nil, flagsMonitor == nil,
              seals != nil, settings != nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(keyDown: event)
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.settings?.commandKeyDown = event.modifierFlags.contains(.command)
            return event
        }
    }

    /// 全局键盘：Esc 取消选中章；⌘Z / Ctrl+Z 撤销；Delete 移除选中章；↑/↓ 调整印章库顺序
    private func handle(keyDown event: NSEvent) -> NSEvent? {
        // 仅当文本框正在编辑（字段编辑器激活）且本次是「输入字符」时，放行给系统处理文本；
        // 避免抢走正常打字，但我们的全局快捷键（Esc/Delete/⌘Z/方向键）不在字符输入范畴，
        // 仍会进入下方处理。
        let isPlainTyping = event.charactersIgnoringModifiers?.isEmpty == false
            && !event.modifierFlags.contains(.command)
            && !event.modifierFlags.contains(.control)
            && !event.modifierFlags.contains(.option)
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isFieldEditor, isPlainTyping {
            return event
        }

        // ↑/↓（126/125）：印章库已选中某章时上下移动其顺序
        if (event.keyCode == 126 || event.keyCode == 125), let seals = seals, seals.selectedID != nil {
            seals.moveSelectedSeal(by: event.keyCode == 126 ? -1 : 1)
            return nil
        }

        // Esc：取消全部选中章
        if event.keyCode == 53 || event.characters == "\u{1b}" {
            if let settings = settings, !settings.selectedFullStampIDs.isEmpty {
                settings.clearSelection()
                return nil
            }
            return event
        }

        // ⌘Z / Ctrl+Z：统一时间线撤销
        if event.keyCode == 6, event.characters?.lowercased() == "z",
           event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            if settings?.undo() == true { return nil }
        }

        // Delete（kVK_Delete = 51，即 Mac 删除/退格键）：移除选中的全部正文章（支持多选）。
        // 带 cmd/option 的组合键放行给系统，避免与系统编辑快捷键冲突。
        if event.keyCode == 51,
           !event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.option),
           let settings = settings, !settings.selectedFullStampIDs.isEmpty {
            settings.removeSelectedFullStamps()
            return nil
        }

        return event
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        flagsMonitor = nil
    }
}

/// 窗口关闭拦截：文档有未保存改动时，点红X先弹「该文件尚未保存，是否关闭？」；
/// 已保存/未修改则直接关闭。
/// 采用「转发代理」：把自身设为 window.delegate 并保留 SwiftUI 原有 delegate，
/// 未实现的 NSWindowDelegate 方法全部转发给原 delegate，避免破坏工具栏/标题等原生行为。
@MainActor
final class CloseGuard: NSObject, NSWindowDelegate {
    static let shared = CloseGuard()
    private weak var previous: NSObjectProtocol?

    /// 把本代理挂到窗口上（保留原 delegate 用于转发）
    func attach(to window: NSWindow) {
        if window.delegate === self { return }
        previous = window.delegate
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let doc = AppDelegate.docRef, doc.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = L("该文件尚未保存，是否关闭？")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("取消"))
        alert.addButton(withTitle: L("确认"))
        alert.beginSheetModal(for: sender) { resp in
            if resp == .alertSecondButtonReturn {
                AppDelegate.docRef?.isDirty = false
                sender.close()
            }
        }
        return false
    }

    // 转发 SwiftUI 原有 window delegate 的方法，避免覆盖原生行为
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        if let prev = previous as? NSObject, prev.responds(to: aSelector) { return true }
        return false
    }
    override func forwardingTarget(for aSelector: Selector!) -> Any? { previous }
}

/// 透明 NSView，仅在 updateNSView 时把窗口 delegate 切换到 CloseGuard（幂等）。
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        // 本方法非 actor 隔离，但 SwiftUI 保证在主线程调用；切换窗口 delegate 需 @MainActor
        MainActor.assumeIsolated {
            if let win = nsView.window { CloseGuard.shared.attach(to: win) }
        }
    }
}
