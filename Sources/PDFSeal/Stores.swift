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
    @Published var selectedFullStampID: UUID?

    /// 每枚章的撤销栈（交互前快照）
    private var undoStacks: [UUID: [FullStampSnapshot]] = [:]

    private(set) var pageCount = 0

    /// 关闭文档后清空所有盖章状态
    func clearDocumentState() {
        pageCount = 0
        qifengStamps = []
        fullStamps = []
        selectedFullStampID = nil
        undoStacks = [:]
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
        selectedFullStampID = nil
        undoStacks = [:]
    }

    /// 交互（拖动/缩放/点击落位）开始前记录快照
    func pushUndo(_ id: UUID) {
        guard let inst = fullStamps.first(where: { $0.id == id }) else { return }
        var stack = undoStacks[id] ?? []
        stack.append(FullStampSnapshot(anchor: inst.anchor, widthCm: inst.widthCm,
                                       heightCm: inst.heightCm, rotation: inst.rotation,
                                       opacity: inst.opacity))
        if stack.count > 50 { stack.removeFirst() }
        undoStacks[id] = stack
    }

    /// ⌘Z / Ctrl+Z：回退到上一个快照
    @discardableResult
    func undo(_ id: UUID) -> Bool {
        guard var stack = undoStacks[id], let snap = stack.popLast(),
              let i = fullStamps.firstIndex(where: { $0.id == id }) else { return false }
        undoStacks[id] = stack
        fullStamps[i].anchor = snap.anchor
        fullStamps[i].widthCm = snap.widthCm
        fullStamps[i].heightCm = snap.heightCm
        fullStamps[i].rotation = snap.rotation
        fullStamps[i].opacity = snap.opacity
        return true
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

    var selectedInstance: FullStampInstance? {
        fullStamps.first { $0.id == selectedFullStampID } ?? fullStamps.last
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
        selectedFullStampID = inst.id
    }

    func removeFullStamp(_ id: UUID) {
        fullStamps.removeAll { $0.id == id }
        undoStacks[id] = nil
        if selectedFullStampID == id {
            selectedFullStampID = fullStamps.last?.id
        }
    }

    func removeAllFullStamps() {
        fullStamps = []
        selectedFullStampID = nil
        undoStacks = [:]
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
