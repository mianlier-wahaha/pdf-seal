import SwiftUI
import PDFKit
import CoreGraphics
import SealCore

// MARK: - 文档

/// 后台写盘专用诊断：直接追加一行到 /tmp/mpdf_diag.log。
/// AnnotationPDFView.diag 的环形缓冲只在主线程安全，后台保存线程用本函数。
func saveDiag(_ s: String) {
    let line = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium) + " " + s + "\n"
    if let fh = FileHandle(forWritingAtPath: "/tmp/mpdf_diag.log") {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    }
}

@MainActor
final class DocumentStore: ObservableObject {
    /// 「隐藏」批注的标记（userName）：保存/另存为时据此把遮盖块压平进页面内容
    nonisolated static let redactMarker = "mPDF-redact"

    @Published var document: PDFDocument?
    @Published var url: URL?
    @Published var pageSizes: [CGSize] = []
    @Published var loadError: String?
    /// 当前文档是否有未保存的改动（盖章/水印/页面编辑后置 true；保存或打开/关闭文件后置 false）
    @Published var isDirty: Bool = false
    /// 是否有未落盘的「页面结构」改动（增删/排序/旋转/度量）——保存时需先写基础文档
    @Published var hasPageEdits: Bool = false
    /// 是否有未落盘的批注改动（编辑页高亮/矩形/直线/文字）——保存/另存为时需写文档
    @Published var hasAnnotationEdits: Bool = false
    /// 页面行标识（页面管理 List 的稳定行 id，页操作后整体重建）
    @Published var pageIDs: [UUID] = []
    /// 页操作版本号（缩略图缓存失效用）
    @Published var revision: Int = 0
    /// 跨界面跳页请求（页面管理双击某页 → 预览定位到该页），消费后置 nil
    @Published var pendingJumpPage: Int? = nil

    // MARK: 页面操作撤销/重做（快照式：PDFDocument 深拷贝 + 行 ID + 章页码状态）
    @Published private(set) var canUndoPageEdit = false
    @Published private(set) var canRedoPageEdit = false
    private var pageUndoStack: [PageEditSnapshot] = []
    private var pageRedoStack: [PageEditSnapshot] = []
    private let maxPageUndoDepth = 30

    /// 三路全局时间线（批注/章/页面）取最近者回退用
    var lastPageUndoTime: Date? { pageUndoStack.last?.time }
    var lastPageRedoTime: Date? { pageRedoStack.last?.time }

    private func takePageSnapshotDoc() -> PDFDocument? {
        guard let d = document else { return nil }
        let snap = PDFDocument()
        for i in 0..<d.pageCount {
            if let p = d.page(at: i) { snap.insert(p.copy() as! PDFPage, at: i) }
        }
        return snap
    }

    /// 每次页面结构改动前调用（删除/旋转/排序/插入/度量）
    func pushPageUndo(stampState: StampPageState) {
        guard let snapDoc = takePageSnapshotDoc() else { return }
        pageUndoStack.append(PageEditSnapshot(document: snapDoc, pageIDs: pageIDs,
                                              hasPageEdits: hasPageEdits, stampState: stampState,
                                              time: Date()))
        if pageUndoStack.count > maxPageUndoDepth { pageUndoStack.removeFirst() }
        pageRedoStack.removeAll()
        refreshPageUndoFlags()
        UndoCenter.shared.refresh()
    }

    func undoPageEdit(settings: StampSettings) {
        guard let snap = pageUndoStack.popLast() else { return }
        if let cur = takePageSnapshotDoc() {
            pageRedoStack.append(PageEditSnapshot(document: cur, pageIDs: pageIDs,
                                                  hasPageEdits: hasPageEdits,
                                                  stampState: settings.capturePageState(),
                                                  time: Date()))
        }
        restorePageEdit(snap, settings: settings)
        UndoCenter.shared.refresh()
    }

    func redoPageEdit(settings: StampSettings) {
        guard let snap = pageRedoStack.popLast() else { return }
        if let cur = takePageSnapshotDoc() {
            pageUndoStack.append(PageEditSnapshot(document: cur, pageIDs: pageIDs,
                                                  hasPageEdits: hasPageEdits,
                                                  stampState: settings.capturePageState(),
                                                  time: Date()))
        }
        restorePageEdit(snap, settings: settings)
        UndoCenter.shared.refresh()
    }

    private func restorePageEdit(_ snap: PageEditSnapshot, settings: StampSettings) {
        document = snap.document
        pageSizes = (0..<snap.document.pageCount).map {
            guard let p = snap.document.page(at: $0) else { return .zero }
            return PageBox.displayedSize(p)
        }
        pageIDs = snap.pageIDs
        hasPageEdits = snap.hasPageEdits
        isDirty = true
        revision += 1
        settings.restorePageState(snap.stampState)
        refreshPageUndoFlags()
    }

    func clearPageUndoHistory() {
        pageUndoStack.removeAll()
        pageRedoStack.removeAll()
        refreshPageUndoFlags()
        UndoCenter.shared.refresh()
    }

    private func refreshPageUndoFlags() {
        canUndoPageEdit = !pageUndoStack.isEmpty
        canRedoPageEdit = !pageRedoStack.isEmpty
    }

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
        pageIDs = (0..<d.pageCount).map { _ in UUID() }
        hasPageEdits = false
        isDirty = false
        clearPageUndoHistory()
    }

    /// 关闭当前文档
    func close() {
        document = nil
        url = nil
        pageSizes = []
        loadError = nil
        pageIDs = []
        hasPageEdits = false
        isDirty = false
        clearPageUndoHistory()
    }

    // MARK: 隐藏（redact）批注落盘压平

    /// 写盘：含「隐藏」批注的页面在落盘时压平——遮盖块烘焙进页面内容、注释层不再携带，
    /// 其余批注原样保留。内存中的文档不受影响（仍可撤销/继续编辑）。
    /// 可传 onProgress 驱动后台保存进度条。
    func writeFlattened(to url: URL, onProgress: ((Double) -> Void)? = nil) -> Bool {
        guard let d = document else { return false }
        // ⭐ 快照必须在调用（主）线程生成：PDFKit 非线程安全，活文档只允许主线程访问；
        //   后台写盘只操作快照副本。
        guard let data = d.dataRepresentation() else { return false }
        return Self.writeSnapshot(data, to: url, onProgress: onProgress)
    }

    /// 从内存快照写盘（快照由调用方在主线程生成；本函数可在后台线程执行）。
    /// 进度：0.05 快照读回 → 0.85 逐页压平 → 0.9 写盘前 → 1.0 完成。
    nonisolated static func writeSnapshot(_ data: Data, to url: URL, onProgress: ((Double) -> Void)? = nil) -> Bool {
        let t0 = CFAbsoluteTimeGetCurrent()
        onProgress?(0.02)
        guard let src = PDFDocument(data: data) else { return false }
        onProgress?(0.05)
        let hasRedact = (0..<src.pageCount).contains { i in
            src.page(at: i)?.annotations.contains { $0.userName == redactMarker } ?? false
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        defer { saveDiag(String(format: "SAVE writeFlattened total=%.0fms (readback+scan=%.0fms flat+write=%.0fms) pages=%d", (CFAbsoluteTimeGetCurrent() - t0) * 1000, (t1 - t0) * 1000, (CFAbsoluteTimeGetCurrent() - t1) * 1000, src.pageCount)) }
        if hasRedact, let (flat, keepers, sub) = Self.flattenRedactions(src, onProgress: { onProgress?($0) }) {
            // ⭐ keepers 必须活到写盘结束：页面挪入 flat 后，其内容流与保留批注的 /AP
            // 外观流仍引用来源文档的 CGPDFSource，来源文档先释放 → 写出扫流即野指针崩溃
            // （SIGSEGV at 0x14/0x1b，PDFSeal-2026-10-20 三份崩溃报告实证）。
            let t2 = CFAbsoluteTimeGetCurrent()
            onProgress?(0.9)
            let ok = flat.write(to: url)
            onProgress?(1.0)
            saveDiag(String(format: "SAVE   flatten sub: %@ | write=%.0fms ok=%d", sub, (CFAbsoluteTimeGetCurrent() - t2) * 1000, ok ? 1 : 0))
            _ = keepers   // 作用域兜底：写盘完成前不释放
            return ok
        }
        let t2 = CFAbsoluteTimeGetCurrent()
        onProgress?(0.9)
        let ok = src.write(to: url)   // 无隐藏批注或压平失败：快照原样写出兜底
        onProgress?(1.0)
        saveDiag(String(format: "SAVE   direct write=%.0fms ok=%d redact=%d", (CFAbsoluteTimeGetCurrent() - t2) * 1000, ok ? 1 : 0, hasRedact ? 1 : 0))
        return ok
    }

    /// 压平隐藏批注：src 为快照读回副本（序列化已由调用方完成），对含隐藏块的页面
    /// 用 CGContext 重画——只画页面内容 + 按批注颜色填遮盖矩形，其余批注重新挂回注释层。
    /// 无隐藏块的页面直接挪入目标文档（跳过重绘——只藏一两页的常规场景大提速）。
    /// 返回 (压平文档, 生命周期依赖, 计时分解)：页面/批注被挪入新文档后仍引用来源文档的
    /// CGPDFSource，调用方必须持有这些来源文档直到写盘完成。
    nonisolated private static func flattenRedactions(_ src: PDFDocument, onProgress: @escaping (Double) -> Void) -> (PDFDocument, [PDFDocument], String)? {
        let out = PDFDocument()
        var keepers: [PDFDocument] = [src]
        var any = false
        var flatPages = 0
        var drawMs: Double = 0
        var readbackMs: Double = 0
        let total = max(src.pageCount, 1)
        for i in 0..<src.pageCount {
            guard let page = src.page(at: i) else { continue }
            let redacts = page.annotations.filter { $0.userName == redactMarker }
            guard !redacts.isEmpty else {
                out.insert(page, at: i)   // 无隐藏块：直接挪页，跳过重绘
                continue
            }
            any = true
            let keep = page.annotations.filter { $0.userName != redactMarker }
            for a in page.annotations { page.removeAnnotation(a) }   // 只画页面内容
            var mediaBox = page.bounds(for: .mediaBox)
            let flatData = NSMutableData()
            guard let consumer = CGDataConsumer(data: flatData as CFMutableData),
                  let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, _: nil) else {
                out.insert(page, at: i); continue
            }
            let tC = CFAbsoluteTimeGetCurrent()
            ctx.beginPDFPage(nil)
            page.draw(with: .mediaBox, to: ctx)
            for r in redacts {
                ctx.setFillColor((r.color ?? .black).cgColor)
                ctx.fill(r.bounds)
            }
            ctx.endPDFPage()
            ctx.closePDF()
            let tD = CFAbsoluteTimeGetCurrent()
            drawMs += tD - tC
            flatPages += 1
            if let flatSrc = PDFDocument(data: flatData as Data), let flatPage = flatSrc.page(at: 0) {
                keepers.append(flatSrc)                       // flatPage 的内容流引用 flatSrc
                for a in keep { flatPage.addAnnotation(a) }   // 其余批注挂回注释层，仍可编辑
                out.insert(flatPage, at: i)
            } else {
                out.insert(page, at: i)
            }
            readbackMs += CFAbsoluteTimeGetCurrent() - tD
            onProgress(0.05 + 0.8 * Double(i + 1) / Double(total))
        }
        let sub = String(format: "redraw=%dpg/%.0fms pageReadback=%.0fms", flatPages, drawMs * 1000, readbackMs * 1000)
        return any ? (out, keepers, sub) : nil
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
    var firstPageLarger: Bool // 首页占比加大
    var firstPageRatio: Double// 首页占总章图比例
    var middleRatioEnabled: Bool // 是否单独控制内页占比
    var middleRatio: Double   // 中间页每页占总章图比例
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
// MARK: - 水印设置（文档级绘制层，与章的逐对象模型独立）

extension WatermarkConfig.Align {
    /// 对齐预设的本地化标签（水平：居左/居中/居右；垂直：居上/居中/居下）
    func label(horizontal: Bool) -> String {
        switch (horizontal, self) {
        case (true, .start): return "居左"
        case (true, .center): return "居中"
        case (true, .end): return "居右"
        case (false, .start): return "居上"
        case (false, .center): return "居中"
        case (false, .end): return "居下"
        }
    }
}

/// 水印可用的颜色预设（下标即 colorIndex）
let watermarkColors: [(Double, Double, Double)] = [
    (0.55, 0.55, 0.55),   // 灰
    (0.10, 0.10, 0.10),   // 黑
    (0.80, 0.15, 0.15),   // 红
    (0.15, 0.30, 0.70),   // 蓝
]

/// 水印字体预设：UI 标签 → 字体家族名（绘制时解析为 PostScript 名）
let watermarkFonts: [(String, String)] = [
    ("宋体-简", "Songti SC"),
    ("黑体", "PingFang SC"),
    ("楷体-简", "Kaiti SC"),
    ("仿宋", "STFangsong"),
]

struct WatermarkSettings: Equatable {
    var enabled = false
    var text = ""
    var fontFamily = "Songti SC"          // watermarkFonts 里的家族名
    var fontSize: Double = 48             // pt
    var colorIndex = 0                    // watermarkColors 下标
    var rotation: Double = 45             // 度
    var opacityPercent: Double = 8        // 1...100
    var mode: WatermarkConfig.Mode = .single
    var hAlign: WatermarkConfig.Align = .center
    var vAlign: WatermarkConfig.Align = .center
    var offsetXmm: Double = 0
    var offsetYmm: Double = 0
    var allPages = true
    var rangeStart = 1
    var rangeEnd = 1

    /// 是否处于可导出状态（开着且有非空文本）
    var isActive: Bool {
        enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 转为绘制配置；未启用或文本为空返回 nil。
    /// 字体家族名解析为 PostScript 名（解析失败回退苹方）。
    func config() -> WatermarkConfig? {
        guard isActive else { return nil }
        let psName = NSFontManager.shared.availableMembers(ofFontFamily: fontFamily)?.first?.first as? String
            ?? "PingFangSC-Regular"
        let idx = min(max(colorIndex, 0), watermarkColors.count - 1)
        let (r, g, b) = watermarkColors[idx]
        return WatermarkConfig(text: text,
                               fontPS: psName,
                               fontSize: CGFloat(fontSize),
                               red: r, green: g, blue: b,
                               rotation: CGFloat(rotation),
                               opacity: opacityPercent / 100,
                               mode: mode,
                               hAlign: hAlign, vAlign: vAlign,
                               offsetXmm: offsetXmm, offsetYmm: offsetYmm)
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
    @Published var qifengFirstPageLarger: Bool = false
    @Published var qifengFirstPageRatio: Double = 0.25
    @Published var qifengMiddleRatioEnabled: Bool = true
    @Published var qifengMiddleRatio: Double = 0.05

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
    // 水印（文档级设置，换文档时保留模板参数、仅重置页码范围）
    @Published var watermark = WatermarkSettings()
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

    // MARK: - 撤销：统一时间线（带时间戳，供全局撤销中心排序；支持重做）
    /// 撤销动作。⌘Z 弹栈顶：添加则移除该章，几何则还原快照。
    private enum StampUndoAction {
        case add(FullStampInstance)              // 撤销「添加」= 移除该章（存实例供重做）
        case geometry(UUID, FullStampSnapshot)   // 撤销「几何改动」= 还原快照
    }
    private enum StampRedoAction {
        case add(FullStampInstance)              // 重做「添加」= 重新加入该章
        case geometry(UUID, FullStampSnapshot)   // 重做「几何改动」= 套用改后快照
    }
    private struct StampUndoEntry { let action: StampUndoAction; let time: Date }
    private struct StampRedoEntry { let action: StampRedoAction; let time: Date }
    private var undoEntries: [StampUndoEntry] = []
    private var redoEntries: [StampRedoEntry] = []

    var canUndoStamp: Bool { !undoEntries.isEmpty }
    var canRedoStamp: Bool { !redoEntries.isEmpty }
    var lastUndoTime: Date? { undoEntries.last?.time }
    var lastRedoTime: Date? { redoEntries.last?.time }

    private func snapshot(_ inst: FullStampInstance) -> FullStampSnapshot {
        FullStampSnapshot(anchor: inst.anchor, widthCm: inst.widthCm,
                          heightCm: inst.heightCm, rotation: inst.rotation,
                          opacity: inst.opacity)
    }

    private(set) var pageCount = 0

    /// 关闭文档后清空所有盖章状态
    func clearDocumentState() {
        pageCount = 0
        qifengStamps = []
        fullStamps = []
        selectedFullStampIDs = []
        primaryID = nil
        undoEntries = []
        redoEntries = []
        UndoCenter.shared.refresh()
    }

    /// 页面管理操作后同步页数（不清空章实例，与 syncPageCount 不同）
    func setPageCount(_ n: Int) { pageCount = max(n, 0) }

    // MARK: 页面操作撤销用的章参数快照
    func capturePageState() -> StampPageState {
        StampPageState(qifengStamps: qifengStamps, fullStamps: fullStamps, watermark: watermark)
    }

    func restorePageState(_ st: StampPageState) {
        qifengStamps = st.qifengStamps
        fullStamps = st.fullStamps
        watermark = st.watermark
    }

    /// 页操作后的章页码范围联动收缩/顺延。
    /// oldToNew[旧下标] = 新下标（nil = 该页已删除）。旋转/度量等不换序的操作传 nil 直接跳过。
    func remapPages(_ oldToNew: [Int?]?) {
        guard let map = oldToNew, !map.isEmpty else { return }
        let total = map.count
        func mapBound(_ oneBased: Int, seekUp: Bool) -> Int? {
            let z = oneBased - 1
            guard (0..<total).contains(z) else { return nil }
            if let n = map[z] { return n + 1 }
            if seekUp {
                if let n = (z..<total).compactMap({ map[$0] }).first { return n + 1 }
            } else {
                if let n = (0...z).compactMap({ map[$0] }).last { return n + 1 }
            }
            return nil
        }
        func remapRange(_ all: Bool, _ s: inout Int, _ e: inout Int) {
            guard !all else { return }
            if let ns = mapBound(s, seekUp: false) { s = ns }
            if let ne = mapBound(e, seekUp: true) { e = ne }
            if s > e { e = s }
        }
        for i in qifengStamps.indices {
            var s = qifengStamps[i].rangeStart, e = qifengStamps[i].rangeEnd
            remapRange(qifengStamps[i].allPages, &s, &e)
            qifengStamps[i].rangeStart = s
            qifengStamps[i].rangeEnd = e
            qifengStamps[i].removedPages = Set(qifengStamps[i].removedPages.compactMap { map[$0] })
        }
        for i in fullStamps.indices {
            var s = fullStamps[i].rangeStart, e = fullStamps[i].rangeEnd
            remapRange(fullStamps[i].allPages, &s, &e)
            fullStamps[i].rangeStart = s
            fullStamps[i].rangeEnd = e
            fullStamps[i].removedPages = Set(fullStamps[i].removedPages.compactMap { map[$0] })
        }
        var ws = watermark.rangeStart, we = watermark.rangeEnd
        remapRange(watermark.allPages, &ws, &we)
        watermark.rangeStart = ws
        watermark.rangeEnd = we
    }

    func syncPageCount(_ count: Int) {
        guard count > 0 else { return }
        pageCount = count
        rangeStart = 1
        rangeEnd = count
        fullRangeStart = count
        fullRangeEnd = count
        watermark.rangeStart = 1
        watermark.rangeEnd = count
        qifengStamps = []
        fullStamps = []
        selectedFullStampIDs = []
        primaryID = nil
        undoEntries = []
        redoEntries = []
    }

    /// 交互（拖动/缩放/点击落位/尺寸滑杆）开始前记录「改动前」快照，入统一时间线
    func pushUndo(_ id: UUID) {
        guard let inst = fullStamps.first(where: { $0.id == id }) else { return }
        undoEntries.append(StampUndoEntry(action: .geometry(id, snapshot(inst)), time: Date()))
        if undoEntries.count > 200 { undoEntries.removeFirst() }
        redoEntries.removeAll()   // 新动作清空重做线
        UndoCenter.shared.refresh()
    }

    /// 撤销最近一次章操作（添加/几何）。弹栈顶，指向的章已不存在时跳过继续。
    @discardableResult
    func undo() -> Bool {
        while let e = undoEntries.popLast() {
            switch e.action {
            case .add(let inst):
                guard fullStamps.contains(where: { $0.id == inst.id }) else { continue }
                redoEntries.append(StampRedoEntry(action: .add(inst), time: Date()))
                fullStamps.removeAll { $0.id == inst.id }
                selectedFullStampIDs.remove(inst.id)
                if primaryID == inst.id { primaryID = remainingPrimary() }
                UndoCenter.shared.refresh()
                return true
            case .geometry(let id, let snap):
                guard let i = fullStamps.firstIndex(where: { $0.id == id }) else { continue }
                redoEntries.append(StampRedoEntry(action: .geometry(id, snapshot(fullStamps[i])), time: Date()))
                fullStamps[i].anchor = snap.anchor
                fullStamps[i].widthCm = snap.widthCm
                fullStamps[i].heightCm = snap.heightCm
                fullStamps[i].rotation = snap.rotation
                fullStamps[i].opacity = snap.opacity
                UndoCenter.shared.refresh()
                return true
            }
        }
        return false
    }

    /// 重做最近一次被撤销的章操作
    @discardableResult
    func redo() -> Bool {
        while let e = redoEntries.popLast() {
            switch e.action {
            case .add(let inst):
                guard !fullStamps.contains(where: { $0.id == inst.id }) else { continue }
                fullStamps.append(inst)
                undoEntries.append(StampUndoEntry(action: .add(inst), time: Date()))
                UndoCenter.shared.refresh()
                return true
            case .geometry(let id, let snap):
                guard let i = fullStamps.firstIndex(where: { $0.id == id }) else { continue }
                undoEntries.append(StampUndoEntry(action: .geometry(id, snapshot(fullStamps[i])), time: Date()))
                fullStamps[i].anchor = snap.anchor
                fullStamps[i].widthCm = snap.widthCm
                fullStamps[i].heightCm = snap.heightCm
                fullStamps[i].rotation = snap.rotation
                fullStamps[i].opacity = snap.opacity
                UndoCenter.shared.refresh()
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
                                           firstPageLarger: qifengFirstPageLarger,
                                           firstPageRatio: qifengFirstPageRatio,
                                           middleRatioEnabled: qifengMiddleRatioEnabled,
                                           middleRatio: qifengMiddleRatio,
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

    /// 调整指定章的旋转角度（按 180° 取模循环，负角折回正区间）
    func setRotation(_ degrees: Double, of id: UUID) {
        guard let i = fullStamps.firstIndex(where: { $0.id == id }) else { return }
        var r = degrees.truncatingRemainder(dividingBy: 180)
        if r < 0 { r += 180 }
        fullStamps[i].rotation = r
        fullRotation = r   // 模板值跟随，下一枚同角度
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
        undoEntries.append(StampUndoEntry(action: .add(inst), time: Date()))
        redoEntries.removeAll()   // 新动作清空重做线
        UndoCenter.shared.refresh()
    }

    func removeFullStamp(_ id: UUID) {
        fullStamps.removeAll { $0.id == id }
        undoEntries.removeAll {
            if case .add(let inst) = $0.action { return inst.id == id }
            if case .geometry(let gid, _) = $0.action { return gid == id }
            return false
        }
        selectedFullStampIDs.remove(id)
        if primaryID == id {
            primaryID = remainingPrimary()
        }
        UndoCenter.shared.refresh()
    }

    /// 移除当前选中的所有章
    func removeSelectedFullStamps() {
        for id in selectedFullStampIDs {
            fullStamps.removeAll { $0.id == id }
            undoEntries.removeAll {
                if case .add(let inst) = $0.action { return inst.id == id }
                if case .geometry(let gid, _) = $0.action { return gid == id }
                return false
            }
        }
        selectedFullStampIDs = []
        primaryID = nil
        UndoCenter.shared.refresh()
    }

    func removeAllFullStamps() {
        fullStamps = []
        selectedFullStampIDs = []
        primaryID = nil
        undoEntries = []
        redoEntries = []
        UndoCenter.shared.refresh()
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
        c.firstPageLarger = qifengFirstPageLarger
        c.firstPageRatio = CGFloat(qifengFirstPageRatio)
        c.middleRatioEnabled = qifengMiddleRatioEnabled
        c.middleRatio = CGFloat(qifengMiddleRatio)
        return c
    }
}


// MARK: - 页面操作撤销快照

/// 页面操作撤销快照：文档深拷贝 + 行 ID + 章页码状态 + 时间戳（全局时间线排序用）
struct PageEditSnapshot {
    let document: PDFDocument
    let pageIDs: [UUID]
    let hasPageEdits: Bool
    let stampState: StampPageState
    let time: Date
}

/// 章参数状态快照（页操作会联动章页码范围/removedPages）
struct StampPageState {
    var qifengStamps: [QifengInstance]
    var fullStamps: [FullStampInstance]
    var watermark: WatermarkSettings
}

// MARK: - 全局撤销/重做中心（批注 / 章 / 页面操作 三路时间线，按时间戳取最近者回退）

@MainActor
final class UndoCenter: ObservableObject {
    static let shared = UndoCenter()
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// 活动会话引用（多标签切换时由 ContentView 重新绑定）
    private weak var doc: DocumentStore?
    private weak var stamps: StampSettings?

    func bind(doc: DocumentStore, stamps: StampSettings) {
        self.doc = doc
        self.stamps = stamps
        refresh()
    }

    func refresh() {
        guard let doc, let st = stamps, let d = doc.document else {
            setFlags(false, false)
            return
        }
        let u = AnnotationUndoStack.shared.hasEntries(document: d)
            || st.canUndoStamp || doc.canUndoPageEdit
        let r = AnnotationUndoStack.shared.hasRedoEntries(document: d)
            || st.canRedoStamp || doc.canRedoPageEdit
        setFlags(u, r)
    }

    private func setFlags(_ u: Bool, _ r: Bool) {
        if u != canUndo { canUndo = u }
        if r != canRedo { canRedo = r }
    }

    /// 全局撤销：批注/章/页面三路时间线按时间戳取最近的一条回退
    @discardableResult
    func undo(doc ctxDoc: DocumentStore? = nil, stamps ctxStamps: StampSettings? = nil) -> Bool {
        let doc = ctxDoc ?? self.doc
        let st = ctxStamps ?? self.stamps
        guard let doc, let st = st, let d = doc.document else { return false }
        let aT = AnnotationUndoStack.shared.lastUndoTime(document: d)
        let sT = st.lastUndoTime
        let pT = doc.lastPageUndoTime
        if let t = aT, t >= (sT ?? .distantPast), t >= (pT ?? .distantPast) {
            if runAnnotationUndo(doc: doc, document: d) { return true }
        }
        if let t = sT, t >= (pT ?? .distantPast) {
            if st.undo() { doc.isDirty = true; refresh(); return true }
        }
        if doc.canUndoPageEdit {
            doc.undoPageEdit(settings: st)
            refresh()
            return true
        }
        // 优先级路径落空时按可用性兜底
        if aT != nil, runAnnotationUndo(doc: doc, document: d) { return true }
        if st.canUndoStamp, st.undo() { doc.isDirty = true; refresh(); return true }
        refresh()
        return false
    }

    /// 全局重做：批注/页面/章三路时间线按时间戳取最近的一条重放
    @discardableResult
    func redo(doc ctxDoc: DocumentStore? = nil, stamps ctxStamps: StampSettings? = nil) -> Bool {
        let doc = ctxDoc ?? self.doc
        let st = ctxStamps ?? self.stamps
        guard let doc, let st = st, let d = doc.document else { return false }
        let aT = AnnotationUndoStack.shared.lastRedoTime(document: d)
        let sT = st.lastRedoTime
        let pT = doc.lastPageRedoTime
        if let t = aT, t >= (sT ?? .distantPast), t >= (pT ?? .distantPast) {
            if runAnnotationRedo(doc: doc, document: d) { return true }
        }
        if let t = sT, t >= (pT ?? .distantPast) {
            if st.redo() { doc.isDirty = true; refresh(); return true }
        }
        if doc.canRedoPageEdit {
            doc.redoPageEdit(settings: st)
            refresh()
            return true
        }
        if aT != nil, runAnnotationRedo(doc: doc, document: d) { return true }
        if st.canRedoStamp, st.redo() { doc.isDirty = true; refresh(); return true }
        refresh()
        return false
    }

    /// 撤销全部动作（沿全局时间线逐条回退，直到无可撤销）
    func undoAll(doc: DocumentStore? = nil, stamps: StampSettings? = nil) {
        var guardCount = 0
        while undo(doc: doc, stamps: stamps), guardCount < 2000 { guardCount += 1 }
    }

    /// 文本编辑回放（撤销/重做共用）：先设文字再套几何快照，
    /// bounds 用「微差→真值」两段赋值强制 PDFKit 失效重绘（等值赋值不触发重绘的已知坑）
    static func applyTextSnapshot(_ anno: PDFAnnotation, geom: AnnotationGeomSnapshot, text: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        anno.contents = text
        geom.apply(to: anno)
        let b = geom.bounds
        anno.bounds = b.insetBy(dx: -0.01, dy: -0.01)
        anno.bounds = b
        CATransaction.commit()
    }

    private func runAnnotationUndo(doc: DocumentStore, document: PDFDocument) -> Bool {
        guard let e = AnnotationUndoStack.shared.pop(document: document) else { return false }
        if let page = document.page(at: e.pageIndex) {
            switch e.action {
            case .added(let anno): page.removeAnnotation(anno)
            case .removed(let anno): page.addAnnotation(anno)
            case .replaced(let original, let pieces):
                for p in pieces { page.removeAnnotation(p) }
                page.addAnnotation(original)
            case .addedBatch(let annos):
                for a in annos { page.removeAnnotation(a) }
            case .addedCrossPage(let pairs):
                for (i, a) in pairs { document.page(at: i)?.removeAnnotation(a) }
            case .geometry(let anno, let before, _):
                before.apply(to: anno)
            case .textEdited(let anno, let beforeGeom, let beforeText, _, _):
                UndoCenter.applyTextSnapshot(anno, geom: beforeGeom, text: beforeText)
            }
        }
        doc.isDirty = true
        doc.hasAnnotationEdits = true
        refresh()
        return true
    }

    private func runAnnotationRedo(doc: DocumentStore, document: PDFDocument) -> Bool {
        guard let e = AnnotationUndoStack.shared.popRedo(document: document) else { return false }
        if let page = document.page(at: e.pageIndex) {
            switch e.action {
            case .added(let anno): page.addAnnotation(anno)
            case .removed(let anno): page.removeAnnotation(anno)
            case .replaced(let original, let pieces):
                page.removeAnnotation(original)
                for p in pieces { page.addAnnotation(p) }
            case .addedBatch(let annos):
                for a in annos { page.addAnnotation(a) }
            case .addedCrossPage(let pairs):
                for (i, a) in pairs { document.page(at: i)?.addAnnotation(a) }
            case .geometry(let anno, _, let after):
                after.apply(to: anno)
            case .textEdited(let anno, _, _, let afterGeom, let afterText):
                UndoCenter.applyTextSnapshot(anno, geom: afterGeom, text: afterText)
            }
        }
        doc.isDirty = true
        doc.hasAnnotationEdits = true
        refresh()
        return true
    }
}
