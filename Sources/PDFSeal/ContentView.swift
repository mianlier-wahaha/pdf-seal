import SwiftUI
import PDFKit
import CoreGraphics
import UniformTypeIdentifiers
import SealCore

struct ContentView: View {
    @EnvironmentObject private var doc: DocumentStore
    @EnvironmentObject private var seals: SealStore
    @EnvironmentObject private var settings: StampSettings

    
    @State private var showJigsaw = false
    @State private var statusText: String?
    @State private var errorText: String?
    @State private var keyMonitor: Any?
    @State private var showCloseConfirm = false

    var body: some View {
        HStack(spacing: 0) {
            SealLibraryView()
                .frame(width: 220)
            Divider()
            VStack(spacing: 0) {
                previewArea
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ParamsPanelView()
                .frame(width: 268)
        }
        .sheet(isPresented: $showJigsaw) { JigsawView() }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
            openPDF(url)
            return true
        }
        .alert("出错了", isPresented: .init(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .onReceive(doc.$loadError) { _ in if let e = doc.loadError { errorText = e; doc.loadError = nil } }
        .onReceive(seals.$importError) { _ in if let e = seals.importError { errorText = e; seals.importError = nil } }
        .confirmationDialog("是否确认关闭？", isPresented: $showCloseConfirm,
                            titleVisibility: .visible) {
            Button("取消", role: .cancel) {}
            Button("确定") { closeDoc() }
        }
        .onAppear {
            // 启动时套用上次所用章的固定物理尺寸
            let d = seals.physicalSize(for: seals.selectedID)
            settings.applySealPhysicalSize(widthCm: d.widthCm, heightCm: d.heightCm,
                                           pageHeightPt: doc.pageSizes.first?.height)
            installKeyMonitor()
        }
        .onDisappear {
            if let m = keyMonitor {
                NSEvent.removeMonitor(m)
                keyMonitor = nil
            }
        }
    }

    /// 全局键盘：Esc 取消选中章；⌘Z / Ctrl+Z 撤销该章上一次调整
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 仅当文本框正在编辑（字段编辑器激活）时放行给系统
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isFieldEditor {
                return event
            }
            let isEsc = event.keyCode == 53 || event.characters == "\u{1b}"
            if isEsc {
                if settings.selectedFullStampID != nil {
                    settings.selectedFullStampID = nil
                    return nil
                }
                return event
            }
            if event.keyCode == 6, event.characters?.lowercased() == "z",
               event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                if let id = settings.selectedFullStampID, settings.undo(id) {
                    return nil
                }
            }
            return event
        }
    }

    private func openPDF(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        doc.load(url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        settings.syncPageCount(doc.pageCount)
        statusText = doc.url == nil ? nil : "已载入 \(doc.pageCount) 页"
    }

    /// NSOpenPanel 直调：SwiftUI fileImporter 在部分视图层级下不弹窗
    private func pickPDF() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]
        if let win = NSApp.mainWindow {
            panel.beginSheetModal(for: win) { resp in
                if resp == .OK, let url = panel.url {
                    openPDF(url)
                }
            }
        } else {
            if panel.runModal() == .OK, let url = panel.url {
                openPDF(url)
            }
        }
    }

    /// 保存：用盖章结果覆盖当前文件
    private func saveInPlace() {
        guard doc.url != nil else { errorText = "请先打开 PDF"; return }
        guard let base = try? buildPlacements() else {
            errorText = "请先添加印章再保存"; return
        }
        do {
            try PDFExporter.export(input: doc.url!, output: doc.url!,
                                   placements: base.placements, seals: base.seals)
            statusText = "已保存：\(doc.displayName)"
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 关闭当前文档
    private func closeDoc() {
        doc.close()
        settings.clearDocumentState()
        statusText = nil
    }

    @ViewBuilder
    private var previewArea: some View {
        if doc.document == nil {
            VStack(spacing: 14) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("把 PDF 拖进来，或点「打开」选择文件")
                    .foregroundStyle(.secondary)
                Button("打开 PDF…") { pickPDF() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { pickPDF() } label: { Label("打开", systemImage: "doc") }
                    Button { saveInPlace() } label: { Label("保存", systemImage: "arrow.down.doc") }
                        .disabled(doc.document == nil || seals.selectedID == nil)
                    Button { exportPDF() } label: { Label("另存为", systemImage: "square.and.arrow.down") }
                        .disabled(doc.document == nil || seals.selectedID == nil)
                    Button { showCloseConfirm = true } label: { Label("关闭", systemImage: "xmark.circle") }
                        .disabled(doc.document == nil)
                    Spacer()
                    Text("\(doc.displayName) · \(doc.pageCount) 页")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { showJigsaw = true } label: { Label("拼合校验", systemImage: "square.on.square") }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider()
                PreviewPagesView()
            }
        }
    }

    // MARK: 盖章导出

    private func buildPlacements() throws -> (placements: [StampPlacement], seals: [Int: CGImage]) {
        var pls: [StampPlacement] = []
        var sealImages: [Int: CGImage] = [:]
        var key = 0

        // 骑缝章：每条实例使用各自锁定的印章与位置
        for q in settings.qifengStamps {
            guard let qCG = seals.cgImage(for: q.sealID) else { continue }
            var c = QifengConfig()
            c.edge = q.edge
            c.range = q.effectiveRange(pageCount: doc.pageCount)
            c.sizeRatio = CGFloat(q.size)
            c.offset = CGFloat(q.offset)
            let qAspect = seals.aspect(for: q.sealID)
            for var pl in StampGeometry.qifeng(config: c,
                                               pageSizes: doc.pageSizes, sealAspect: qAspect,
                                               opacity: CGFloat(settings.qifengOpacity))
                .filter({ !q.removedPages.contains($0.pageIndex) }) {
                pl.sealKey = key
                pls.append(pl)
            }
            sealImages[key] = qCG
            key += 1
        }

        // 正文章：每枚实例使用各自锁定的印章
        for inst in settings.fullStamps {
            guard let cg = seals.cgImage(for: inst.sealID) else { continue }
            let a = seals.aspect(for: inst.sealID)
            var c = FullStampConfig()
            c.anchor = inst.anchor
            c.sizeRatio = CGFloat(inst.size)
            c.rotation = CGFloat(inst.rotation)
            c.range = inst.effectiveRange(pageCount: doc.pageCount)
            for var pl in StampGeometry.full(config: c,
                                             pageSizes: doc.pageSizes, sealAspect: a,
                                             opacity: CGFloat(inst.opacity))
                .filter({ !inst.removedPages.contains($0.pageIndex) }) {
                pl.sealKey = key
                pls.append(pl)
            }
            sealImages[key] = cg
            key += 1
        }

        if pls.isEmpty { throw SealError.badSealImage }
        return (pls, sealImages)
    }

    private func exportPDF() {
        guard doc.url != nil else { errorText = "请先打开 PDF"; return }
        guard let base = try? buildPlacements() else { errorText = "请先添加印章再导出"; return }
        let panel = NSSavePanel()
        let stem = doc.url!.deletingPathExtension().lastPathComponent
        panel.directoryURL = doc.url!.deletingLastPathComponent()   // 默认原文件所在文件夹
        panel.nameFieldStringValue = "\(stem)-骑缝章.pdf"
        panel.allowedContentTypes = [.pdf]
        panel.beginSheetModal(for: NSApp.mainWindow!) { resp in
            guard resp == .OK, let target = panel.url else { return }
            do {
                try PDFExporter.export(input: doc.url!, output: target,
                                       placements: base.placements, seals: base.seals)
                statusText = "已导出：\(target.lastPathComponent)"
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
