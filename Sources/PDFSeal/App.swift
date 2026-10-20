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
            // 工具菜单：只收录本 app 已有的功能入口（没有的项不占位）
            CommandMenu(L("工具")) {
                Button(L("编辑 PDF")) { NotificationCenter.default.post(name: .menuToolEdit, object: nil) }
                Button(L("标记密文")) { NotificationCenter.default.post(name: .menuToolRedact, object: nil) }
                Button(L("组织页面")) { NotificationCenter.default.post(name: .menuToolPageManage, object: nil) }
                Button(L("水印")) { NotificationCenter.default.post(name: .menuToolStamp, object: nil) }
                Divider()
                Button(L("合并文件…")) { NotificationCenter.default.post(name: .menuMergeFiles, object: nil) }
                Menu(L("创建 PDF")) {
                    Button(L("空白页面")) { NotificationCenter.default.post(name: .menuCreatePDF, object: nil) }
                    Button(L("从文件创建 PDF")) { NotificationCenter.default.post(name: .menuCreatePDF, object: nil) }
                    Button(L("从图像创建 PDF")) { NotificationCenter.default.post(name: .menuCreatePDF, object: nil) }
                    Button(L("从剪贴板创建 PDF")) { NotificationCenter.default.post(name: .menuCreatePDF, object: nil) }
                    Divider()
                    Button(L("从 Word 创建 PDF")) { NotificationCenter.default.post(name: .menuCreatePDF, object: nil) }
                    Button(L("从 Excel 创建 PDF")) { NotificationCenter.default.post(name: .menuCreatePDF, object: nil) }
                    Button(L("从 PowerPoint 创建 PDF")) { NotificationCenter.default.post(name: .menuCreatePDF, object: nil) }
                }
            }
        }
    }
}

extension Notification.Name {
    static let menuOpenPDF = Notification.Name("PDFSeal.menuOpenPDF")
    static let menuSavePDF = Notification.Name("PDFSeal.menuSavePDF")
    static let menuSaveAsPDF = Notification.Name("PDFSeal.menuSaveAsPDF")
    // 工具菜单（v2.10.0）
    static let menuToolEdit = Notification.Name("PDFSeal.menuToolEdit")
    static let menuToolRedact = Notification.Name("PDFSeal.menuToolRedact")
    static let menuToolPageManage = Notification.Name("PDFSeal.menuToolPageManage")
    static let menuToolStamp = Notification.Name("PDFSeal.menuToolStamp")
    static let menuMergeFiles = Notification.Name("PDFSeal.menuMergeFiles")
    static let menuCreatePDF = Notification.Name("PDFSeal.menuCreatePDF")
}
