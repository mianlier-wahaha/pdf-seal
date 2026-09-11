import SwiftUI
import CoreGraphics
import SealCore

@main
struct PDFSealApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var doc = DocumentStore()
    @StateObject private var seals = SealStore()
    @StateObject private var settings = StampSettings()

    var body: some Scene {
        // 全局键盘监听随 App 生命周期安装（AppDelegate 内幂等，不再依赖视图 onAppear/onDisappear）
        appDelegate.bind(doc: doc, seals: seals, settings: settings)
        return WindowGroup(L("PDF 骑缝章")) {
            ContentView()
                .environmentObject(doc)
                .environmentObject(seals)
                .environmentObject(settings)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowToolbarStyle(.unified)
    }
}
