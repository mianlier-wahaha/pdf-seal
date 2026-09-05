import SwiftUI
import PDFKit
import CoreGraphics
import SealCore

// MARK: - 文档

@MainActor
final class DocumentStore: ObservableObject {
    @Published var document: PDFDocument?
    @Published var url: URL?
    @Published var pageSizes: [CGSize] = []
    @Published var loadError: String?

    var displayName: String { url?.lastPathComponent ?? "未打开文件" }
    var pageCount: Int { pageSizes.count }

    func load(_ url: URL) {
        guard url.pathExtension.lowercased() == "pdf" else {
            loadError = L("仅支持 PDF 文件"); return
        }
        guard let d = PDFDocument(url: url), d.pageCount > 0 else {
            loadError = L("无法打开 PDF（可能已加密或损坏）"); return
        }
        self.url = url
        document = d
        pageSizes = (0..<d.pageCount).map {
            guard let p = d.page(at: $0) else { return .zero }
            return PageBox.displayedSize(p)
        }
        loadError = nil
    }

    /// 关闭当前文档
    func close() {
        document = nil
        url = nil
        pageSizes = []
        loadError = nil
    }
}

// MARK: - 印章库（持久化）

struct SealItem: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var file: String
    /// 该章的标准物理尺寸（cm），设置一次后固定；nil = 未设置
    var widthCm: Double?
    var heightCm: Double?
}

@MainActor
final class SealStore: ObservableObject {
    @Published var seals: [SealItem] = []
    @Published var selectedID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedID?.uuidString, forKey: "lastSealID")
        }
    }
    @Published var importError: String?

    private let dir: URL
    private let manifestURL: URL
    private var cache: [UUID: NSImage] = [:]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pdf-seal", isDirectory: true)
        dir = base.appendingPathComponent("seals", isDirectory: true)
        manifestURL = dir.appendingPathComponent("manifest.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
        if let s = UserDefaults.standard.string(forKey: "lastSealID").flatMap(UUID.init(uuidString:)),
           seals.contains(where: { $0.id == s }) {
            selectedID = s
        } else {
            selectedID = seals.first?.id
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let items = try? JSONDecoder().decode([SealItem].self, from: data) else { return }
        seals = items.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.file).path) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(seals) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    func importSeal(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let img = NSImage(contentsOf: url),
              let cg = cgPixel(img) else {
            importError = L("无法读取图片，请使用 PNG/JPG"); return
        }
        let name = url.deletingPathExtension().lastPathComponent
        addProcessedSeal(name: name.isEmpty ? "印章" : name, cgImage: cg)
    }

    /// 新建图章对话框「创建」：保存处理好的章图并入库
    func addProcessedSeal(name: String, cgImage: CGImage) {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            importError = L("保存印章失败"); return
        }
        let id = UUID()
        let file = "\(id.uuidString).png"
        do {
            try png.write(to: dir.appendingPathComponent(file), options: .atomic)
        } catch {
            importError = LF("保存印章失败：%@", error.localizedDescription); return
        }
        seals.append(SealItem(id: id, name: name, file: file,
                              widthCm: nil, heightCm: nil))
        selectedID = id
        persist()
    }

    private func cgPixel(_ img: NSImage) -> CGImage? {
        var rect = CGRect(x: 0, y: 0, width: img.size.width, height: img.size.height)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    func rename(_ item: SealItem, to name: String) {
        guard let i = seals.firstIndex(where: { $0.id == item.id }) else { return }
        seals[i].name = name
        persist()
    }

    /// 读取章的默认物理尺寸（cm）
    func physicalSize(for id: UUID?) -> (widthCm: Double?, heightCm: Double?) {
        guard let item = seals.first(where: { $0.id == id }) else { return (nil, nil) }
        return (item.widthCm, item.heightCm)
    }

    /// 固化章的默认物理尺寸（cm），设置一次后固定
    func fixPhysicalSize(widthCm: Double? = nil, heightCm: Double? = nil, for id: UUID?) {
        guard let id, let i = seals.firstIndex(where: { $0.id == id }) else { return }
        if let w = widthCm { seals[i].widthCm = w }
        if let h = heightCm { seals[i].heightCm = h }
        persist()
    }

    func delete(_ item: SealItem) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(item.file))
        cache[item.id] = nil
        seals.removeAll { $0.id == item.id }
        if selectedID == item.id { selectedID = seals.first?.id }
        persist()
    }

    // MARK: 印章库排序

    /// 拖拽落位：把 dragged 移动到 target 当前位置（拖拽过程中实时调用，不落盘）
    func moveSeal(_ dragged: SealItem, to target: SealItem) {
        guard let from = seals.firstIndex(where: { $0.id == dragged.id }),
              let to = seals.firstIndex(where: { $0.id == target.id }),
              from != to else { return }
        seals.move(fromOffsets: IndexSet(integer: from),
                   toOffset: to > from ? to + 1 : to)
    }

    /// 拖拽结束后持久化顺序
    func persistOrder() {
        persist()
    }

    /// 选中印章后按 ↑/↓ 上下移动一位（越界自动忽略）
    func moveSelectedSeal(by delta: Int) {
        guard let id = selectedID,
              let i = seals.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard (0..<seals.count).contains(j) else { return }
        seals.swapAt(i, j)
        persist()
    }

    func image(for id: UUID?) -> NSImage? {
        guard let id, let item = seals.first(where: { $0.id == id }) else { return nil }
        if let img = cache[id] { return img }
        guard let img = NSImage(contentsOf: dir.appendingPathComponent(item.file)) else { return nil }
        cache[id] = img
        return img
    }

    func cgImage(for id: UUID?) -> CGImage? {
        image(for: id).flatMap {
            $0.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
    }

    /// 章图宽高比（w/h）
    func aspect(for id: UUID?) -> CGFloat {
        guard let cg = cgImage(for: id), cg.height > 0 else { return 1 }
        return CGFloat(cg.width) / CGFloat(cg.height)
    }

    /// 裁出印章图的一块（source 归一化、原点左上）
    func sliceImage(for id: UUID?, source: CGRect) -> NSImage? {
        guard let cg = cgImage(for: id) else { return nil }
        let crop = CGRect(x: source.minX * CGFloat(cg.width),
                          y: source.minY * CGFloat(cg.height),
                          width: source.width * CGFloat(cg.width),
                          height: source.height * CGFloat(cg.height))
        guard let sliced = cg.cropping(to: crop) else { return nil }
        return NSImage(cgImage: sliced,
                       size: NSSize(width: sliced.width, height: sliced.height))
    }
}

// MARK: - 盖章参数

/// 章实例状态快照（撤销用）
struct FullStampSnapshot: Equatable {
    var anchor: CGPoint
    var widthCm: Double
    var heightCm: Double
    var rotation: Double
    var opacity: Double
}

/// 一枚已添加的正文章实例
struct FullStampInstance: Identifiable, Equatable {
    let id: UUID
    let sealID: UUID           // 该章所用的印章（添加时锁定，切换印章库不影响）
    var anchor: CGPoint        // 章中心，归一化（原点左上）
    var widthCm: Double        // 章宽（物理 cm）
    var heightCm: Double       // 章高（物理 cm）
    var rotation: Double       // 度
    var opacity: Double
    var allPages: Bool
    var rangeStart: Int        // 1-based
    var rangeEnd: Int
    var removedPages: Set<Int> = []   // 0-based，按页删除

    func effectiveRange(pageCount: Int) -> ClosedRange<Int> {
        let total = max(pageCount, 1)
        if allPages { return 0...(total - 1) }
        let s = min(max(rangeStart, 1), total)
        let e = min(max(rangeEnd, s), total)
        return (s - 1)...(e - 1)
    }

    func covers(_ pageIndex: Int, pageCount: Int) -> Bool {
        effectiveRange(pageCount: pageCount).contains(pageIndex)
    }
}

/// 一条已添加的骑缝章实例
struct QifengInstance: Identifiable, Equatable {
    let id: UUID
    let sealID: UUID          // 锁定的印章
    let edge: SeamEdge
    var size: Double          // 章高占页高比例
    var offset: Double        // 上下偏移（负=下移，正=上移）
    var allPages: Bool
    var rangeStart: Int
    var rangeEnd: Int
    var removedPages: Set<Int> = []

    func effectiveRange(pageCount: Int) -> ClosedRange<Int> {
        let total = max(pageCount, 1)
        if allPages { return 0...(total - 1) }
        let s = min(max(rangeStart, 1), total)
        let e = min(max(rangeEnd, s), total)
        return (s - 1)...(e - 1)
    }
}

@MainActor
final class StampSettings: ObservableObject {
    @Published var edge: SeamEdge = .right
    @Published var allPages = true
    @Published var rangeStart = 1
    @Published var rangeEnd = 1
    @Published var qifengSize: Double = 0.15
    @Published var qifengOffset: Double = 0
    @Published var qifengOpacity: Double = 0.9

    // 骑缝章模板（「添加」时的初始选项）
    // qifengSize / qifengOffset 即模板参数
    // 已添加的骑缝章实例（可多条）
    @Published var qifengStamps: [QifengInstance] = []

    // 正文章模板（「添加」时的初始选项）
    @Published var fullAnchor: CGPoint = CGPoint(x: 0.75, y: 0.85)
    @Published var fullWidthCm: Double = 4.0
    @Published var fullHeightCm: Double = 4.0
    @Published var fullRotation: Double = 0
    @Published var fullOpacity: Double = 0.9
    @Published var fullAllPages = false
    @Published var fullRangeStart = 1
    @Published var fullRangeEnd = 1
    // 已添加的正文章实例（可多枚）
    @Published var fullStamps: [FullStampInstance] = []
    /// 多选：当前所有被选中章的 id 集合（唯一真相来源）
    @Published var selectedFullStampIDs: Set<UUID> = []
    /// 主选中（最后点击 / 添加的章），承载尺寸滑杆与缩放手柄的锚点
    private var primaryID: UUID?
    /// ⌘ 键实时状态（由 ContentView 的 flagsChanged 监听器写入）。
    /// 不能依赖 NSEvent.modifierFlags 在 .onTapGesture 闭包里读取——该闭包是手势结束后
    /// 异步派发的，全局修饰键状态往往已重置，导致判定恒为 false。故用实时跟踪值。
    @Published var commandKeyDown = false

    // MARK: - 撤销：统一时间线
    /// 撤销动作（按发生时间排序）。⌘Z 弹栈顶：添加则移除该章，几何则还原快照。
    private enum UndoAction {
        case add(UUID)                           // 撤销「添加」= 移除该章
        case geometry(UUID, FullStampSnapshot)   // 撤销「几何改动」= 还原快照
    }
    private var undoActions: [UndoAction] = []

    private(set) var pageCount = 0

    /// 关闭文档后清空所有盖章状态
    func clearDocumentState() {
        pageCount = 0
        qifengStamps = []
        fullStamps = []
        selectedFullStampIDs = []
        primaryID = nil
        undoActions = []
    }

    func syncPageCount(_ count: Int) {
        guard count > 0 else { return }
        pageCount = count
        rangeStart = 1
        rangeEnd = count
        fullRangeStart = count
        fullRangeEnd = count
        qifengStamps = []
        fullStamps = []
        selectedFullStampIDs = []
        primaryID = nil
        undoActions = []
    }

    /// 交互（拖动/缩放/点击落位/尺寸滑杆）开始前记录「改动前」快照，入统一时间线
    func pushUndo(_ id: UUID) {
        guard let inst = fullStamps.first(where: { $0.id == id }) else { return }
        let snap = FullStampSnapshot(anchor: inst.anchor, widthCm: inst.widthCm,
                                     heightCm: inst.heightCm, rotation: inst.rotation,
                                     opacity: inst.opacity)
        undoActions.append(.geometry(id, snap))
        if undoActions.count > 200 { undoActions.removeFirst() }
    }

    /// ⌘Z / Ctrl+Z：撤销时间线上「最近一次」操作（添加章 或 几何改动）。
    /// 栈顶动作指向的章已不存在（被其它途径删除）时，跳过并继续弹栈，直到命中有效动作。
    @discardableResult
    func undo() -> Bool {
        while let action = undoActions.popLast() {
            switch action {
            case .add(let id):
                guard fullStamps.contains(where: { $0.id == id }) else { continue }
                fullStamps.removeAll { $0.id == id }
                selectedFullStampIDs.remove(id)
                if primaryID == id { primaryID = remainingPrimary() }
                return true
            case .geometry(let id, let snap):
                guard let i = fullStamps.firstIndex(where: { $0.id == id }) else { continue }
                fullStamps[i].anchor = snap.anchor
                fullStamps[i].widthCm = snap.widthCm
                fullStamps[i].heightCm = snap.heightCm
                fullStamps[i].rotation = snap.rotation
                fullStamps[i].opacity = snap.opacity
                return true
            }
        }
        return false
    }

    /// 「添加」按钮：按当前模板选项新增一条骑缝章（锁定印章与位置）
    func addQifengStamp(sealID: UUID?) {
        guard pageCount > 0, let sealID else { return }
        qifengStamps.append(QifengInstance(id: UUID(),
                                           sealID: sealID,
                                           edge: edge,
                                           size: qifengSize,
                                           offset: qifengOffset,
                                           allPages: allPages,
                                           rangeStart: rangeStart,
                                           rangeEnd: rangeEnd))
    }

    func removeQifengStamp(_ id: UUID) {
        qifengStamps.removeAll { $0.id == id }
    }

    func removeAllQifengStamps() {
        qifengStamps = []
    }

    func removeQifengPage(_ pageIndex: Int, of id: UUID) {
        guard let i = qifengStamps.firstIndex(where: { $0.id == id }) else { return }
        qifengStamps[i].removedPages.insert(pageIndex)
    }

    func restoreQifengPage(_ pageIndex: Int, of id: UUID) {
        guard let i = qifengStamps.firstIndex(where: { $0.id == id }) else { return }
        qifengStamps[i].removedPages.remove(pageIndex)
    }

    /// 选中章变化时，套用该章固定的物理尺寸（cm）
    /// 1cm = 72 / 2.54 ≈ 28.3465 pt；骑缝章尺寸按当前文档页高换算为比例
    func applySealPhysicalSize(widthCm: Double?, heightCm: Double?, pageHeightPt: CGFloat?) {
        guard let wC = widthCm, let hC = heightCm else { return }
        fullWidthCm = wC
        fullHeightCm = hC
        if let ph = pageHeightPt, ph > 0 {
            qifengSize = Double(CGFloat(hC * 28.3465) / ph)
        }
    }

    /// 主选中章（最后点击 / 添加的章）。用于尺寸滑杆与缩放手柄的锚点。
    /// 普通点击 / 添加 = 仅它选中；⌘ 点击 = 在已有选择上累加 / 取消。
    var selectedFullStampID: UUID? { primaryID }

    var selectedInstance: FullStampInstance? {
        guard let pid = primaryID else { return nil }
        return fullStamps.first { $0.id == pid }
    }

    /// 主选中章在 fullStamps 中的下标（按添加顺序，0-based）。
    var selectedIndex: Int {
        guard let pid = primaryID, let i = fullStamps.firstIndex(where: { $0.id == pid }) else { return 0 }
        return i
    }

    /// 当前选中的章数量
    var selectedCount: Int { selectedFullStampIDs.count }

    // MARK: - 多选操作

    /// 普通点击 / 添加：仅选中这一枚（清空其余选中）
    func selectOnly(_ id: UUID) {
        selectedFullStampIDs = [id]
        primaryID = id
    }

    /// ⌘ 点击：在已有选择上累加；若已选中则取消选中（切换）。
    /// 取消的是主选中时，主选中顺延到其余选中章中最后添加的一枚。
    func toggleSelection(_ id: UUID) {
        if selectedFullStampIDs.contains(id) {
            selectedFullStampIDs.remove(id)
            if primaryID == id {
                primaryID = remainingPrimary()
            }
        } else {
            selectedFullStampIDs.insert(id)
            primaryID = id
        }
    }

    /// 取消全部选中（Esc）
    func clearSelection() {
        selectedFullStampIDs = []
        primaryID = nil
    }

    /// 在剩余选中章里挑「最后添加」的一枚作为主选中
    private func remainingPrimary() -> UUID? {
        selectedFullStampIDs.compactMap { fid in
            fullStamps.firstIndex(where: { $0.id == fid }).map { ($0, fid) }
        }.max(by: { $0.0 < $1.0 })?.1
    }

    /// 调整指定章的物理尺寸（cm），范围 1–20
    func setSize(widthCm: Double, heightCm: Double, of id: UUID) {
        guard let i = fullStamps.firstIndex(where: { $0.id == id }) else { return }
        fullStamps[i].widthCm = min(max(widthCm, 1), 20)
        fullStamps[i].heightCm = min(max(heightCm, 1), 20)
        fullWidthCm = fullStamps[i].widthCm
        fullHeightCm = fullStamps[i].heightCm
    }

    /// 「添加」按钮：按当前模板选项新增一枚章实例
    /// - Parameter sealID: 该章锁定的印章
    /// - Parameter pageIndex: 提供 时，新章仅覆盖该页并落在 anchor 处（点击落章）
    func addFullStamp(sealID: UUID?, pageIndex: Int? = nil, anchor: CGPoint? = nil) {
        guard pageCount > 0, let sealID else { return }
        var inst = FullStampInstance(id: UUID(),
                                     sealID: sealID,
                                     anchor: anchor ?? fullAnchor,
                                     widthCm: fullWidthCm,
                                     heightCm: fullHeightCm,
                                     rotation: fullRotation,
                                     opacity: fullOpacity,
                                     allPages: fullAllPages,
                                     rangeStart: fullRangeStart,
                                     rangeEnd: fullRangeEnd)
        if let p = pageIndex {
            inst.allPages = false
            inst.rangeStart = p + 1
            inst.rangeEnd = p + 1
        }
        fullStamps.append(inst)
        selectOnly(inst.id)
        undoActions.append(.add(inst.id))
    }

    func removeFullStamp(_ id: UUID) {
        fullStamps.removeAll { $0.id == id }
        undoActions.removeAll {
            if case .add(let aid) = $0 { return aid == id }
            if case .geometry(let gid, _) = $0 { return gid == id }
            return false
        }
        selectedFullStampIDs.remove(id)
        if primaryID == id {
            primaryID = remainingPrimary()
        }
    }

    /// 移除当前选中的所有章
    func removeSelectedFullStamps() {
        for id in selectedFullStampIDs {
            fullStamps.removeAll { $0.id == id }
            undoActions.removeAll {
                if case .add(let aid) = $0 { return aid == id }
                if case .geometry(let gid, _) = $0 { return gid == id }
                return false
            }
        }
        selectedFullStampIDs = []
        primaryID = nil
    }

    func removeAllFullStamps() {
        fullStamps = []
        selectedFullStampIDs = []
        primaryID = nil
        undoActions = []
    }

    func anchor(of id: UUID) -> CGPoint? {
        fullStamps.first { $0.id == id }?.anchor
    }

    func setAnchor(of id: UUID, to point: CGPoint) {
        guard let i = fullStamps.firstIndex(where: { $0.id == id }) else { return }
        fullStamps[i].anchor = point
    }

    func removePage(_ pageIndex: Int, of id: UUID) {
        guard let i = fullStamps.firstIndex(where: { $0.id == id }) else { return }
        fullStamps[i].removedPages.insert(pageIndex)
    }

    func restorePage(_ pageIndex: Int, of id: UUID) {
        guard let i = fullStamps.firstIndex(where: { $0.id == id }) else { return }
        fullStamps[i].removedPages.remove(pageIndex)
    }

    private func normRange(_ start: Int, _ end: Int) -> ClosedRange<Int> {
        let total = max(pageCount, 1)
        let s = min(max(start, 1), total)
        let e = min(max(end, s), total)
        return (s - 1)...(e - 1)
    }

    var qifengRange: ClosedRange<Int> { normRange(rangeStart, rangeEnd) }

    func qifengConfig(pageCount: Int) -> QifengConfig {
        var c = QifengConfig()
        c.edge = edge
        c.range = allPages ? (0...(max(pageCount - 1, 0))) : qifengRange
        c.sizeRatio = CGFloat(qifengSize)
        c.offset = CGFloat(qifengOffset)
        return c
    }
}
