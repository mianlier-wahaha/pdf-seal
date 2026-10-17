import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers
import SealCore

// MARK: - 页面管理：网格缩略图（点击选择 / ⌘ 多选 / ⇧ 连选 / 拖拽排序）+ 旋转/删除/插入/复制/粘贴/提取/度量

struct PageManageView: View {
    @EnvironmentObject private var doc: DocumentStore
    @EnvironmentObject private var settings: StampSettings

    /// 双击某页 → 切到预览并定位该页（由 ContentView 提供）
    let onOpenPage: (Int) -> Void

    @State private var selection = Set<UUID>()
    @State private var anchorIndex: Int?      // ⇧ 连选锚点
    @State private var draggingIndex: Int?
    @State private var dropTargetIndex: Int?
    @State private var scope: PageScope = .selected
    @State private var showMeasure = false
    /// 全局共享缩略图缓存（按文档身份隔离 + 后台预取）：切标签回来零重渲染
    @ObservedObject private var thumbStore = ThumbStore.shared
    @State private var status: String?
    @State private var errorText: String?
    // 插入弹窗（工具栏入口，弹窗内自选位置）
    @State private var showInsertFile = false
    @State private var showInsertClipboard = false
    @State private var showInterleave = false
    @State private var showSplit = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if doc.document == nil {
                emptyState
            } else {
                pageGrid
            }
        }
        .sheet(isPresented: $showMeasure) {
            MeasureSheet(scope: .selected, selected: selectedIndices)
        }
        .sheet(isPresented: $showInsertFile) {
            InsertFromFileSheet(fixedAt: nil) { at, url, srcPages in
                performInsert(at: at) { doc.insertPages(from: url, sourcePages: srcPages, at: at) }
            }
        }
        .sheet(isPresented: $showInsertClipboard) {
            InsertFromClipboardSheet(fixedAt: nil) { at in
                performInsert(at: at) { doc.pastePages(at: at) }
            }
        }
        .sheet(isPresented: $showInterleave) {
            InterleaveSheet { inserted, mapping in
                settings.remapPages(mapping)
                settings.setPageCount(doc.pageCount)
                selection.removeAll()
                anchorIndex = nil
                status = LF("已交叉插入 %d 页", inserted)
            }
        }
        .sheet(isPresented: $showSplit) {
            SplitSheet { files in
                status = LF("已拆分为 %d 个 PDF", files.count)
                NSWorkspace.shared.activateFileViewerSelecting(files)
            }
        }
        .alert(L("出错了"), isPresented: .init(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(L("好"), role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .onChange(of: doc.revision) { _ in
            thumbStore.invalidate(document: doc.document)   // 页序/内容已变，整本失效重渲染
        }
        .onChange(of: doc.url) { _ in
            // 切换会话（换文档）：选择状态失效；缩略图由 ThumbStore 按文档身份隔离，
            // 新文档载入即预取，旧文档缓存保留（切回即用）
            selection.removeAll()
            anchorIndex = nil
            scope = .selected
            status = nil
            errorText = nil
            thumbStore.prefetch(document: doc.document, width: 170)
        }
        .onAppear {
            thumbStore.prefetch(document: doc.document, width: 170)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(L("把 PDF 拖进来，或点「打开」选择文件"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 工具栏（顺序：范围 → 旋转/删除 | 插入页/复制/粘贴/提取 | 度量）

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $scope) {
                Text(L("自定义")).tag(PageScope.selected)
                Text(L("奇数页")).tag(PageScope.odd)
                Text(L("偶数页")).tag(PageScope.even)
                Text(L("全部页")).tag(PageScope.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .help(L("点选范围即把对应页填入选中集；手动增减选页会自动切回「自定义」"))
            .onChange(of: scope) { newScope in
                guard newScope != .selected else { return }
                // 切换范围 = 之前的手动选中状态被清除，改为物化对应页集
                let ids: [UUID]
                switch newScope {
                case .odd:  ids = doc.pageIDs.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
                case .even: ids = doc.pageIDs.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
                case .all:  ids = doc.pageIDs
                case .selected: ids = []
                }
                selection = Set(ids)
                anchorIndex = nil
            }

            Button { rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }
                .help(L("向左旋转 90°"))
            Button { rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }
                .help(L("向右旋转 90°"))

            Button { deleteSelected() } label: { Label(L("删除"), systemImage: "trash") }
                .keyboardShortcut(.delete, modifiers: [])
                .help(L("删除选中页（页码联动收缩）"))

            Divider().frame(height: 18)

            Menu {
                Button(L("插入空白页")) { insertBlank(at: nil) }
                Button(L("从文件插入…")) { showInsertFile = true }
                Button(L("从剪贴板插入…")) { showInsertClipboard = true }
                Divider()
                Button(L("交叉插入…")) { showInterleave = true }
            } label: { Label(L("插入页"), systemImage: "plus.rectangle.on.rectangle") }
                .fixedSize()
                .help(L("插入到选中页之后；未选中则插到末尾"))

            Button { copyScope() } label: { Label(L("复制"), systemImage: "doc.on.doc") }
                .keyboardShortcut("c", modifiers: .command)
                .help(L("复制应用范围内的页"))
            Button { paste() } label: { Label(L("粘贴"), systemImage: "doc.on.clipboard") }
                .keyboardShortcut("v", modifiers: .command)
                .help(L("粘贴到选中页之后"))
            Button { extractSelected() } label: { Label(L("提取"), systemImage: "arrow.up.left.square") }
                .help(L("提取选中页另存"))
            Button { reverseOrder() } label: { Label(L("倒序"), systemImage: "arrow.up.arrow.down") }
                .help(L("把当前 PDF 按倒序重新排列"))
            Button { showSplit = true } label: { Label(L("拆分"), systemImage: "rectangle.split.2x1") }
                .disabled(doc.url == nil)
                .help(L("按页数把当前 PDF 拆分为多个文件"))

            Divider().frame(height: 18)

            Button { showMeasure = true } label: { Label(L("度量"), systemImage: "ruler") }
                .help(L("度量 — 修改画幅"))

            Spacer()
            Text(L("⌘ 多选 · ⇧ 连选 · 拖动排序"))
                .font(.caption)
                .foregroundStyle(.tertiary)
            if let s = status {
                Text(s).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: 页网格（缩略图 + 页码；选中/范围命中页高亮）

    private var pageGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 14)], spacing: 14) {
                ForEach(pageItems) { item in
                    pageCell(item)
                }
            }
            .padding(14)
            .id(doc.revision)   // 页面编辑后重建单元格，重新触发 onAppear 渲染
        }
    }

    private func pageCell(_ item: PageItem) -> some View {
        let i = item.index
        let hit = highlightIndices.contains(i)
        let isDropTarget = dropTargetIndex == i
        let aspect = doc.pageSizes.indices.contains(i)
            ? max(doc.pageSizes[i].width / max(doc.pageSizes[i].height, 1), 0.3)
            : 0.707
        return VStack(spacing: 5) {
            Group {
                if let img = thumb(at: i) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 168)
                } else {
                    // 占位：按真实页型比例留位，后台渲染完成后自动替换
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .aspectRatio(aspect, contentMode: .fit)
                        .frame(maxHeight: 168)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isDropTarget ? Color.accentColor
                            : hit ? Color.accentColor
                            : Color(nsColor: .separatorColor),
                            lineWidth: isDropTarget ? 3 : hit ? 2.5 : 0.5)
            )
            .shadow(color: hit ? Color.accentColor.opacity(0.25) : .clear, radius: 4)
            Text("\(i + 1)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(hit ? Color.accentColor : .secondary)
        }
        .contentShape(Rectangle())
        // 单击即时响应：不用 onTapGesture(count:2)——它会扣住单击等双击判定窗口
        // （跟随系统双击间隔，慢设置下明显延迟）；改用事件 clickCount 区分双击。
        .onTapGesture {
            if NSApp.currentEvent?.clickCount == 2 {
                onOpenPage(i)
            } else {
                handleTap(i)
            }
        }
        .onAppear { requestThumb(i) }
        .onDrag {
            draggingIndex = i
            return NSItemProvider(object: "\(i)" as NSString)
        }
        .onDrop(of: [UTType.text], delegate: PageDropDelegate(
            target: i,
            onEnter: { dropTargetIndex = i },
            onDrop: { completeDrop(to: i) }
        ))
    }

    /// 高亮集合 = 选中集（切换范围时已物化为选中）
    private var highlightIndices: Set<Int> {
        Set(selectedIndices)
    }

    private var pageItems: [PageItem] {
        doc.pageIDs.enumerated().map { PageItem(id: $1, index: $0) }
    }

    private var selectedIndices: [Int] {
        selection.compactMap { id in doc.pageIDs.firstIndex(of: id) }.sorted()
    }

    private func thumb(at index: Int) -> NSImage? {
        guard let d = doc.document else { return nil }
        return thumbStore.image(for: ObjectIdentifier(d), page: index)
    }

    // MARK: 缩略图异步渲染（全局缓存 + 后台限流预取，主线程零阻塞）

    /// 请求某页缩略图：命中缓存即时返回；未命中由 ThumbStore 后台渲染（防重复提交）
    private func requestThumb(_ index: Int) {
        guard let d = doc.document else { return }
        thumbStore.request(document: d, page: index, width: 170)
    }

    // MARK: 选择（单击单选 / ⌘ 切换 / ⇧ 连选）

    private func handleTap(_ i: Int) {
        let flags = NSApp.currentEvent?.modifierFlags
            .intersection(.deviceIndependentFlagsMask) ?? []
        let id = doc.pageIDs[i]
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchorIndex = i
        } else if flags.contains(.shift), let a = anchorIndex, anchorIndex != i {
            selection = Set((min(a, i)...max(a, i)).compactMap { doc.pageIDs.indices.contains($0) ? doc.pageIDs[$0] : nil })
        } else {
            selection = [id]
            anchorIndex = i
        }
        // 在奇数页/偶数页/全部页状态下手动增减选页 → 自动切回「自定义」
        if scope != .selected { scope = .selected }
    }

    // MARK: 操作

    /// 操作目标 = 选中集（切换范围时已物化，手动改选即自定义）
    private func pagesForScope() -> [Int] {
        selectedIndices
    }

    private func apply(_ mapping: [Int?]?) {
        settings.remapPages(mapping)
        settings.setPageCount(doc.pageCount)
        selection.removeAll()   // 行 id 已整体重建
        anchorIndex = nil
        dropTargetIndex = nil
        draggingIndex = nil
        scope = .selected      // 页集已变，范围回「自定义」
    }

    private func rotate(clockwise: Bool) {
        let targets = pagesForScope()
        guard !targets.isEmpty else { errorText = L("请先选择页"); return }
        doc.pushPageUndo(stampState: settings.capturePageState())
        doc.rotatePages(targets, clockwise: clockwise)
        status = LF("已旋转 %d 页", targets.count)
    }

    /// 复制：跟随应用范围（选中页/奇数页/偶数页/全部页）
    private func copyScope() {
        let targets = pagesForScope()
        guard !targets.isEmpty else {
            errorText = L("请先选择页"); return
        }
        doc.copyPages(targets)
        status = LF("已复制 %d 页", targets.count)
    }

    private func deleteSelected() {
        let targets = pagesForScope()
        guard !targets.isEmpty else {
            errorText = L("请先选择要删除的页（至少保留一页）"); return
        }
        guard targets.count < doc.pageCount else {
            errorText = L("不能删除全部页面（至少保留一页）"); return
        }
        doc.pushPageUndo(stampState: settings.capturePageState())
        let mapping = doc.deletePages(Set(targets))
        if mapping == nil {
            errorText = L("请先选择要删除的页（至少保留一页）"); return
        }
        apply(mapping)
        status = LF("已删除 %d 页", mapping!.filter { $0 == nil }.count)
    }

    /// 拖拽放下的落点：被移动页插入到目标页位置
    private func completeDrop(to target: Int) -> Bool {
        defer { draggingIndex = nil; dropTargetIndex = nil }
        guard let from = draggingIndex, from != target else { return false }
        let moving = (selection.contains(doc.pageIDs[from]) && selectedIndices.count > 1)
            ? selectedIndices
            : [from]
        let movedSet = Set(moving)
        guard !movedSet.contains(target) else { return false }
        var order = Array(0..<doc.pageCount).filter { !movedSet.contains($0) }
        let insertAt = order.firstIndex(of: target)!
        order.insert(contentsOf: moving, at: insertAt)
        doc.pushPageUndo(stampState: settings.capturePageState())
        guard let mapping = doc.reorderPages(newOrder: order) else { return false }
        apply(mapping)
        status = LF("已移动 %d 页", moving.count)
        return true
    }

    /// 统一插入收尾：包裹撤销快照、重映射、状态提示。perform 返回插入页数（0 = 失败）。
    private func performInsert(at: Int, _ perform: () -> Int) {
        doc.pushPageUndo(stampState: settings.capturePageState())
        let n = perform()
        guard n > 0 else {
            errorText = L("没有可插入的内容"); return
        }
        apply(shiftMapping(total: doc.pageCount - n, insertAt: at, count: n))
        status = LF("已插入 %d 页", n)
    }

    private func insertBlank(at index: Int?) {
        let at = index ?? (selectedIndices.last.map { $0 + 1 } ?? doc.pageCount)
        let refIndex = selectedIndices.last ?? min(doc.pageCount - 1, 0)
        guard let ref = doc.pageSizes.indices.contains(refIndex) ? doc.pageSizes[refIndex] : nil,
              ref.width > 0 else {
            errorText = L("无法确定空白页尺寸"); return
        }
        doc.pushPageUndo(stampState: settings.capturePageState())
        guard doc.insertBlankPage(at: at, size: ref) else { return }
        apply(shiftMapping(total: doc.pageCount - 1, insertAt: at, count: 1))
        status = LF("已插入空白页（第 %d 页）", at + 1)
    }

    /// 全部页倒序重排
    private func reverseOrder() {
        guard doc.pageCount > 1 else {
            errorText = L("至少需要两页才能倒序"); return
        }
        doc.pushPageUndo(stampState: settings.capturePageState())
        let mapping = doc.reversePages()
        apply(mapping)
        status = L("已按倒序重排全部页")
    }

    /// 插入 n 页后的旧→新映射：插入位置及之后的旧页顺延
    private func shiftMapping(total: Int, insertAt: Int, count: Int) -> [Int?] {
        (0..<total).map { $0 >= insertAt ? $0 + count : $0 }
    }

    private func extractSelected() {
        let targets = pagesForScope()
        guard !targets.isEmpty else { errorText = L("请先选择页"); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = L("提取页")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if doc.extractPages(targets, to: url) {
            status = LF("已提取 %d 页 → %@", targets.count, url.lastPathComponent)
        } else {
            errorText = L("提取失败")
        }
    }

    private func paste() {
        let at = (selectedIndices.last.map { $0 + 1 }) ?? doc.pageCount
        doc.pushPageUndo(stampState: settings.capturePageState())
        let n = doc.pastePages(at: at)
        guard n > 0 else { errorText = L("剪贴板中没有可粘贴的 PDF 页"); return }
        apply(shiftMapping(total: doc.pageCount - n, insertAt: at, count: n))
        status = LF("已粘贴 %d 页", n)
    }
}

// MARK: - 网格拖放 Delegate

private struct PageDropDelegate: DropDelegate {
    let target: Int
    let onEnter: () -> Void
    let onDrop: () -> Bool

    func dropEntered(info: DropInfo) { onEnter() }
    func performDrop(info: DropInfo) -> Bool { onDrop() }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

// MARK: - 度量：实测画幅 → 改宽高（mm）→ 九宫格锚点 → 应用

/// 度量弹窗的常用纸型预设（mm）
enum PaperPreset: CaseIterable, Hashable {
    case a3, a4, a5, b5, letter, legal

    var name: String {
        switch self {
        case .a3: "A3"; case .a4: "A4"; case .a5: "A5"
        case .b5: "B5"; case .letter: L("Letter"); case .legal: L("Legal")
        }
    }
    var widthMm: Double {
        switch self {
        case .a3: 297; case .a4: 210; case .a5: 148
        case .b5: 176; case .letter: 216; case .legal: 216
        }
    }
    var heightMm: Double {
        switch self {
        case .a3: 420; case .a4: 297; case .a5: 210
        case .b5: 250; case .letter: 279; case .legal: 356
        }
    }
}

struct MeasureSheet: View {
    @EnvironmentObject private var doc: DocumentStore
    @EnvironmentObject private var settings: StampSettings
    @Environment(\.dismiss) private var dismiss

    let scope: PageScope
    let selected: [Int]

    @State private var widthMm: String = ""
    @State private var heightMm: String = ""
    @State private var ax: Int = 1   // 0 左 1 中 2 右
    @State private var ay: Int = 1   // 0 上 1 中 2 下
    @State private var errorText: String?

    private var targets: [Int] { doc.indices(for: scope, selected: selected) }

    private var referenceSize: CGSize? {
        guard let first = targets.first, doc.pageSizes.indices.contains(first) else { return nil }
        return doc.pageSizes[first]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("度量 — 修改画幅")).font(.headline)

            if let s = referenceSize {
                let pt = { (v: CGFloat) in String(format: "%.1f", v) }
                let mm = { (v: CGFloat) in String(format: "%.1f", v / 72 * 25.4) }
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(mm(s.width)) × \(mm(s.height)) mm（\(pt(s.width)) × \(pt(s.height)) pt）")
                            .font(.title3.monospacedDigit())
                        Text(paperLine(s))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }

            HStack(spacing: 12) {
                Text(L("新画幅")).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(L("宽")); TextField("210", text: $widthMm).frame(width: 70)
                    Text(L("高")); TextField("297", text: $heightMm).frame(width: 70)
                    Text("mm").foregroundStyle(.secondary)
                }
            }

            // 常用纸型预设：一键填入宽高
            HStack(spacing: 6) {
                Text(L("预设")).foregroundStyle(.secondary)
                ForEach([PaperPreset.a3, .a4, .a5, .b5, .letter, .legal], id: \.self) { p in
                    Button(p.name) {
                        widthMm = String(format: "%.0f", p.widthMm)
                        heightMm = String(format: "%.0f", p.heightMm)
                    }
                    .controlSize(.small)
                    .help("\(p.name)：\(Int(p.widthMm)) × \(Int(p.heightMm)) mm")
                }
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("内容锚点")).foregroundStyle(.secondary)
                    anchorGrid
                    Text(L("内容等比放缩适配新画幅，不会截取丢失信息"))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("应用范围")).foregroundStyle(.secondary)
                    Text(scope.label).font(.title3)
                    Text(LF("共 %d 页", targets.count)).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let e = errorText { Text(e).font(.callout).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button(L("取消"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(DialogButtonStyle())
                Button(L("应用")) { applyMeasure() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(DialogButtonStyle(prominent: true))
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { prefill() }
    }

    private func paperLine(_ s: CGSize) -> String {
        PaperSize.guess(widthPt: s.width, heightPt: s.height)
            .map { LF("纸型估计：%@", $0) } ?? L("非标准纸型")
    }

    private func prefill() {
        guard let s = referenceSize else { return }
        if widthMm.isEmpty { widthMm = String(format: "%.0f", s.width / 72 * 25.4) }
        if heightMm.isEmpty { heightMm = String(format: "%.0f", s.height / 72 * 25.4) }
    }

    private var anchorGrid: some View {
        VStack(spacing: 3) {
            ForEach(0..<3) { row in
                HStack(spacing: 3) {
                    ForEach(0..<3) { col in
                        Rectangle()
                            .fill(ax == col && ay == row ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.4))
                            .frame(width: 22, height: 22)
                            .cornerRadius(4)
                            .contentShape(Rectangle())
                            .onTapGesture { ax = col; ay = row }
                    }
                }
            }
        }
    }

    private func applyMeasure() {
        guard let w = Double(widthMm), let h = Double(heightMm), w > 10, h > 10 else {
            errorText = L("请输入有效的宽高（mm，需大于 10）"); return
        }
        let pt = 72.0 / 25.4
        doc.pushPageUndo(stampState: settings.capturePageState())
        let ok = doc.resizePages(targets, widthPt: CGFloat(w * pt), heightPt: CGFloat(h * pt), ax: ax, ay: ay)
        guard ok else {
            errorText = L("画幅调整失败"); return
        }
        settings.remapPages((0..<doc.pageCount).map { $0 as Int? })   // 页序不变，仅同步页数
        settings.setPageCount(doc.pageCount)
        dismiss()
    }
}

// MARK: - 插入位置（弹窗共用模型 + 选择器）

struct InsertPosition: Equatable {
    enum Anchor: Hashable { case first, last, custom }

    var anchor: Anchor = .last
    var customPage: Int = 1
    var after: Bool = true

    /// 解析为 0-based 插入间隙下标；fixedAt 非 nil 时直接采用
    func resolve(total: Int, fixedAt: Int?) -> Int {
        if let f = fixedAt { return min(max(f, 0), total) }
        let a: Int
        switch anchor {
        case .first: a = 0
        case .last: a = max(total - 1, 0)
        case .custom: a = min(max(customPage, 1), max(total, 1)) - 1
        }
        return after ? a + 1 : a
    }

    /// 固定间隙位置的描述文案（网格加号入口）
    static func fixedLabel(_ at: Int, total: Int) -> String {
        if at <= 0 { return L("插入到最前面") }
        if at >= total { return L("插入到末尾") }
        return LF("插入到第 %d 页之后", at)
    }
}

/// 「页面：第一页/最后一页/自定义 + 位置：之前/之后」选择器（学习 UPDF 弹窗布局）
struct InsertPositionPicker: View {
    @Binding var pos: InsertPosition
    let total: Int
    var rowSpacing: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("页面")).foregroundStyle(.secondary)
                Picker("", selection: $pos.anchor) {
                    Text(L("第一页")).tag(InsertPosition.Anchor.first)
                    Text(L("最后一页")).tag(InsertPosition.Anchor.last)
                    Text(L("自定义")).tag(InsertPosition.Anchor.custom)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if pos.anchor == .custom {
                    HStack(spacing: 6) {
                        Stepper(value: $pos.customPage, in: 1...max(total, 1)) {
                            TextField("1", value: $pos.customPage, formatter: NumberFormatter())
                                .frame(width: 54)
                                .multilineTextAlignment(.center)
                        }
                        Text(LF("/ %d", total)).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 22)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("位置")).foregroundStyle(.secondary)
                Picker("", selection: $pos.after) {
                    Text(L("之前")).tag(false)
                    Text(L("之后")).tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        }
    }
}

// MARK: - 从文件插入

struct InsertFromFileSheet: View {
    @EnvironmentObject private var doc: DocumentStore
    @Environment(\.dismiss) private var dismiss

    /// 非 nil = 网格间隙加号进入（位置锁定）；nil = 工具栏进入（弹窗内选位置）
    let fixedAt: Int?
    let onInsert: (_ at: Int, _ url: URL, _ sourcePages: [Int]?) -> Void

    @State private var sourceURL: URL?
    @State private var srcPageCount = 0
    @State private var rangeStart = ""
    @State private var rangeEnd = ""
    @State private var pos = InsertPosition()
    @State private var errorText: String?

    private var insertIndex: Int? {
        sourceURL == nil ? nil : pos.resolve(total: doc.pageCount, fixedAt: fixedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("从文件插入")).font(.headline)

            HStack(alignment: .top, spacing: 26) {
                // 左列：来源 + 页面范围
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("来源")).foregroundStyle(.secondary)
                    SourceFileCard(
                        fileName: sourceURL?.lastPathComponent,
                        subline: sourceURL == nil ? nil : LF("%d 页", srcPageCount)
                    ) { url, pages in
                        sourceURL = url
                        srcPageCount = pages
                        errorText = nil
                    }
                    Text(L("页面范围")).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField(L("起"), text: $rangeStart)
                            .frame(width: 84)
                            .multilineTextAlignment(.center)
                        Text("–").foregroundStyle(.secondary)
                        TextField(L("止"), text: $rangeEnd)
                            .frame(width: 84)
                            .multilineTextAlignment(.center)
                    }
                    Text(L("留空 = 插入全部页"))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 右列：插入到（原文件）+ 位置
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("插入到（原文件）")).foregroundStyle(.secondary)
                    Text("\(doc.displayName) · \(doc.pageCount) 页")
                        .font(.callout)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let f = fixedAt {
                        Text(InsertPosition.fixedLabel(f, total: doc.pageCount))
                            .font(.callout)
                            .foregroundStyle(Color.accentColor)
                    } else {
                        InsertPositionPicker(pos: $pos, total: doc.pageCount, rowSpacing: 12)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let e = errorText { Text(e).font(.callout).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button(L("取消"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(DialogButtonStyle())
                Button(L("插入")) { doInsert() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(DialogButtonStyle(prominent: true))
                    .disabled(insertIndex == nil)
            }
        }
        .padding(24)
        .frame(width: 600)
    }

    private func doInsert() {
        guard let u = sourceURL else { return }
        var pages: [Int]? = nil
        let s = Int(rangeStart.trimmingCharacters(in: .whitespaces))
        let e = Int(rangeEnd.trimmingCharacters(in: .whitespaces))
        if s != nil || e != nil {
            guard let st = s, let en = e, st >= 1, en >= st, en <= srcPageCount else {
                errorText = LF("页面范围无效（1 – %d）", srcPageCount); return
            }
            pages = Array((st - 1)...(en - 1))
        }
        guard let at = insertIndex else { return }
        onInsert(at, u, pages)
        dismiss()
    }
}

// MARK: - 从剪贴板插入

struct InsertFromClipboardSheet: View {
    @EnvironmentObject private var doc: DocumentStore
    @Environment(\.dismiss) private var dismiss

    let fixedAt: Int?
    let onInsert: (_ at: Int) -> Void

    @State private var preview: NSImage?
    @State private var clipPages = 0
    @State private var pos = InsertPosition()

    private var insertIndex: Int? {
        clipPages > 0 ? pos.resolve(total: doc.pageCount, fixedAt: fixedAt) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("从剪贴板插入")).font(.headline)

            HStack(alignment: .top, spacing: 20) {
                // 左列：剪贴板内容预览
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("剪贴板内容")).foregroundStyle(.secondary)
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.08), radius: 3)
                        if let img = preview {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFit()
                                .padding(10)
                        } else {
                            Text(L("剪贴板中没有可插入的 PDF 或图片"))
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(20)
                        }
                    }
                    .frame(height: 220)
                    if clipPages > 0 {
                        Text(LF("共 %d 页", clipPages)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 右列：插入位置
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("插入到（原文件）")).foregroundStyle(.secondary)
                    Text("\(doc.displayName) · \(doc.pageCount) 页")
                        .font(.callout)
                        .lineLimit(2)
                    if let f = fixedAt {
                        Text(InsertPosition.fixedLabel(f, total: doc.pageCount))
                            .font(.callout)
                            .foregroundStyle(Color.accentColor)
                    } else {
                        InsertPositionPicker(pos: $pos, total: doc.pageCount)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button(L("取消"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(DialogButtonStyle())
                Button(L("插入")) {
                    guard let at = insertIndex else { return }
                    onInsert(at)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(insertIndex == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            preview = doc.clipboardPreview()
            clipPages = doc.clipboardPageCount
        }
    }
}

// MARK: - 交叉插入（正反扫描件拼合）

struct InterleaveSheet: View {
    @EnvironmentObject private var doc: DocumentStore
    @EnvironmentObject private var settings: StampSettings
    @Environment(\.dismiss) private var dismiss

    /// 完成回调：父视图做重映射与状态提示
    let onDone: (_ inserted: Int, _ mapping: [Int?]) -> Void

    @State private var sourceURL: URL?
    @State private var srcPageCount = 0
    @State private var sourceReversed = false
    @State private var targetReversed = false
    @State private var mode: DocumentStore.InterleaveMode = .oddPositions

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("交叉插入")).font(.headline)

            HStack(alignment: .top, spacing: 26) {
                // 左列：来源（与「从文件插入」同款虚线卡片，UI 统一）
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("来源")).foregroundStyle(.secondary)
                    SourceFileCard(
                        fileName: sourceURL?.lastPathComponent,
                        subline: sourceURL == nil ? nil : LF("%d 页", srcPageCount)
                    ) { url, pages in
                        sourceURL = url
                        srcPageCount = pages
                    }
                    Toggle(L("来源倒序"), isOn: $sourceReversed)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 右列：插入到（原文件）
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("插入到（原文件）")).foregroundStyle(.secondary)
                    Text("\(doc.displayName) · \(doc.pageCount) 页")
                        .font(.callout)
                        .lineLimit(2)
                    Toggle(L("原文件倒序"), isOn: $targetReversed)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 插入方式：奇数页 / 偶数页（带示意图）
            VStack(alignment: .leading, spacing: 8) {
                Text(L("插入方式")).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    modeCard(.oddPositions, title: L("奇数页插入"))
                    modeCard(.evenPositions, title: L("偶数页插入"))
                }
                Text(modeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(L("取消"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(DialogButtonStyle())
                Button(L("插入")) { doInsert() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(DialogButtonStyle(prominent: true))
                    .disabled(sourceURL == nil || srcPageCount == 0)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var modeHint: String {
        mode == .oddPositions
            ? L("新 PDF 每页依次占据结果的奇数位：新1 原1 新2 原2 新3 原3 …（原文件页用完后新页顺次追加）")
            : L("新 PDF 每页依次占据结果的偶数位：原1 新1 原2 新2 原3 新3 …（原文件页用完后新页顺次追加）")
    }

    /// 交错示意图：蓝块 = 新页（来源），灰块 = 原页
    private func modeCard(_ m: DocumentStore.InterleaveMode, title: String) -> some View {
        let chips: [(isNew: Bool, n: Int)] = m == .oddPositions
            ? [(true, 1), (false, 1), (true, 2), (false, 2), (true, 3), (false, 3)]
            : [(false, 1), (true, 1), (false, 2), (true, 2), (false, 3), (true, 3)]
        let selected = mode == m
        return Button {
            mode = m
        } label: {
            VStack(spacing: 8) {
                HStack(spacing: 3) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, c in
                        Text("\(c.n)")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(c.isNew ? Color.white : Color.primary)
                            .frame(width: 24, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(c.isNew ? Color.accentColor
                                          : Color(nsColor: .separatorColor).opacity(0.45))
                            )
                    }
                }
                HStack(spacing: 10) {
                    Label(L("原页"), systemImage: "square.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                    Label(L("新页"), systemImage: "square.fill")
                        .font(.caption2).foregroundStyle(Color.accentColor)
                }
                Text(title).font(.callout.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func doInsert() {
        guard let u = sourceURL, srcPageCount > 0 else { return }
        // 撤销快照在本弹窗内压入（插入动作也在此发生）
        doc.pushPageUndo(stampState: settings.capturePageState())
        guard let r = doc.interleaveInsert(from: u, sourceReversed: sourceReversed,
                                           targetReversed: targetReversed, mode: mode) else {
            dismiss(); return
        }
        onDone(r.inserted, r.mapping)
        dismiss()
    }
}

// MARK: - 拆分文档（按页数 / 按大小）

struct SplitSheet: View {
    enum SplitMode: Hashable { case pages, size }

    @EnvironmentObject private var doc: DocumentStore
    @Environment(\.dismiss) private var dismiss

    let onDone: (_ files: [URL]) -> Void

    @State private var mode: SplitMode = .pages
    @State private var pagesPer = "1"
    @State private var sizeMB = ""            // 默认留空：用户输入后才估算
    @State private var byteSizes: [Int] = []
    @State private var computingSizes = false
    @State private var estimateGen = 0        // 估算代次，丢弃过期结果
    @State private var errorText: String?

    private var pageCount: Int { max(doc.pageCount, 0) }

    /// 用户输入的有效每份大小（MB），未输入或非法时为 nil
    private var validMB: Double? {
        let v = Double(sizeMB.trimmingCharacters(in: .whitespaces))
        return (v != nil && v! > 0) ? v : nil
    }

    private var parts: Int? {
        switch mode {
        case .pages:
            guard let n = Int(pagesPer.trimmingCharacters(in: .whitespaces)), n >= 1 else { return nil }
            return (pageCount + n - 1) / n
        case .size:
            guard let mb = validMB else { return nil }
            guard !computingSizes, !byteSizes.isEmpty else { return nil }   // 估算未完成时只显示进度
            let limit = Int(mb * 1024 * 1024)
            var count = 0, acc = 0, pagesInChunk = 0
            for s in byteSizes {
                if pagesInChunk > 0 && acc + s > limit { count += 1; acc = 0; pagesInChunk = 0 }
                acc += s; pagesInChunk += 1
            }
            if pagesInChunk > 0 { count += 1 }
            return count
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("拆分文档")).font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text(L("文档拆分方式")).foregroundStyle(.secondary)
                Picker("", selection: $mode) {
                    Text(L("按页数拆分")).tag(SplitMode.pages)
                    Text(L("按大小拆分")).tag(SplitMode.size)
                }
                .pickerStyle(.menu)
                .frame(width: 220)
                .labelsHidden()
            }

            Divider()

            switch mode {
            case .pages:
                HStack(spacing: 8) {
                    Text(L("每份页数")).foregroundStyle(.secondary)
                    TextField("1", text: $pagesPer)
                        .frame(width: 64)
                        .multilineTextAlignment(.center)
                    Text(LF("（1 – %d）", pageCount))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            case .size:
                HStack(spacing: 8) {
                    Text(L("每份大小")).foregroundStyle(.secondary)
                    TextField("5", text: $sizeMB)
                        .frame(width: 64)
                        .multilineTextAlignment(.center)
                    Text(L("MB · 按各页实际数据量估算装箱")).font(.caption).foregroundStyle(.tertiary)
                }
            }

            if let p = parts {
                Label(LF("将创建 %d 个 PDF", p), systemImage: "doc.on.doc")
                    .foregroundStyle(Color.accentColor)
            }
            if mode == .size && validMB != nil && computingSizes {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("正在估算各页数据量…")).font(.caption).foregroundStyle(.secondary)
                }
            }

            Text(LF("输出到原文件所在文件夹，文件名形如「%@-01.pdf」",
                    doc.url?.deletingPathExtension().lastPathComponent ?? "文档"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)   // 长文件名自动换行
                .lineLimit(nil)

            if let e = errorText { Text(e).font(.callout).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button(L("取消"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(DialogButtonStyle())
                Button(L("拆分")) { doSplit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(DialogButtonStyle(prominent: true))
                    .disabled(parts == nil || doc.url == nil || computingSizes)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onChange(of: sizeMB) { _ in
            if mode == .size, validMB != nil, byteSizes.isEmpty { refreshSizes() }
        }
        .onChange(of: doc.revision) { _ in
            if mode == .size, validMB != nil { refreshSizes() }   // 页集变动即重估
        }
    }

    /// 各页字节数估算（供「将创建 X 个 PDF」预览）。
    /// 全程后台执行（含整册序列化）——主线程只收结果，不卡弹窗动画。
    /// 单页序列化会把全档共享资源重复计入（实测高估 ~60%），按整册实际字节数归一化修正。
    private func refreshSizes() {
        guard !computingSizes, let d = doc.document, d.pageCount > 0 else { return }
        computingSizes = true
        estimateGen += 1
        let gen = estimateGen
        DispatchQueue.global(qos: .userInitiated).async {
            let full = d.dataRepresentation() ?? Data()   // 整册序列化 = 归一化基准（后台执行）
            var raw: [Int] = []
            if let d2 = PDFDocument(data: full) {   // 独立实例，后台线程安全
                raw = (0..<d2.pageCount).compactMap { d2.page(at: $0)?.dataRepresentation?.count }
            }
            let rawSum = raw.reduce(0, +)
            let factor = (full.count > 0 && rawSum > 0) ? Double(full.count) / Double(rawSum) : 1.0
            let sizes = raw.map { max(Int((Double($0) * factor).rounded()), 1) }
            DispatchQueue.main.async {
                guard gen == estimateGen else { return }   // 已有更新代次的估算，丢弃本结果
                byteSizes = sizes
                computingSizes = false
            }
        }
    }

    private func doSplit() {
        guard let url = doc.url, doc.pageCount > 0 else {
            errorText = L("请先保存当前 PDF（⌘S）再拆分"); return
        }
        let directory = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        switch mode {
        case .pages:
            guard let n = Int(pagesPer.trimmingCharacters(in: .whitespaces)), n >= 1 else { return }
            // 按页数每次执行时实时读取当前文档（页数以当下为准）
            let files = doc.splitDocument(every: n, to: directory, baseName: baseName)
            guard !files.isEmpty else {
                errorText = L("写盘失败，请检查目标文件夹是否可写"); return
            }
            onDone(files)
            dismiss()
        case .size:
            guard let mb = validMB, !byteSizes.isEmpty, !computingSizes else { return }
            let limit = Int(mb * 1024 * 1024)
            // 直接使用已估算好的页字节数（页集变动时会自动重估），
            // 写盘时 splitDocument 自带「超限末页顺延」实测校准，无需再弹估算提示
            let files = doc.splitDocument(byMaxBytes: limit, sizes: byteSizes,
                                          to: directory, baseName: baseName)
            guard !files.isEmpty else {
                errorText = L("写盘失败，请检查目标文件夹是否可写"); return
            }
            onDone(files)
            dismiss()
        }
    }
}
