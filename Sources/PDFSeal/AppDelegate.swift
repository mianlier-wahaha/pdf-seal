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
    private weak var workspace: Workspace?
    private weak var seals: SealStore?
    /// 供窗口关闭代理读取活动会话文档（避免循环依赖）
    static var workspaceRef: Workspace?
    /// 冷启动竞态缓冲：odoc 事件先于 bind 到达时暂存待打开的 PDF
    private var pendingOpenURL: URL?

    /// 由 PDFSealApp 在 body 中调用，但内部幂等（仅首次真正订阅）。
    func bind(workspace: Workspace, seals: SealStore) {
        guard self.workspace == nil else { return }
        self.workspace = workspace
        self.seals = seals
        Self.workspaceRef = workspace
        installIfNeeded()
        // 冷启动时 odoc 事件可能先于 bind 到达：补载暂存的 PDF
        if let pending = pendingOpenURL {
            pendingOpenURL = nil
            workspace.openURL(pending)
        }
        // 临时 UITEST：打字链路实测 harness
        if ProcessInfo.processInfo.environment["MPDF_UITEST"] != nil
            || ProcessInfo.processInfo.arguments.contains("--uitest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                AnnotationPDFView.runUITestHarness()
            }
        }
        // 临时探针：真实环境事件派发实证（自动开 PDF → 编辑页 → 被动探针）
        if ProcessInfo.processInfo.arguments.contains("--probe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let pdf = ProcessInfo.processInfo.arguments.first(where: { $0.hasSuffix(".pdf") }) {
                    MainActor.assumeIsolated { self.openDocument(at: URL(fileURLWithPath: pdf)) }
                }
            }
        }
        // 临时探针：裸窗口基准 bench
        if ProcessInfo.processInfo.arguments.contains("--probebench") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                AnnotationPDFView.runCursorScrollProbe()
            }
        }
        // 临时探针：窗口红X关闭拦截链路实证（开 PDF → 置脏 → performClose）
        if ProcessInfo.processInfo.arguments.contains("--probe-close") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated {
                    self?.openDocument(at: URL(fileURLWithPath: "/tmp/mpdf_test.pdf"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        MainActor.assumeIsolated {
                            guard let ws = AppDelegate.workspaceRef, let s = ws.sessions.last else {
                                uitestLog("[PROBE-CLOSE] no session"); return
                            }
                            s.doc.isDirty = true
                            NSApp.activate(ignoringOtherApps: true)
                            let win = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
                            uitestLog("[PROBE-CLOSE] dirty set, sessions=%@, windows=%@, main=%@, delegate=%@",
                                      String(ws.sessions.count), String(NSApp.windows.count),
                                      win.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
                                      String(describing: win?.delegate))
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                MainActor.assumeIsolated {
                                    uitestLog("[PROBE-CLOSE] performClose ->")
                                    win?.performClose(nil)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                        MainActor.assumeIsolated {
                                            uitestLog("[PROBE-CLOSE] after: mainWindow visible=%@, stillExists=%@",
                                                      win?.isVisible == true ? "yes" : "no",
                                                      NSApp.windows.contains(where: { $0 === win }) ? "yes" : "no")
                                            NSApp.terminate(nil)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func installIfNeeded() {
        // 监听器必须同时具备 workspace 引用且尚未安装，才安装一次；重复调用为无操作。
        guard keyMonitor == nil, flagsMonitor == nil,
              seals != nil, workspace != nil else { return }

        // 窗口关闭守卫常驻监听：SwiftUI 每次状态刷新都会把 window.delegate 夺回
        // AppKitWindowController，导致 CloseGuard.windowShouldClose 失效（红绿灯 ✕
        // 不弹未保存确认）。didUpdate 每次窗口更新回调里做一次指针比较，被夺回即抢回。
        NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                if let win = note.object as? NSWindow {
                    CloseGuard.shared.attachIfAppropriate(win)
                }
            }
        }
        // 兜底轮询：窗口静默（无重绘）期间 didUpdate 不触发，SwiftUI 夺回后抢不回；
        // 0.5s 定时把所有可见窗口的 delegate 重新归位（纯指针比较，成本可忽略）。
        let guardTimer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                for win in NSApp.windows where win.isVisible {
                    CloseGuard.shared.attachIfAppropriate(win)
                }
            }
        }
        RunLoop.main.add(guardTimer, forMode: .common)

        // macOS 27 PDFKit 注记马赛克修复（私有层 contentsScale=1.0 + nearest 采样系统 bug）
        PDFKitAnnotationQualityFix.install()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(keyDown: event)
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.workspace?.active.settings.commandKeyDown = event.modifierFlags.contains(.command)
            return event
        }
    }

    /// 全局键盘：Esc 取消选中章；⌘Z / Ctrl+Z 撤销；Delete 移除选中章；↑/↓ 调整印章库顺序
    /// （章/文档操作均落在「活动会话」上，多标签切换后自动跟随）
    private func handle(keyDown event: NSEvent) -> NSEvent? {
        // 仅当文本框正在编辑（字段编辑器激活）且本次是「输入字符」时，放行给系统处理文本；
        // 避免抢走正常打字，但我们的全局快捷键（Esc/Delete/⌘Z/方向键）不在字符输入范畴，
        // 仍会进入下方处理。
        let isPlainTyping = event.charactersIgnoringModifiers?.isEmpty == false
            && !event.modifierFlags.contains(.command)
            && !event.modifierFlags.contains(.control)
            && !event.modifierFlags.contains(.option)
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView,
           tv.isFieldEditor || tv is GhostTextEditor, isPlainTyping {
            return event
        }

        // ↑/↓（126/125）：印章库已选中某章时上下移动其顺序
        if (event.keyCode == 126 || event.keyCode == 125), let seals = seals, seals.selectedID != nil {
            seals.moveSelectedSeal(by: event.keyCode == 126 ? -1 : 1)
            return nil
        }

        // Esc：取消全部选中章
        if event.keyCode == 53 || event.characters == "\u{1b}" {
            if let st = workspace?.active.settings, !st.selectedFullStampIDs.isEmpty {
                st.clearSelection()
                return nil
            }
            return event
        }

        // ⌘Z / Ctrl+Z：全局撤销中心（批注/章/页面 三路时间线取最近者回退）；⇧⌘Z 重做
        if event.keyCode == 6, event.characters?.lowercased() == "z",
           event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            guard let ws = workspace else { return event }
            let st = ws.active.settings
            if event.modifierFlags.contains(.shift) {
                if UndoCenter.shared.redo(doc: ws.active.doc, stamps: st) { return nil }
            } else {
                if UndoCenter.shared.undo(doc: ws.active.doc, stamps: st) { return nil }
            }
        }

        // Delete（kVK_Delete = 51，即 Mac 删除/退格键）：移除选中的全部正文章（支持多选）。
        // 带 cmd/option 的组合键放行给系统，避免与系统编辑快捷键冲突。
        if event.keyCode == 51,
           !event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.option),
           let ws = workspace, !ws.active.settings.selectedFullStampIDs.isEmpty {
            ws.active.settings.removeSelectedFullStamps()
            return nil
        }

        return event
    }

    /// 注册「打开文档」Apple 事件：访达「打开方式」/双击 PDF 时由系统投递 odoc 事件。
    /// 必须在 applicationWillFinishLaunching 安装——odoc 事件在 finishLaunching 后即投递，
    /// 装晚了（如 applicationDidFinishLaunching 之后）冷启动会丢事件。
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocEvent(_:withReplyEvent:)),
            forEventClass: kCoreEventClass,
            andEventID: kAEOpenDocuments
        )
    }

    /// odoc 事件处理：从事件中提取文件 URL，取第一个 PDF 载入。
    /// nonisolated：Apple 事件回调不由 Swift 并发系统调度，须手动回到主线程。
    @objc nonisolated private func handleOpenDocEvent(_ event: NSAppleEventDescriptor,
                                                     withReplyEvent reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        var urls: [URL] = []
        if list.descriptorType == typeAEList {
            for i in 1...max(list.numberOfItems, 0) {
                if let u = list.atIndex(i)?.fileURLValue { urls.append(u) }
            }
        } else if let u = list.fileURLValue {
            urls.append(u)
        }
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.openDocument(at: url) }
        }
    }

    /// 载入外部打开的 PDF（新标签或切换到已开标签）；workspace 尚未绑定（冷启动竞态）时先挂起
    func openDocument(at url: URL) {
        if let ws = workspace {
            ws.openURL(url)
        } else {
            pendingOpenURL = url
        }
    }

    /// 关闭最后一个窗口时退出整个 app（与 ⌘Q 等效），避免窗口已关但 Dock 残留僵尸图标。
    /// 未保存确认仍由 CloseGuard.windowShouldClose 先行拦截，确认关闭后走正常关闭→本方法触发退出。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
    private var titleObserver: NSObjectProtocol?

    /// 把本代理挂到窗口上（保留原 delegate 用于转发），并钉住「窗口标题恒为空」——
    /// SwiftUI 每次状态刷新/打开文档都会把标题重设回 app 名（PDF 工具箱），
    /// 而 NSWindow.title 不支持 KVO（observe(\.title) 收不到回调），故改用
    /// NSWindowDidChangeTitleNotification：标题一变且非空立即清空并隐藏；
    /// 清空为空串触发的下一次通知因 title 为空直接返回，循环自然终止。
    /// ⚠️ SwiftUI 会在状态刷新时把 window.delegate 夺回 AppKitWindowController，
    /// 挂一次必被覆盖——需配合 didUpdate 常驻守卫（见 AppDelegate 监听）。
    func attach(to window: NSWindow) {
        if window.delegate !== self {
            previous = window.delegate
            window.delegate = self
        }
        if titleObserver == nil {
            titleObserver = NotificationCenter.default.addObserver(
                forName: NSNotification.Name("NSWindowDidChangeTitle"),
                object: window, queue: .main
            ) { note in
                guard let win = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    win.titleVisibility = .hidden
                    if !win.title.isEmpty { win.title = "" }
                }
            }
        }
        window.titleVisibility = .hidden
        if !window.title.isEmpty { window.title = "" }
    }

    /// didUpdate 常驻守卫入口：只接管「SwiftUI WindowGroup 主窗口」，不碰面板/sheet。
    /// ⚠️ 判定具体类不能用 type(of: win.delegate)——existential 包装会返回
    /// "Optional<NSWindowDelegate>" 而非具体类名；须用 String(describing: win?.delegate)。
    func attachIfAppropriate(_ win: NSWindow) {
        if win.delegate === self { return }   // 常态快路径：已接管，零成本返回
        guard !(win is NSPanel), win.sheetParent == nil, win.isVisible else { return }
        // 取具体类名：existential 须先转 AnyObject 再 type(of:)，否则拿到 "Optional<NSWindowDelegate>"
        let desc = win.delegate.map { "\(type(of: $0 as AnyObject))" } ?? "nil"
        guard desc == "nil" || desc.contains("AppKitWindowController") else { return }
        attach(to: win)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        uitestLog("[CLOSE-GUARD] windowShouldClose fired")
        guard let ws = AppDelegate.workspaceRef,
              ws.sessions.contains(where: { $0.doc.isDirty }) else {
            uitestLog("[CLOSE-GUARD] guard passed (no dirty), close allowed")
            return true
        }
        let alert = NSAlert()
        alert.messageText = L("该文件尚未保存，是否关闭？")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("取消"))
        alert.addButton(withTitle: L("确认"))
        alert.beginSheetModal(for: sender) { resp in
            if resp == .alertSecondButtonReturn {
                for s in ws.sessions { s.doc.isDirty = false }
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

/// 透明 NSView：视图挂进窗口层级时（viewDidMoveToWindow 系统必回调）把窗口 delegate
/// 切到 CloseGuard。不能用 updateNSView 时机——SwiftUI 对无参 representable 只在
/// 首次布局时调一次，此时 background 视图尚未进 window（window=nil），之后不再刷新，
/// 导致红绿灯 ✕ 关闭拦截从未生效（探针实证）。
struct WindowAccessor: NSViewRepresentable {
    final class CloseAttachView: NSView {
        override func viewDidMoveToWindow() {
            if let win = window {
                MainActor.assumeIsolated {
                    CloseGuard.shared.attach(to: win)
                    win.title = ""
                    win.titleVisibility = .hidden   // 顶栏左侧不留标题文字
                }
            }
        }
    }

    func makeNSView(context: Context) -> NSView { CloseAttachView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        // 本方法非 actor 隔离，但 SwiftUI 保证在主线程调用；切换窗口 delegate 需 @MainActor
        MainActor.assumeIsolated {
            if let win = nsView.window {
                CloseGuard.shared.attach(to: win)
                win.title = ""
                win.titleVisibility = .hidden   // 顶栏左侧不留标题文字
            }
        }
    }
}
