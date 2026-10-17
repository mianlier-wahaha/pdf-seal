import SwiftUI
import CoreGraphics
import SealCore

@main
struct PDFSealApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspace = Workspace()
    @StateObject private var seals = SealStore()

    var body: some Scene {
        // 全局键盘监听随 App 生命周期安装（AppDelegate 内幂等，不再依赖视图 onAppear/onDisappear）
        appDelegate.bind(workspace: workspace, seals: seals)
        // 窗口标题不显示（顶栏左侧留给功能块），app 名仍取自 CFBundleName
        // 多标签：注入「活动会话」的 doc/settings，切标签时由 body 重算完成切换
        return WindowGroup {
            let s = workspace.sessions[workspace.activeIndex]
            ContentView()
                .environmentObject(s.doc)
                .environmentObject(seals)
                .environmentObject(s.settings)
                .environmentObject(workspace)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowToolbarStyle(.unifiedCompact)   // 紧凑顶栏：压缩垂直占用
        .commands {
            // 文件菜单：「新建窗口」之后、「关闭」之前加 打开/保存/另存为（动作由 ContentView 执行）
            CommandGroup(after: .newItem) {
                Button(L("打开")) { NotificationCenter.default.post(name: .menuOpenPDF, object: nil) }
                    .keyboardShortcut("o")
                Button(L("保存")) { NotificationCenter.default.post(name: .menuSavePDF, object: nil) }
                    .keyboardShortcut("s")
                Button(L("另存为")) { NotificationCenter.default.post(name: .menuSaveAsPDF, object: nil) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }
}

extension Notification.Name {
    static let menuOpenPDF = Notification.Name("PDFSeal.menuOpenPDF")
    static let menuSavePDF = Notification.Name("PDFSeal.menuSavePDF")
    static let menuSaveAsPDF = Notification.Name("PDFSeal.menuSaveAsPDF")
}
