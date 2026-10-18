import SwiftUI
import AppKit
import PDFKit
import CoreGraphics
import UniformTypeIdentifiers
import SealCore

// MARK: - 主入口壳：预览（默认）/ 盖章 / 页面管理 + 顶栏 打开·保存·另存为

enum MainEntry: Hashable {
    case preview, stamp, pageManage, edit
}


struct ContentView: View {
    @EnvironmentObject private var doc: DocumentStore
    @EnvironmentObject private var seals: SealStore
    @EnvironmentObject private var settings: StampSettings
    @EnvironmentObject private var workspace: Workspace

    @State private var entry: MainEntry = .preview
    @State private var statusText: String?
    @State private var errorText: String?
    @State private var exportTool: ExportToolKind?
    @ObservedObject private var undoCenter = UndoCenter.shared   // 全局撤销/重做按钮态

    var body: some View {
        VStack(spacing: 0) {
            // 空白会话不算标签：一个 PDF 都没打开时，整个标签栏（含分隔线）都不显示
            if hasOpenTabs {
                tabBar
                Divider()
            }
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
        .sheet(item: $exportTool) { kind in
            ExportToolsSheet(kind: kind) { msg in statusText = msg }
        }
        .onChange(of: workspace.active.id) { _ in
            statusText = nil   // 切换标签：状态栏提示属于上一个会话，不保留
            undoCenter.bind(doc: doc, stamps: settings)   // 撤销中心跟随活动会话
        }
        .onAppear {
            undoCenter.bind(doc: doc, stamps: settings)
            let d = seals.physicalSize(for: seals.selectedID)
            settings.applySealPhysicalSize(widthCm: d.widthCm, heightCm: d.heightCm,
                                           pageHeightPt: doc.pageSizes.first?.height)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                // 纯文字四段：分段选择器会把复合视图的子元素拆成独立段，图标只能整体放弃
                Picker("", selection: $entry) {
                    Text(L("预览")).tag(MainEntry.preview)
                    Text(L("盖章")).tag(MainEntry.stamp)
                    Text(L("页面管理")).tag(MainEntry.pageManage)
                    Text(L("编辑")).tag(MainEntry.edit)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItemGroup(placement: .navigation) {
                // 全局撤销/重做：批注 / 章 / 页面操作 三路时间线取最近者，任何界面都生效
                Button { undoCenter.undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!undoCenter.canUndo)
                .help(L("撤销（⌘Z）"))
                .handCursor()
                Button { undoCenter.undoAll() } label: {
                    // 双重影箭头表示「全部撤销」
                    ZStack {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11))
                            .offset(x: -2.5, y: 2.5)
                            .opacity(0.45)
                        Image(systemName: "arrow.uturn.backward")
                    }
                }
                .disabled(!undoCenter.canUndo)
                .help(L("撤销全部动作"))
                .handCursor()
                Button { undoCenter.redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!undoCenter.canRedo)
                .help(L("重做（⇧⌘Z）"))
                .handCursor()
            }
            ToolbarItemGroup(placement: .navigation) {
                Button { pickPDF() } label: { toolLabel("doc", L("打开")) }
                    .help(L("打开 PDF 文件"))
                    .handCursor()
                Button { saveInPlace() } label: { toolLabel("arrow.down.doc", L("保存")) }
                    .disabled(doc.document == nil)
                    .help(L("原地保存（⌘S）"))
                    .handCursor()
                Button { exportPDF() } label: { toolLabel("square.and.arrow.down", L("另存为")) }
                    .disabled(doc.document == nil)
                    .help(L("另存为新文件（⇧⌘S）"))
                    .handCursor()
                Button { printPDF() } label: { toolLabel("printer", L("打印")) }
                    .disabled(doc.document == nil)
                    .keyboardShortcut("p", modifiers: .command)
                    .help(L("打印当前 PDF（⌘P）"))
                    .handCursor()
                Menu {
                    Button(L("压缩…")) { exportTool = .compress }
                        .disabled(doc.document == nil)
                    Button(L("设置密码…")) { exportTool = .encrypt }
                        .disabled(doc.document == nil)
                    Divider()
                    Button(L("导出为图片…")) { exportTool = .images }
                        .disabled(doc.document == nil)
                    Button(L("图像型 PDF…")) { exportTool = .imagePDF }
                        .disabled(doc.document == nil)
                } label: { toolLabel("ellipsis.circle", L("其他功能")) }
                    .disabled(doc.document == nil)
                    .help(L("压缩 / 加密 / 导出图片 / 图像型 PDF"))
                    .handCursor()
            }
            ToolbarItem(placement: .primaryAction) {
                // 顶栏最右：关闭（走窗口关闭流程，未保存先确认）
                Button { NSApp.keyWindow?.performClose(nil) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                }
                .help(L("关闭窗口（⌘W）"))
                .handCursor()
            }
        }
    }

    // MARK: 标签栏（独立于工具栏的一行；只显示已打开 PDF 的标签，空白会话不算标签）

    @State private var draggingTabID: UUID?

    /// 仅有文档的会话才算标签；空白起始会话不显示
    private var openTabs: [Session] {
        workspace.sessions.filter { $0.doc.document != nil }
    }
    private var hasOpenTabs: Bool { !openTabs.isEmpty }

    /// 标签按实际内容长度显示；所有标签总宽超过整行时才被压缩、超宽出省略号
    /// （HStack 空间不足时自动压缩 Text，末尾 Spacer 吸收空闲宽度）。
    /// 右键菜单（关闭标签）在此布局下可正常弹出。
    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(openTabs, id: \.id) { s in
                sessionTab(s)
            }
            Spacer(minLength: 0)   // 标签未占满时吸收剩余宽度，标签保持实际长度
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func sessionTab(_ s: Session) -> some View {
        let isActive = s.id == workspace.active.id
        return HStack(spacing: 4) {
            Text(s.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 11))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
            Button {
                workspace.close(s.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondary.opacity(isActive ? 1 : 0.5))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(L("关闭此标签"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isActive ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor),
                        lineWidth: isActive ? 1 : 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let i = workspace.sessions.firstIndex(where: { $0.id == s.id }) {
                workspace.activeIndex = i
            }
        }
        .contextMenu {
            Button(L("关闭标签")) { workspace.close(s.id) }
        }
        .onDrag {
            draggingTabID = s.id
            return NSItemProvider(object: s.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(target: s.id, workspace: workspace,
                                                       draggingTabID: $draggingTabID))
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
            WorkspaceHomeView(onOpen: openPDF, onPick: pickPDF)
        } else {
            Group {
                switch entry {
                case .preview: PreviewMainView()
                case .stamp: StampWorkspaceView(statusText: statusText)
                case .pageManage: PageManageView(onOpenPage: openInPreview)
                case .edit: EditMainView()
                }
            }
            // 关键：视图身份绑定当前会话——切换标签时整个视图树重建，
            // 页面管理/预览的缩略图缓存、选中集等 @State 随会话隔离，
            // 否则新标签沿用旧文档的缩略图（索引键相同、缓存不失效）。
            .id(workspace.active.id)
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
        let s = workspace.openURL(url)
        statusText = s.doc.url == nil ? nil : LF("已载入 %d 页", s.doc.pageCount)
        if s.doc.url != nil {
            RecentFiles.record(url)   // 记入工作中心「最近打开」
        }
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

    /// 批注改动未落盘时写回原文件（含「隐藏」批注的页面压平进页面内容）
    @discardableResult
    private func flushAnnotations() -> Bool {
        guard doc.hasAnnotationEdits, let url = doc.url, let d = doc.document else { return true }
        guard d.pageCount == 0 || doc.writeFlattened(to: url) else {
            errorText = L("批注写入失败"); return false
        }
        doc.hasAnnotationEdits = false
        return true
    }

    /// 保存：页面/批注改动写回原文件；有章/水印时再盖章导出覆盖
    private func saveInPlace() {
        guard doc.url != nil else { errorText = L("请先打开 PDF"); return }
        guard flushPageEdits() else { return }
        guard flushAnnotations() else { return }
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

    /// 另存为：有页面改动时先写临时文件作为导出基底，避免丢页操作。
    /// 时序关键：临时文件的写入与清理都放在面板回调内——
    /// ① beginSheetModal 是异步的，若在挂面板前写临时文件，大文档会卡住弹窗出现；
    /// ② defer 清理会随函数返回立刻执行，等用户点「保存」时文件已被删，
    ///    PDFExporter 打不开输入即报「无法打开输入 PDF（可能已加密或损坏）」。
    private func exportPDF() {
        guard let srcURL = doc.url else { errorText = L("请先打开 PDF"); return }
        let base = try? buildPlacements()
        let wmParams = watermarkParams
        let panel = NSSavePanel()
        let stem = srcURL.deletingPathExtension().lastPathComponent
        panel.directoryURL = srcURL.deletingLastPathComponent()   // 默认原文件所在文件夹
        panel.nameFieldStringValue = "\(stem)-\(L10n.stampedSuffix).pdf"
        panel.allowedContentTypes = [.pdf]
        panel.beginSheetModal(for: NSApp.mainWindow!) { resp in
            guard resp == .OK, let target = panel.url else { return }
            // 快路径：无章无水印时纯另存——跳过临时基底与逐页压平（实测 228 页/108MB
            // 压平要 4s），有页改动直写目标、无改动字节复制，只剩一次必需的写盘
            let hasOverlays = !(base?.placements.isEmpty ?? true) || wmParams != nil
            if !hasOverlays {
                do {
                    if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)   // 面板已确认覆盖
                    }
                    if doc.hasPageEdits || doc.hasAnnotationEdits, let d = doc.document {
                        guard doc.writeFlattened(to: target) else {
                            errorText = L("写入失败，请检查目标位置是否可写"); return
                        }
                    } else {
                        try FileManager.default.copyItem(at: srcURL, to: target)
                    }
                    statusText = LF("已导出：%@", target.lastPathComponent)
                    doc.isDirty = false   // 导出后当前编辑已落盘，视为已保存
                } catch {
                    errorText = error.localizedDescription
                }
                return
            }

            // 盖章/水印路径：先把内存文档（含未保存页操作与批注）落临时基底，再压平导出
            var input = srcURL
            var tempURL: URL?
            if doc.hasPageEdits || doc.hasAnnotationEdits, let d = doc.document {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("export-base-\(UUID().uuidString).pdf")
                if doc.writeFlattened(to: tmp) {
                    input = tmp
                    tempURL = tmp
                }
            }
            defer { if let t = tempURL { try? FileManager.default.removeItem(at: t) } }

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

    // MARK: 打印

    /// 系统打印：用离屏 PDFView 承载文档，交给 NSPrintOperation 走系统打印面板
    private func printPDF() {
        guard let d = doc.document, let win = appContentWindow() ?? NSApp.mainWindow else { return }
        let pv = PDFView()
        pv.document = d.copy() as? PDFDocument   // 用副本打印，避免打印过程触碰原文档
        pv.autoScales = true
        pv.frame = NSRect(x: 0, y: 0, width: 612, height: 792)
        let info = NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false
        let op = NSPrintOperation(view: pv, printInfo: info)
        op.showsPrintPanel = true
        op.runModal(for: win, delegate: nil, didRun: nil, contextInfo: nil)
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

// MARK: - 标签拖拽排序

private struct TabDropDelegate: DropDelegate {
    let target: UUID
    let workspace: Workspace
    @Binding var draggingTabID: UUID?

    func validateDrop(info: DropInfo) -> Bool { draggingTabID != nil }

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingTabID, dragging != target,
              let from = workspace.sessions.firstIndex(where: { $0.id == dragging }),
              let to = workspace.sessions.firstIndex(where: { $0.id == target }) else { return }
        let activeID = workspace.active.id
        workspace.sessions.move(fromOffsets: IndexSet(integer: from),
                                toOffset: to > from ? to + 1 : to)
        // 换位后保持「活动标签」仍指向同一会话
        if let ni = workspace.sessions.firstIndex(where: { $0.id == activeID }) {
            workspace.activeIndex = ni
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        draggingTabID = nil
        return true
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
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { d in
                    if !dragging {
                        dragging = true
                        startWidth = width   // 记手势起点宽度
                    }
                    let dx = d.location.x - d.startLocation.x   // 全局差值，与分隔条自身移动无关
                    width = min(max(startWidth + Double(dx), 150), 420)
                }
                .onEnded { _ in
                    dragging = false
                    if !hovering { NSCursor.arrow.set() }   // 松手时已不在边界上则恢复箭头
                }
        )
        .accessibilityLabel("调整印章库宽度")
    }
}
