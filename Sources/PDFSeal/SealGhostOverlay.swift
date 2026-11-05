import AppKit
import PDFKit
import SealCore

// MARK: - 印章 placement 公共构建（保存/导出/打印/编辑幽灵层共用同一份算法）

enum StampPlanner {

    /// 骑缝章 + 正文章 → 贴片列表与章图。
    /// 空章图时 throw（保存路径需要区分「没章」与「章图缺失」），幽灵层用 try? 兜底为空层。
    @MainActor
    static func build(settings: StampSettings, seals: SealStore,
                      pageSizes: [CGSize], pageCount: Int) throws -> ([StampPlacement], [Int: CGImage]) {
        var pls: [StampPlacement] = []
        var sealImages: [Int: CGImage] = [:]
        var key = 0

        // 骑缝章：每条实例使用各自锁定的印章与位置
        for q in settings.qifengStamps {
            guard let qCG = seals.cgImage(for: q.sealID) else { continue }
            var c = QifengConfig()
            c.edge = q.edge
            c.range = q.effectiveRange(pageCount: pageCount)
            c.sizeRatio = CGFloat(q.size)
            c.offset = CGFloat(q.offset)
            c.firstPageLarger = q.firstPageLarger
            c.firstPageRatio = CGFloat(q.firstPageRatio)
            c.middleRatioEnabled = q.middleRatioEnabled
            c.middleRatio = CGFloat(q.middleRatio)
            let qAspect = seals.aspect(for: q.sealID)
            for var pl in StampGeometry.qifeng(config: c,
                                               pageSizes: pageSizes, sealAspect: qAspect,
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
            let pageH = pageSizes[c.range.lowerBound].height
            c.sizeRatio = CGFloat(inst.heightCm * 28.3465 / pageH)
            c.rotation = CGFloat(inst.rotation)
            c.range = inst.effectiveRange(pageCount: pageCount)
            for var pl in StampGeometry.full(config: c,
                                             pageSizes: pageSizes, sealAspect: a,
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

// MARK: - 编辑视图印章幽灵层
// 盖章界面的章是覆盖层数据（导出/打印时压平），编辑 PDF 界面用的 PDFKit 看不到它。
// 本层把同一份 placement 映射到 PDFKit 视图坐标只读重画：随滚动/缩放/翻页刷新，
// 绘制语义与 PDFExporter.drawPlacement 完全一致（同 crop、同旋转方向、同透明度），
// 不挡任何鼠标交互（hitTest 返回 nil）。

final class SealGhostOverlay: NSView {
    weak var host: PDFView?
    private var placements: [StampPlacement] = []
    private var sealImages: [Int: CGImage] = [:]
    private var observers: [NSObjectProtocol] = []

    func attach(to pdf: PDFView) {
        host = pdf
        autoresizingMask = [.width, .height]
        // 滚动/缩放/翻页 → 重算坐标（PDFView 自身 bounds 不随内部滚动变化）
        observers.append(NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: pdf, queue: .main
        ) { [weak self] _ in self?.needsDisplay = true })
        if let sv = findScrollView(pdf) {
            sv.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: sv.contentView, queue: .main
            ) { [weak self] _ in self?.needsDisplay = true })
        }
        pdf.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: pdf, queue: .main
        ) { [weak self] _ in self?.needsDisplay = true })
    }

    func sync(placements: [StampPlacement], images: [Int: CGImage]) {
        self.placements = placements
        self.sealImages = images
        needsDisplay = true
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// 只做显示，绝不拦截编辑界面的点击/拖拽
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdf = host, let document = pdf.document, !placements.isEmpty,
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        for pl in placements {
            guard pl.pageIndex < document.pageCount,
                  let page = document.page(at: pl.pageIndex),
                  let img = sealImages[pl.sealKey] else { continue }
            let r = pdf.convert(pl.destRect, from: page)
            guard r.intersects(dirtyRect) else { continue }
            // 与 PDFExporter.drawPlacement 相同的取样与变换（source 归一化左上）
            let iw = CGFloat(img.width), ih = CGFloat(img.height)
            let crop = CGRect(x: pl.source.minX * iw, y: pl.source.minY * ih,
                              width: pl.source.width * iw, height: pl.source.height * ih)
            guard let piece = img.cropping(to: crop) else { continue }
            ctx.saveGState()
            ctx.setAlpha(pl.opacity)
            if pl.rotation != 0 {
                ctx.translateBy(x: r.midX, y: r.midY)
                ctx.rotate(by: -pl.rotation * .pi / 180)
                ctx.draw(piece, in: CGRect(x: -r.width / 2, y: -r.height / 2,
                                           width: r.width, height: r.height))
            } else {
                ctx.draw(piece, in: r)
            }
            ctx.restoreGState()
        }
    }

    /// PDFView 的滚动发生在其内部 NSScrollView（私有层级），递归找到才能挂滚动通知
    private func findScrollView(_ root: NSView) -> NSScrollView? {
        if let sv = root as? NSScrollView { return sv }
        for sub in root.subviews {
            if let sv = findScrollView(sub) { return sv }
        }
        return nil
    }
}

// MARK: - 页面管理缩略图章合成
// 缩略图由 ThumbStore 渲染 PDF 页面所得，看不到覆盖层的章。
// 把该页的 placement 按 destRect（pt，左下原点）等比映射到位图像素（同为左下原点的 y-up
// 空间，仅缩放无翻转），取样/旋转/透明度与 PDFExporter.drawPlacement 完全一致。

enum StampThumbComposer {

    /// 在基础缩略图上叠加该页所有章贴片，返回新图（不改动 base）
    static func compose(base: NSImage, pageIndex: Int,
                        placements: [StampPlacement], images: [Int: CGImage],
                        pageSize: CGSize) -> NSImage? {
        let pagePlacements = placements.filter { $0.pageIndex == pageIndex }
        guard !pagePlacements.isEmpty, pageSize.width > 0, pageSize.height > 0,
              let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        let sx = CGFloat(w) / pageSize.width
        let sy = CGFloat(h) / pageSize.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        for pl in pagePlacements {
            guard let img = images[pl.sealKey] else { continue }
            let iw = CGFloat(img.width), ih = CGFloat(img.height)
            let crop = CGRect(x: pl.source.minX * iw, y: pl.source.minY * ih,
                              width: pl.source.width * iw, height: pl.source.height * ih)
            guard let piece = img.cropping(to: crop) else { continue }
            let r = CGRect(x: pl.destRect.minX * sx, y: pl.destRect.minY * sy,
                           width: pl.destRect.width * sx, height: pl.destRect.height * sy)
            ctx.saveGState()
            ctx.setAlpha(pl.opacity)
            if pl.rotation != 0 {
                ctx.translateBy(x: r.midX, y: r.midY)
                ctx.rotate(by: -pl.rotation * .pi / 180)
                ctx.draw(piece, in: CGRect(x: -r.width / 2, y: -r.height / 2,
                                           width: r.width, height: r.height))
            } else {
                ctx.draw(piece, in: r)
            }
            ctx.restoreGState()
        }
        guard let outCG = ctx.makeImage() else { return nil }
        return NSImage(cgImage: outCG, size: base.size)
    }
}

/// 页面管理缩略图的章数据与合成结果缓存（引用类型：body 求值期间同步读写，
/// 不触发 SwiftUI 状态更新；键 = 文档身份 + 页面版本 + 章参数版本）。
@MainActor
final class StampArtCache {
    private var layerDocID: ObjectIdentifier?
    private var layerRev = -1
    private var layerStampRev = -1
    private var layer: (placements: [StampPlacement], images: [Int: CGImage])?
    private var map: [Int: (base: ObjectIdentifier, rev: Int, img: NSImage)] = [:]

    /// 取该文档当前章贴片（按 docRev/stampRev 记忆化；无章返回 nil）
    func stampLayer(doc: PDFDocument, docRev: Int, stampRev: Int,
                    settings: StampSettings, seals: SealStore,
                    pageSizes: [CGSize], pageCount: Int) -> (placements: [StampPlacement], images: [Int: CGImage])? {
        if layerDocID == ObjectIdentifier(doc), layerRev == docRev, layerStampRev == stampRev, let l = layer {
            return l
        }
        let l = try? StampPlanner.build(settings: settings, seals: seals,
                                        pageSizes: pageSizes, pageCount: pageCount)
        layerDocID = ObjectIdentifier(doc)
        layerRev = docRev
        layerStampRev = stampRev
        layer = l
        if l == nil { map.removeAll() }
        return l
    }

    /// 某页合成结果：基础图与章版本都没变就直接复用
    func composited(page: Int, base: NSImage, stampRev: Int, make: () -> NSImage?) -> NSImage {
        if let e = map[page], e.base == ObjectIdentifier(base), e.rev == stampRev { return e.img }
        let img = make() ?? base
        map[page] = (ObjectIdentifier(base), stampRev, img)
        return img
    }
}
