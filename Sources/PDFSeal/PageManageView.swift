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
    @State private var thumbs: [Int: NSImage] = [:]
    @State private var status: String?
    @State private var errorText: String?

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
            MeasureSheet(scope: scope, selected: selectedIndices)
        }
        .alert(L("出错了"), isPresented: .init(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(L("好"), role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .onChange(of: doc.revision) { _ in thumbs.removeAll() }
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
                Text(L("选中页")).tag(PageScope.selected)
                Text(L("奇数页")).tag(PageScope.odd)
                Text(L("偶数页")).tag(PageScope.even)
                Text(L("全部页")).tag(PageScope.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .help(L("操作应用范围"))

            Button { rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }
                .help(L("向左旋转 90°"))
            Button { rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }
                .help(L("向右旋转 90°"))

            Button { deleteSelected() } label: { Label(L("删除"), systemImage: "trash") }
                .keyboardShortcut(.delete, modifiers: [])
                .help(L("删除选中页（页码联动收缩）"))

            Divider().frame(height: 18)

            Menu {
                Button(L("插入空白页")) { insertBlank() }
                Button(L("从剪切板插入")) { paste() }
                Button(L("从文件插入…")) { insertFromFile() }
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
        }
    }

    private func pageCell(_ item: PageItem) -> some View {
        let i = item.index
        let hit = highlightIndices.contains(i)
        let isDropTarget = dropTargetIndex == i
        return VStack(spacing: 5) {
            Image(nsImage: thumb(at: i))
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 168)
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
        .onTapGesture(count: 2) { onOpenPage(i) }
        .onTapGesture { handleTap(i) }
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

    /// 高亮集合 = 选中页 ∪ 当前应用范围命中的页（奇偶/全部范围下直观可见）
    private var highlightIndices: Set<Int> {
        var s = Set(selectedIndices)
        if scope != .selected { s.formUnion(pagesForScope()) }
        return s
    }

    private var pageItems: [PageItem] {
        doc.pageIDs.enumerated().map { PageItem(id: $1, index: $0) }
    }

    private var selectedIndices: [Int] {
        selection.compactMap { id in doc.pageIDs.firstIndex(of: id) }.sorted()
    }

    private func thumb(at index: Int) -> NSImage {
        if let t = thumbs[index] { return t }
        guard let p = doc.document?.page(at: index) else { return NSImage() }
        let size = PageBox.displayedSize(p)
        let scale = 170.0 / max(size.width, 1)
        let img = p.thumbnail(of: CGSize(width: 170, height: max(size.height * scale, 40)), for: .mediaBox)
        thumbs[index] = img
        return img
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
    }

    // MARK: 操作

    private func pagesForScope() -> [Int] {
        doc.indices(for: scope, selected: selectedIndices)
    }

    private func apply(_ mapping: [Int?]?) {
        settings.remapPages(mapping)
        settings.setPageCount(doc.pageCount)
        selection.removeAll()   // 行 id 已整体重建
        anchorIndex = nil
        dropTargetIndex = nil
        draggingIndex = nil
    }

    private func rotate(clockwise: Bool) {
        let targets = pagesForScope()
        guard !targets.isEmpty else { errorText = L("请先选择页或切换应用范围"); return }
        doc.pushPageUndo(stampState: settings.capturePageState())
        doc.rotatePages(targets, clockwise: clockwise)
        status = LF("已旋转 %d 页", targets.count)
    }

    /// 复制：跟随应用范围（选中页/奇数页/偶数页/全部页）
    private func copyScope() {
        let targets = pagesForScope()
        guard !targets.isEmpty else {
            errorText = L("请先选择页或切换应用范围"); return
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

    private func insertFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]
        panel.message = L("选择要插入的 PDF（插入到选中页之后）")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let at = (selectedIndices.last.map { $0 + 1 }) ?? doc.pageCount
        doc.pushPageUndo(stampState: settings.capturePageState())
        let n = doc.insertPages(from: url, at: at)
        guard n > 0 else { errorText = L("无法读取该 PDF"); return }
        apply(shiftMapping(total: doc.pageCount - n, insertAt: at, count: n))
        status = LF("已插入 %d 页", n)
    }

    private func insertBlank() {
        let refIndex = selectedIndices.last ?? min(doc.pageCount - 1, 0)
        guard let ref = doc.pageSizes.indices.contains(refIndex) ? doc.pageSizes[refIndex] : nil,
              ref.width > 0 else {
            errorText = L("无法确定空白页尺寸"); return
        }
        let at = selectedIndices.last.map { $0 + 1 } ?? doc.pageCount
        doc.pushPageUndo(stampState: settings.capturePageState())
        guard doc.insertBlankPage(at: at, size: ref) else { return }
        apply(shiftMapping(total: doc.pageCount - 1, insertAt: at, count: 1))
        status = LF("已插入空白页（第 %d 页）", at + 1)
    }

    /// 插入 n 页后的旧→新映射：插入位置及之后的旧页顺延
    private func shiftMapping(total: Int, insertAt: Int, count: Int) -> [Int?] {
        (0..<total).map { $0 >= insertAt ? $0 + count : $0 }
    }

    private func extractSelected() {
        let targets = pagesForScope()
        guard !targets.isEmpty else { errorText = L("请先选择页或切换应用范围"); return }
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

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("内容锚点")).foregroundStyle(.secondary)
                    anchorGrid
                    Text(L("放大补白边 · 缩小裁切"))
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
                Button(L("应用")) { applyMeasure() }.keyboardShortcut(.defaultAction)
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
