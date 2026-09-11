import AppKit
import SwiftUI

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

    /// 由 PDFSealApp 在 body 中调用（生命周期内幂等）。持有 store 弱引用并安装监听器。
    func bind(doc: DocumentStore, seals: SealStore, settings: StampSettings) {
        self.doc = doc
        self.seals = seals
        self.settings = settings
        installIfNeeded()
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
