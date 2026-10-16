import Foundation
import PDFKit
import AppKit
import CoreGraphics
import SealCore

// MARK: - 页面操作层（PDF 工具箱：页面管理 / 度量）

/// 操作范围：选中页 / 奇数页 / 偶数页 / 全部页
enum PageScope: Hashable {
    case selected, odd, even, all

    var label: String {
        switch self {
        case .selected: return L("选中页")
        case .odd: return L("奇数页")
        case .even: return L("偶数页")
        case .all: return L("全部页")
        }
    }
}

/// 页面管理列表行
struct PageItem: Identifiable {
    let id: UUID
    let index: Int
}

extension DocumentStore {
    /// 页操作后统一刷新派生状态（尺寸、行 ID、脏标记）
    func refreshAfterEdit() {
        guard let d = document, d.pageCount > 0 else { return }
        pageSizes = (0..<d.pageCount).map {
            guard let p = d.page(at: $0) else { return .zero }
            return PageBox.displayedSize(p)
        }
        pageIDs = (0..<d.pageCount).map { _ in UUID() }
        revision += 1
        hasPageEdits = true
        isDirty = true
    }

    /// 各范围对应的页下标（0-based）
    func indices(for scope: PageScope, selected: [Int]) -> [Int] {
        let count = pageCount
        switch scope {
        case .selected: return selected
        case .odd: return stride(from: 0, to: count, by: 2).map { $0 }
        case .even: return stride(from: 1, to: count, by: 2).map { $0 }
        case .all: return Array(0..<count)
        }
    }

    /// 旋转（左/右 90°）。不改页序，无需重映射章页码。
    func rotatePages(_ indices: [Int], clockwise: Bool) {
        guard let d = document else { return }
        for i in indices {
            guard let p = d.page(at: i) else { continue }
            let cur = Int(p.rotation) % 360
            p.rotation = ((clockwise ? cur + 90 : cur - 90) + 360) % 360
        }
        refreshAfterEdit()
    }

    /// 删除页。至少保留一页；返回旧→新下标映射（nil = 已删除），页序无变化时返回 nil。
    @discardableResult
    func deletePages(_ indices: Set<Int>) -> [Int?]? {
        guard let d = document, !indices.isEmpty, d.pageCount > indices.count else { return nil }
        var mapping = [Int?]()
        var next = 0
        for i in 0..<d.pageCount {
            if indices.contains(i) { mapping.append(nil) } else { mapping.append(next); next += 1 }
        }
        for i in indices.sorted(by: >) { d.removePage(at: i) }
        refreshAfterEdit()
        return mapping
    }

    /// 重排页序：newOrder[新位置] = 旧下标。返回旧→新映射。
    @discardableResult
    func reorderPages(newOrder: [Int]) -> [Int?]? {
        guard let d = document, newOrder.count == d.pageCount else { return nil }
        var pages: [PDFPage] = []
        var mapping = [Int?](repeating: nil, count: newOrder.count)
        for (pos, old) in newOrder.enumerated() {
            guard let p = d.page(at: old) else { return nil }
            pages.append(p)
            mapping[old] = pos
        }
        while d.pageCount > 0 { d.removePage(at: 0) }
        for p in pages { d.insert(p, at: d.pageCount) }
        refreshAfterEdit()
        return mapping
    }

    /// 从文件插入页面（插入到 index 位置起）。返回插入页数。
    @discardableResult
    func insertPages(from url: URL, at index: Int) -> Int {
        guard let d = document, let src = PDFDocument(url: url), src.pageCount > 0 else { return 0 }
        var k = 0
        for i in 0..<src.pageCount {
            guard let p = src.page(at: i)?.copy() as? PDFPage else { continue }
            d.insert(p, at: min(index + k, d.pageCount))
            k += 1
        }
        refreshAfterEdit()
        return k
    }

    /// 插入空白页（尺寸 = 参考页显示尺寸）
    @discardableResult
    func insertBlankPage(at index: Int, size: CGSize) -> Bool {
        guard let d = document else { return false }
        let p = PDFPage()
        p.setBounds(CGRect(x: 0, y: 0, width: size.width, height: size.height), for: .mediaBox)
        d.insert(p, at: min(max(index, 0), d.pageCount))
        refreshAfterEdit()
        return true
    }

    /// 复制页到剪贴板（PDF 数据，支持跨文档粘贴）
    func copyPages(_ indices: [Int]) {
        guard let d = document, !indices.isEmpty else { return }
        let bag = PDFDocument()
        var k = 0
        for i in indices {
            guard let p = d.page(at: i)?.copy() as? PDFPage else { continue }
            bag.insert(p, at: k); k += 1
        }
        guard k > 0, let data = bag.dataRepresentation() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .pdf)
    }

    /// 从剪贴板粘贴页（插入到 index 位置起）。返回插入页数。
    @discardableResult
    func pastePages(at index: Int) -> Int {
        guard let d = document,
              let data = NSPasteboard.general.data(forType: .pdf),
              let src = PDFDocument(data: data) else { return 0 }
        var k = 0
        for i in 0..<src.pageCount {
            guard let p = src.page(at: i)?.copy() as? PDFPage else { continue }
            d.insert(p, at: min(index + k, d.pageCount))
            k += 1
        }
        if k > 0 { refreshAfterEdit() }
        return k
    }

    /// 提取页另存为新 PDF
    func extractPages(_ indices: [Int], to url: URL) -> Bool {
        guard let d = document, !indices.isEmpty else { return false }
        let out = PDFDocument()
        var k = 0
        for i in indices {
            guard let p = d.page(at: i)?.copy() as? PDFPage else { continue }
            out.insert(p, at: k); k += 1
        }
        return out.write(to: url)
    }

    /// 度量：把指定页画幅改为新尺寸（pt），内容按九宫格锚点摆放（放大补白边/缩小裁切）。
    /// ax/ay ∈ 0...2：水平 左/中/右，垂直 上/中/下（以显示坐标为准）。
    func resizePages(_ indices: [Int], widthPt: CGFloat, heightPt: CGFloat, ax: Int, ay: Int) -> Bool {
        guard let d = document, !indices.isEmpty, widthPt > 5, heightPt > 5 else { return false }
        let mb = CGRect(x: 0, y: 0, width: widthPt, height: heightPt)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfbox-\(UUID().uuidString).pdf")
        var mbBox = mb
        guard let ctx = CGContext(tmp as CFURL, mediaBox: &mbBox, nil) else { return false }
        for i in indices.sorted() {
            guard let p = d.page(at: i) else { continue }
            let os = PageBox.displayedSize(p)
            let dx: CGFloat
            switch ax { case 0: dx = 0; case 2: dx = widthPt - os.width; default: dx = (widthPt - os.width) / 2 }
            let dy: CGFloat
            switch ay { case 0: dy = heightPt - os.height; case 2: dy = 0; default: dy = (heightPt - os.height) / 2 }
            ctx.beginPDFPage([kCGPDFContextMediaBox: mb] as CFDictionary)
            ctx.saveGState()
            ctx.translateBy(x: dx, y: dy)
            // PDFPage.draw 自动处理 /Rotate，绘制后内容占据 (0,0)-(显示宽, 显示高)
            p.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        guard let nd = PDFDocument(url: tmp) else {
            try? FileManager.default.removeItem(at: tmp); return false
        }
        var ok = true
        for (k, i) in indices.sorted().enumerated() {
            guard let np = nd.page(at: k) else { ok = false; continue }
            d.removePage(at: i)
            d.insert(np, at: i)
        }
        try? FileManager.default.removeItem(at: tmp)
        if ok { refreshAfterEdit() }
        return ok
    }
}

// MARK: - 纸型识别

enum PaperSize {
    /// 按毫米尺寸猜测常见纸型（宽高不分先后）
    static func guess(widthPt: CGFloat, heightPt: CGFloat) -> String? {
        let mm = { (pt: CGFloat) in Int((pt / 72 * 25.4).rounded()) }
        let (w, h) = (mm(widthPt), mm(heightPt))
        let pair = [min(w, h), max(w, h)]
        let table: [(Int, Int, String)] = [
            (210, 297, "A4"), (148, 210, "A5"), (297, 420, "A3"),
            (105, 148, "A6"), (176, 250, "B5"), (250, 353, "B4"),
            (216, 279, "Letter"), (216, 356, "Legal"),
        ]
        for (a, b, name) in table where pair[0] == a && pair[1] == b { return name }
        return nil
    }
}
