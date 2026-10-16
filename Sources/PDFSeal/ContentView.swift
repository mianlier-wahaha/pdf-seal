import SwiftUI
import AppKit
import PDFKit
import CoreGraphics
import UniformTypeIdentifiers
import SealCore

// MARK: - 主入口壳：预览（默认）/ 盖章 / 页面管理 + 顶栏 打开·保存·另存为

enum MainEntry: Hashable {
    case preview, stamp, pageManage
}


struct ContentView: View {
    @EnvironmentObject private var doc: DocumentStore
    @EnvironmentObject private var seals: SealStore
    @EnvironmentObject private var settings: StampSettings

    @State private var entry: MainEntry = .preview
    @State private var statusText: String?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            mainContent
            Divider()
            statusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowAccessor())
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
            openPDF(url)
            return true
        }
        .alert(L("出错了"), isPresented: .init(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(L("好"), role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .onReceive(doc.$loadError) { _ in if let e = doc.loadError { errorText = e; doc.loadError = nil } }
        .onReceive(seals.$importError) { _ in if let e = seals.importError { errorText = e; seals.importError = nil } }
        .onReceive(NotificationCenter.default.publisher(for: .menuOpenPDF)) { _ in pickPDF() }
        .onReceive(NotificationCenter.default.publisher(for: .menuSavePDF)) { _ in if doc.document != nil { saveInPlace() } }
        .onReceive(NotificationCenter.default.publisher(for: .menuSaveAsPDF)) { _ in if doc.document != nil { exportPDF() } }
        .onAppear {
            let d = seals.physicalSize(for: seals.selectedID)
            settings.applySealPhysicalSize(widthCm: d.widthCm, heightCm: d.heightCm,
                                           pageHeightPt: doc.pageSizes.first?.height)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                // 纯文字三段：分段选择器会把复合视图的子元素拆成独立段，图标只能整体放弃
                Picker("", selection: $entry) {
                    Text(L("预览")).tag(MainEntry.preview)
                    Text(L("盖章")).tag(MainEntry.stamp)
                    Text(L("页面管理")).tag(MainEntry.pageManage)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItemGroup(placement: .navigation) {
                Button { doc.undoPageEdit(settings: settings) } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!doc.canUndoPageEdit)
                .help(L("撤销页面操作（⌘Z）"))
                Button { doc.redoPageEdit(settings: settings) } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!doc.canRedoPageEdit)
                .help(L("重做页面操作（⇧⌘Z）"))
            }
            ToolbarItemGroup(placement: .navigation) {
                Button {} label: { toolLabel("pencil", L("编辑")) }
                    .disabled(true)
                    .help(L("未来预留"))
                Button { pickPDF() } label: { toolLabel("doc", L("打开")) }
                    .help(L("打开 PDF 文件"))
                Button { saveInPlace() } label: { toolLabel("arrow.down.doc", L("保存")) }
                    .disabled(doc.document == nil)
                    .help(L("原地保存（⌘S）"))
                Button { exportPDF() } label: { toolLabel("square.and.arrow.down", L("另存为")) }
                    .disabled(doc.document == nil)
                    .help(L("另存为新文件（⇧⌘S）"))
            }
        }
    }


    /// 顶栏功能块：图标 + 文字并排，保证功能一目了然
    private func toolLabel(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
            Text(text).font(.system(size: 12))
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if doc.document == nil {
            VStack(spacing: 14) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(L("把 PDF 拖进来，或点「打开」选择文件"))
                    .foregroundStyle(.secondary)
                Button(L("打开 PDF…")) { pickPDF() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch entry {
            case .preview: PreviewMainView()
            case .stamp: StampWorkspaceView(statusText: statusText)
            case .pageManage: PageManageView(onOpenPage: openInPreview)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(doc.document == nil ? L("未打开文件") : "\(doc.displayName) · \(doc.pageCount) 页")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if let s = statusText {
                Text(s).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    /// 页面管理双击某页 → 切到预览并定位
    private func openInPreview(_ pageIndex: Int) {
        entry = .preview
        doc.pendingJumpPage = pageIndex
    }

    // MARK: 文件操作

    private func openPDF(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        doc.load(url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        settings.syncPageCount(doc.pageCount)
        doc.isDirty = false   // 刚打开文件，尚无未保存改动（syncPageCount 的清空会触发脏标记，这里回置）
        statusText = doc.url == nil ? nil : LF("已载入 %d 页", doc.pageCount)
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

    /// 水印导出参数：config 为 nil 表示未启用水印；页码范围为 0-based 闭区间（nil = 全部页）
    private var watermarkParams: (config: WatermarkConfig, pages: ClosedRange<Int>?)? {
        guard let wm = settings.watermark.config() else { return nil }
        if settings.watermark.allPages { return (wm, nil) }
        let total = max(doc.pageCount, 1)
        let s = min(max(settings.watermark.rangeStart, 1), total) - 1
        let e = min(max(settings.watermark.rangeEnd, 1), total) - 1
        return (wm, min(s, e)...max(s, e))
    }

    /// 页面结构改动未落盘时，先把基础文档写回原文件
    @discardableResult
    private func flushPageEdits() -> Bool {
        guard doc.hasPageEdits, let url = doc.url, let d = doc.document else { return true }
        guard d.write(to: url) else {
            errorText = L("页面改动写入失败"); return false
        }
        doc.hasPageEdits = false
        return true
    }

    /// 保存：页面改动写回原文件；有章/水印时再盖章导出覆盖
    private func saveInPlace() {
        guard doc.url != nil else { errorText = L("请先打开 PDF"); return }
        guard flushPageEdits() else { return }
        let base = try? buildPlacements()
        let wmParams = watermarkParams
        if base == nil && wmParams == nil {
            // 无章无水印：基础文档已写盘，仅页面改动
            statusText = LF("已保存：%@", doc.displayName)
            doc.isDirty = false
            return
        }
        do {
            try PDFExporter.export(input: doc.url!, output: doc.url!,
                                   placements: base?.placements ?? [], seals: base?.seals ?? [:],
                                   watermark: wmParams?.config, watermarkPages: wmParams?.pages)
            statusText = LF("已保存：%@", doc.displayName)
            doc.isDirty = false   // 原地保存后无未保存改动
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 另存为：有页面改动时先写临时文件作为导出基底，避免丢页操作
    private func exportPDF() {
        guard doc.url != nil else { errorText = L("请先打开 PDF"); return }
        var input = doc.url!
        var tempURL: URL?
        if doc.hasPageEdits, let d = doc.document {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("export-base-\(UUID().uuidString).pdf")
            if d.write(to: tmp) {
                input = tmp
                tempURL = tmp
            }
        }
        defer { if let t = tempURL { try? FileManager.default.removeItem(at: t) } }

        let base = try? buildPlacements()
        let wmParams = watermarkParams
        let panel = NSSavePanel()
        let stem = doc.url!.deletingPathExtension().lastPathComponent
        panel.directoryURL = doc.url!.deletingLastPathComponent()   // 默认原文件所在文件夹
        panel.nameFieldStringValue = "\(stem)-\(L10n.stampedSuffix).pdf"
        panel.allowedContentTypes = [.pdf]
        panel.beginSheetModal(for: NSApp.mainWindow!) { resp in
            guard resp == .OK, let target = panel.url else { return }
            do {
                try PDFExporter.export(input: input, output: target,
                                       placements: base?.placements ?? [], seals: base?.seals ?? [:],
                                       watermark: wmParams?.config, watermarkPages: wmParams?.pages)
                statusText = LF("已导出：%@", target.lastPathComponent)
                doc.isDirty = false   // 导出后当前编辑已落盘，视为已保存
            } catch {
                errorText = error.localizedDescription
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
            c.firstPageLarger = q.firstPageLarger
            c.firstPageRatio = CGFloat(q.firstPageRatio)
            c.middleRatioEnabled = q.middleRatioEnabled
            c.middleRatio = CGFloat(q.middleRatio)
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
            let pageH = doc.pageSizes[c.range.lowerBound].height
            c.sizeRatio = CGFloat(inst.heightCm * 28.3465 / pageH)
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
}

// MARK: - 盖章工作区（原有界面原样保留，仅去掉文件工具栏改由主入口壳承载）

struct StampWorkspaceView: View {
    let statusText: String?
    @EnvironmentObject private var doc: DocumentStore
    @EnvironmentObject private var seals: SealStore
    @EnvironmentObject private var settings: StampSettings
    @State private var showJigsaw = false
    /// 印章库面板宽度（拖右侧边界调整，跨启动记忆）
    @AppStorage("libraryWidth") private var libraryWidth: Double = 220

    var body: some View {
        HStack(spacing: 0) {
            SealLibraryView()
                .frame(width: libraryWidth)
            LibraryWidthDivider(width: $libraryWidth)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { showJigsaw = true } label: { Label(L("拼合校验"), systemImage: "square.on.square") }
                    Spacer()
                    Text(L("拖动章落位；⌘点击多选；⌘Z 撤销"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                Divider()
                PreviewPagesView(statusText: statusText)
            }
            Divider()
            ParamsPanelView()
                .frame(width: 268)
        }
        .sheet(isPresented: $showJigsaw) { JigsawView() }
    }
}

/// 印章库右侧的可拖拽分隔条：hover 高亮并显示左右箭头光标，
/// 拖动调整印章库宽度（150–420pt），宽度经 @AppStorage 跨启动记忆。
/// 视觉上是 1pt 线，可点击/拖拽命中区扩到 9pt 宽。
private struct LibraryWidthDivider: View {
    @Binding var width: Double
    @State private var hovering = false
    @State private var dragging = false
    @State private var startWidth: Double = 0

    var body: some View {
        ZStack {
            Rectangle()
                .fill(hovering || dragging
                      ? Color.accentColor.opacity(0.7)
                      : Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .frame(width: 9)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            // 光标用 set() 直接替换而非 push()/pop()：宽度拖动导致视图重建时 onHover
            // 可能重复触发，push 会多次入栈、pop 少次，光标栈残留 resizeLeftRight，
            // 使全窗口（无自带光标跟踪的区域）都显示左右箭头。set() 无配对问题。
            if inside {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { d in
                    if !dragging {
                        dragging = true
                        startWidth = width   // 记手势起点宽度，避免 translation 累积漂移
                    }
                    width = min(max(startWidth + Double(d.translation.width), 150), 420)
                }
                .onEnded { _ in
                    dragging = false
                    if !hovering { NSCursor.arrow.set() }   // 松手时已不在边界上则恢复箭头
                }
        )
        .accessibilityLabel("调整印章库宽度")
    }
}
