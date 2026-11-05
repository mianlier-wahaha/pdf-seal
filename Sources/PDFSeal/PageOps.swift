import Foundation
import PDFKit
import AppKit
import CoreGraphics
import SwiftUI
import Combine
import Quartz
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
        insertPages(from: url, sourcePages: nil, at: index)
    }

    /// 从文件插入指定源页（sourcePages 为 0-based 源页下标，nil = 全部页）。
    /// 返回插入页数。
    @discardableResult
    func insertPages(from url: URL, sourcePages: [Int]?, at index: Int) -> Int {
        guard let d = document, let src = PDFDocument(url: url), src.pageCount > 0 else { return 0 }
        let order = sourcePages ?? Array(0..<src.pageCount)
        var k = 0
        for i in order where src.page(at: i) != nil {
            guard let p = src.page(at: i)!.copy() as? PDFPage else { continue }
            d.insert(p, at: min(index + k, d.pageCount))
            k += 1
        }
        if k > 0 { refreshAfterEdit() }
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
    /// 优先取 PDF 数据（页面管理「复制」产生）；否则尝试把剪贴板图片转成单页插入。
    @discardableResult
    func pastePages(at index: Int) -> Int {
        guard let d = document else { return 0 }
        var k = 0
        if let data = NSPasteboard.general.data(forType: .pdf),
           let src = PDFDocument(data: data) {
            for i in 0..<src.pageCount {
                guard let p = src.page(at: i)?.copy() as? PDFPage else { continue }
                d.insert(p, at: min(index + k, d.pageCount))
                k += 1
            }
        } else if let img = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage {
            guard let p = PDFPage(image: img) else { return 0 }
            d.insert(p, at: min(max(index, 0), d.pageCount))
            k = 1
        }
        if k > 0 { refreshAfterEdit() }
        return k
    }

    /// 剪贴板预览：优先 PDF 首页缩略图，其次图片。nil = 剪贴板没有可插入内容。
    func clipboardPreview(width: CGFloat = 200) -> NSImage? {
        if let data = NSPasteboard.general.data(forType: .pdf),
           let src = PDFDocument(data: data), src.pageCount > 0,
           let p = src.page(at: 0) {
            let size = PageBox.displayedSize(p)
            let scale = width / max(size.width, 1)
            return p.thumbnail(of: CGSize(width: width, height: max(size.height * scale, 40)), for: .mediaBox)
        }
        if let img = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage {
            return img
        }
        return nil
    }

    /// 剪贴板中可插入的页数（PDF = 页数；图片 = 1）
    var clipboardPageCount: Int {
        if let data = NSPasteboard.general.data(forType: .pdf),
           let src = PDFDocument(data: data) { return src.pageCount }
        return NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first is NSImage ? 1 : 0
    }

    /// 全部页倒序重排。返回旧→新映射。
    @discardableResult
    func reversePages() -> [Int?]? {
        guard let d = document, d.pageCount > 1 else { return nil }
        let order = Array((0..<d.pageCount).reversed())
        return reorderPages(newOrder: order)
    }

    // MARK: 交叉插入（正反扫描件拼合场景）

    enum InterleaveMode {
        case oddPositions    // 新页占据结果的奇数位：新1 原1 新2 原2 新3 原3 …
        case evenPositions   // 新页占据结果的偶数位：原1 新1 原2 新2 原3 新3 …
    }

    /// 交叉插入：把 source.pdf 的页按模式交错插入当前文档。
    /// 奇数页插入 = 新 PDF 第 i 页落到结果的第 2i-1 位；偶数页插入 = 落到第 2i 位。
    /// sourceReversed / targetReversed 控制各自取页顺序（正反扫描拼合）。
    /// 返回（插入页数, 旧目标页→新位置映射）。
    func interleaveInsert(from url: URL, sourceReversed: Bool, targetReversed: Bool,
                          mode: InterleaveMode) -> (inserted: Int, mapping: [Int?])? {
        guard let d = document, d.pageCount > 0,
              let src = PDFDocument(url: url), src.pageCount > 0 else { return nil }
        var targetOrder = Array(0..<d.pageCount)
        if targetReversed { targetOrder.reverse() }
        var sourceOrder = Array(0..<src.pageCount)
        if sourceReversed { sourceOrder.reverse() }

        // 组装最终页序列（PDFPage 均为拷贝，避免同页双引用）
        var finalPages: [PDFPage] = []
        var newIndexOfTarget = [Int?](repeating: nil, count: d.pageCount)
        var si = 0
        func takeNew() -> PDFPage? {
            guard si < sourceOrder.count,
                  let sp = src.page(at: sourceOrder[si])?.copy() as? PDFPage else { return nil }
            si += 1
            return sp
        }
        for ti in targetOrder {
            if mode == .oddPositions, let sp = takeNew() { finalPages.append(sp) }
            guard let tp = d.page(at: ti)?.copy() as? PDFPage else { continue }
            finalPages.append(tp)
            newIndexOfTarget[ti] = finalPages.count - 1
            if mode == .evenPositions, let sp = takeNew() { finalPages.append(sp) }
        }
        while si < sourceOrder.count {   // 目标耗尽后剩余源页追加末尾
            if let sp = src.page(at: sourceOrder[si])?.copy() as? PDFPage { finalPages.append(sp) }
            si += 1
        }
        let inserted = finalPages.count - d.pageCount
        guard inserted > 0 else { return nil }

        while d.pageCount > 0 { d.removePage(at: 0) }
        for p in finalPages { d.insert(p, at: d.pageCount) }
        refreshAfterEdit()
        return (inserted, newIndexOfTarget)
    }

    // MARK: 拆分文档

    /// 按页数拆分：每 n 页存为一个新 PDF，写入 directory（文件名 base-01.pdf …）。
    /// 返回成功写出的文件列表。
    func splitDocument(every n: Int, to directory: URL, baseName: String) -> [URL] {
        guard let d = document, d.pageCount > 0, n >= 1 else { return [] }
        let totalParts = (d.pageCount + n - 1) / n
        let digits = max(String(totalParts).count, 2)
        var files: [URL] = []
        var start = 0
        var idx = 1
        while start < d.pageCount {
            let end = min(start + n, d.pageCount)
            if let url = writePages(Array(start..<end), to: directory, baseName: baseName,
                                    index: idx, digits: digits) { files.append(url) }
            start = end
            idx += 1
        }
        return files
    }

    /// 按大小拆分：每份不超过 maxBytes。
    /// sizes = 各页归一化字节数（调用方在后台估算好）。两步走：
    /// ① 按估算贪心装箱定初分；② 逐份写盘实测，超限则末页顺延到下一份重写——
    /// 保证每份实际大小不超上限（单页本身超限除外）。
    func splitDocument(byMaxBytes maxBytes: Int, sizes: [Int],
                       to directory: URL, baseName: String) -> [URL] {
        guard let d = document, d.pageCount > 0, maxBytes > 0,
              sizes.count == d.pageCount else { return [] }
        var chunks: [[Int]] = []
        var cur: [Int] = []
        var acc = 0
        for (i, s) in sizes.enumerated() {
            if !cur.isEmpty && acc + s > maxBytes { chunks.append(cur); cur = []; acc = 0 }
            cur.append(i); acc += s
        }
        if !cur.isEmpty { chunks.append(cur) }

        let digits = max(String(chunks.count + 1).count, 2)
        var files: [URL] = []
        var carry: [Int] = []
        var idx = 1
        for ch in chunks {
            var pages = carry + ch
            carry = []
            while !pages.isEmpty {
                guard let url = writePages(pages, to: directory, baseName: baseName,
                                           index: idx, digits: digits) else { return files }
                let sz = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                if sz <= maxBytes || pages.count == 1 {
                    files.append(url); idx += 1; break
                }
                carry.insert(pages.removeLast(), at: 0)   // 超限：末页顺延，重写本份
                try? FileManager.default.removeItem(at: url)
            }
        }
        if !carry.isEmpty, let url = writePages(carry, to: directory, baseName: baseName,
                                                index: idx, digits: digits) { files.append(url) }
        return files
    }

    /// 各页单独序列化后的字节数（估算用）。
    /// 每页新建单页 PDFDocument 再 dataRepresentation，代价高——请在后台线程调用。
    func pageByteSizes() -> [Int] {
        guard let d = document else { return [] }
        return (0..<d.pageCount).map { i in
            guard let p = d.page(at: i)?.copy() as? PDFPage else { return 0 }
            let one = PDFDocument()
            one.insert(p, at: 0)
            return one.dataRepresentation()?.count ?? 0
        }
    }

    /// 把指定页写出为一个 PDF 文件（base-XX.pdf）
    private func writePages(_ indices: [Int], to directory: URL, baseName: String,
                            index: Int, digits: Int) -> URL? {
        guard let d = document else { return nil }
        let out = PDFDocument()
        for i in indices {
            guard let p = d.page(at: i)?.copy() as? PDFPage else { continue }
            out.insert(p, at: out.pageCount)
        }
        let url = directory.appendingPathComponent(
            String(format: "%@-%0\(digits)d.pdf", baseName, index))
        return out.write(to: url) ? url : nil
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
            // 等比放缩适配新画幅（不裁切，信息不丢失）；锚点只决定留白方向
            let scale = min(widthPt / os.width, heightPt / os.height)
            let sw = os.width * scale
            let sh = os.height * scale
            let dx: CGFloat
            switch ax { case 0: dx = 0; case 2: dx = widthPt - sw; default: dx = (widthPt - sw) / 2 }
            let dy: CGFloat
            switch ay { case 0: dy = heightPt - sh; case 2: dy = 0; default: dy = (heightPt - sh) / 2 }
            ctx.beginPDFPage([kCGPDFContextMediaBox: mb] as CFDictionary)
            ctx.saveGState()
            ctx.translateBy(x: dx, y: dy)
            ctx.scaleBy(x: scale, y: scale)
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

    // MARK: 转黑白（系统 Gray Tone Quartz 滤镜矢量转换，文字层原样保留）

    /// 转黑白诊断日志（轻量常开）：复现「弹窗点不动」类问题时看 /tmp/mpdf_gray.log
    func grayLog(_ msg: String) {
        let line = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium) + " " + msg + "\n"
        if let fh = FileHandle(forWritingAtPath: "/tmp/mpdf_gray.log") {
            fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); fh.closeFile()
        } else {
            try? line.write(toFile: "/tmp/mpdf_gray.log", atomically: true, encoding: .utf8)
        }
    }

    /// 灰度结果文档：页面挪入活文档后仍引用来源文档的数据流，
    /// 必须持有防野指针（与 flattenRedactions 的 keepers 同一教训）。
    private static var grayPageKeepers: [PDFDocument] = []

    /// 把指定页转为灰度：系统 Gray Tone Quartz 滤镜矢量转换——只改颜色，文字层 / 批注 /
    /// 矢量图形原样保留，体积基本不变（与 ColorSync 实用工具同源）。
    /// 整本单上下文一次转换：共享资源（字体等）只嵌入一份——若按页生成小 PDF 再拼回，
    /// 每页会自带整套字体子集（实测 10 页合同 245K → 1.9M 字体复制 ×10）。
    /// 后台线程跑（私有快照文档仅该线程使用），逐页报进度、可取消，完成后主线程原地替换。
    /// 调用前须先 pushPageUndo。completion 回调主线程，n = 实际转换页数。
    func convertPagesToGray(indices: [Int],
                            onProgress: @escaping (Int, Int) -> Void,
                            isCancelled: @escaping () -> Bool,
                            completion: @escaping (Int) -> Void) {
        guard let d = document, d.pageCount > 0 else { completion(0); return }
        let targets = indices.sorted().filter { $0 >= 0 && $0 < d.pageCount }
        guard !targets.isEmpty else { completion(0); return }
        // 滤镜随 App 内置（Contents/Resources），系统路径仅作兜底
        let filterURL = Bundle.main.url(forResource: "Gray Tone", withExtension: "qfilter")
            ?? URL(fileURLWithPath: "/System/Library/Filters/Gray Tone.qfilter")
        guard let filter = QuartzFilter(url: filterURL) else {
            grayLog("引擎启动失败：滤镜加载不了 \(filterURL.path)")
            completion(0); return
        }
        grayLog("引擎启动 targets=\(targets.count) filter=\(filterURL.path)")
        // 主线程快照（活文档只允许主线程访问），后台只操作快照副本
        guard let data = d.dataRepresentation(), let work = PDFDocument(data: data) else {
            completion(0); return
        }
        func displayed(_ page: PDFPage) -> CGSize {
            let b = page.bounds(for: .mediaBox).size
            let r = Int(page.rotation) % 360
            return (r == 90 || r == 270) ? CGSize(width: b.height, height: b.width) : b
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // ⚠️ macOS 27 实测坑：beginPDFPage 的单页 kCGPDFContextMediaBox 被静默忽略，
            // 输出页一律继承 CGContext 创建时的 mediaBox（纯 CG 探针复现实锤）。
            // 因此按显示尺寸分组，每种尺寸一个转换上下文；组内仍单上下文（字体跨页去重）。
            var groupOrder: [(key: String, size: CGSize)] = []
            var groupMap: [String: [Int]] = [:]
            for i in targets {
                guard let p = work.page(at: i) else { continue }
                let size = displayed(p)
                let key = String(format: "%.2fx%.2f", size.width, size.height)
                if groupMap[key] == nil { groupOrder.append((key, size)) }
                groupMap[key, default: []].append(i)
            }
            var results: [Int: PDFPage] = [:]
            var keepers: [PDFDocument] = []
            var cancelled = false
            var done = 0
            for group in groupOrder {
                if isCancelled() { cancelled = true; break }
                let md = NSMutableData()
                var box = CGRect(origin: .zero, size: group.size)
                guard let octx = CGContext(consumer: CGDataConsumer(data: md as CFMutableData)!,
                                           mediaBox: &box, nil) else { continue }
                filter.apply(to: octx)
                for i in groupMap[group.key]! {
                    if isCancelled() { cancelled = true; break }
                    guard let p = work.page(at: i) else { continue }
                    // 上下文 mediaBox 即该组页面显示尺寸；PDFPage.draw 自动处理 /Rotate 与批注外观
                    octx.beginPDFPage(nil)
                    p.draw(with: .mediaBox, to: octx)
                    octx.endPDFPage()
                    done += 1
                    let d = done
                    DispatchQueue.main.async { onProgress(d, targets.count) }
                }
                octx.closePDF()
                if cancelled { break }
                if let sub = PDFDocument(data: md as Data) {
                    keepers.append(sub)
                    for (k, i) in groupMap[group.key]!.enumerated() {
                        if let gp = sub.page(at: k) { results[i] = gp }
                    }
                }
            }
            let resultCount = results.count
            self?.grayLog("引擎转换结束 n=\(resultCount) cancelled=\(cancelled)")
            DispatchQueue.main.async { [weak self] in
                guard let self, let live = self.document, !cancelled, resultCount > 0 else {
                    completion(0); return
                }
                // 降序替换防索引位移
                for i in results.keys.sorted(by: >) {
                    guard let gp = results[i], i < live.pageCount else { continue }
                    live.removePage(at: i)
                    live.insert(gp, at: i)
                }
                Self.grayPageKeepers.append(contentsOf: keepers)   // 防野指针
                self.hasPageEdits = true
                self.isDirty = true
                self.revision += 1
                self.grayLog("引擎替换完成 \(resultCount) 页")
                completion(resultCount)
            }
        }
    }
}

// MARK: - 窗口与文件选择辅助

/// 取文档主窗口（供打印等非 sheet 场景使用）：SwiftUI sheet 打开时
/// NSApp.mainWindow/keyWindow 会指向 sheet 自身，须回溯 sheetParent 找到承载文档的窗口。
func appContentWindow() -> NSWindow? {
    if let main = NSApp.mainWindow, main.sheetParent == nil { return main }
    if let key = NSApp.keyWindow, let parent = key.sheetParent { return parent }
    return NSApp.windows.first { $0.isVisible && $0.sheetParent == nil }
}

/// 诊断日志（常开轻量，/tmp/mpdf_dbg.log）：弹窗生命周期、点击、面板、CloseGuard 全打点
func dbgLog(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    let line = f.string(from: Date()) + " " + s + "\n"
    let path = "/tmp/mpdf_dbg.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// 非模态弹出文件面板（NSOpenPanel / NSSavePanel 通用，回调主线程）。
/// ⚠️ macOS 26+ 上 sheet 开着时严禁 runModal()：模态会话与 SwiftUI sheet 冲突，
/// 会把整个 App 事件流锁死（主线程停在模态等待、所有窗口点击无效，只能强退）。
/// 旧注释「runModal 任何场景都可靠」在 macOS 27 实测失效，反向变成锁死元凶。
/// begin() 是独立浮窗、不接管事件循环，任何嵌套场景都可靠。
func presentPanel(_ panel: NSSavePanel, then go: @escaping () -> Void) {
    dbgLog("presentPanel begin \(panel.className)")
    panel.begin { resp in
        dbgLog("presentPanel resp=\(resp.rawValue)")
        if resp == .OK { go() }
    }
}

/// 非模态选择一个有效 PDF 文件，回调 (URL, 页数)；取消或无效文件不回调。
func pickPDFFile(message: String, onPicked: @escaping (URL, Int) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.pdf]
    panel.message = message
    presentPanel(panel) {
        guard let u = panel.url,
              let d = PDFDocument(url: u), d.pageCount > 0 else { return }
        onPicked(u, d.pageCount)
    }
}

/// 统一的「选择文件」虚线卡片（从文件插入 / 交叉插入共用，保证两个弹窗 UI 一致）
struct SourceFileCard: View {
    let fileName: String?      // nil = 未选择
    var subline: String?

    var body: some View {
        Button {
            pickPDFFile(message: L("选择要插入的 PDF")) { url, pageCount in
                onPicked(url, pageCount)
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: fileName == nil ? "plus.viewfinder" : "doc.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(fileName == nil ? Color.accentColor : Color.secondary)
                Text(fileName ?? L("选择文件"))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .help(fileName ?? L("选择文件"))
                if let s = subline {
                    Text(s)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 78)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(
                        fileName == nil
                            ? Color(nsColor: .separatorColor)
                            : Color.accentColor.opacity(0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    let onPicked: (_ url: URL, _ pages: Int) -> Void

    init(fileName: String?, subline: String? = nil, onPicked: @escaping (_ url: URL, _ pages: Int) -> Void) {
        self.fileName = fileName
        self.subline = subline
        self.onPicked = onPicked
    }
}

// MARK: - 缩略图共享缓存（全局单例，按文档身份隔离）

/// 页面管理 / 预览共用的全局缩略图缓存。渲染走 PDFKit thumbnail（与最初版本一致，
/// 对常见 PDF 有快速路径、秒出）；架构上保留共享缓存的价值：
/// 1. 可见页同步即时渲染——格子出现立即出图，不显示菊花（onAppear 回调在视图
///    更新之外，同步改缓存安全）；
/// 2. 其余页主线程分批（每批 2 页）渐进预取，批间让出 runloop，UI 不卡死；
/// 3. 缓存按 PDFDocument 实例身份全局保存，切标签回来直接命中、零重渲染；
/// 4. 页操作（revision 变化）整本失效；超过 6 份文档按最近使用逐出防内存膨胀。
/// PDFKit 渲染须在主线程（PDFPage 非线程安全），故全部调度回主线程执行。
final class ThumbStore: ObservableObject {
    static let shared = ThumbStore()
    let objectWillChange = ObservableObjectPublisher()

    private var cache: [ObjectIdentifier: [Int: NSImage]] = [:]
    private var docs: [ObjectIdentifier: PDFDocument] = [:]
    private var widths: [ObjectIdentifier: CGFloat] = [:]
    private var pending: [ObjectIdentifier: [Int]] = [:]     // 预取队列（FIFO，可见页可插队）
    private var jobs: [ObjectIdentifier: Set<Int>] = [:]
    private var lastUse: [ObjectIdentifier: Date] = [:]      // LRU 逐出依据
    private var draining = false
    private var notifying = false

    func image(for docID: ObjectIdentifier, page: Int) -> NSImage? {
        lastUse[docID] = Date()
        return cache[docID]?[page]
    }

    /// 请求单页：命中缓存即时返回；未命中同步渲染（秒出，与最初版本一致）。
    /// 若该页已在预取队列中，则插队到队首。主线程调用。
    func request(document: PDFDocument, page: Int, width: CGFloat) {
        let docID = ObjectIdentifier(document)
        docs[docID] = document
        widths[docID] = width
        if cache[docID]?[page] != nil { return }
        if jobs[docID, default: []].contains(page) {
            pending[docID]?.removeAll { $0 == page }
            pending[docID]?.insert(page, at: 0)
            return
        }
        jobs[docID, default: []].insert(page)
        renderNow(document: document, docID: docID, page: page, width: width)
    }

    /// 后台预取整本文档（幂等）：只排队，不阻塞调用方。
    func prefetch(document: PDFDocument?, width: CGFloat) {
        guard let document, document.pageCount > 0 else { return }
        let docID = ObjectIdentifier(document)
        docs[docID] = document
        widths[docID] = width
        for i in 0..<document.pageCount {
            guard cache[docID]?[i] == nil, !jobs[docID, default: []].contains(i) else { continue }
            jobs[docID, default: []].insert(i)
            pending[docID, default: []].append(i)
        }
        drainSoon()
    }

    /// 页面编辑后整本失效（页序/内容已变，缓存不可复用）。主线程调用。
    func invalidate(document: PDFDocument?) {
        guard let document else { return }
        let docID = ObjectIdentifier(document)
        cache[docID] = nil
        pending[docID] = nil
        jobs[docID] = nil
        pulse()
    }

    // MARK: 私有

    /// PDFKit 同步渲染一页并入缓存（主线程调用）
    @discardableResult
    private func renderNow(document: PDFDocument, docID: ObjectIdentifier, page: Int, width: CGFloat) -> Bool {
        guard let p = document.page(at: page) else {
            jobs[docID]?.remove(page)
            return false
        }
        let size = p.bounds(for: .mediaBox)
        let scale = width / max(size.width, 1)
        let img = p.thumbnail(of: CGSize(width: width, height: max(size.height * scale, 40)),
                              for: .mediaBox)
        jobs[docID]?.remove(page)
        cache[docID, default: [:]][page] = img
        evictIfNeeded()
        pulse()
        return true
    }

    /// 预取泵：每次 runloop 渲染一批（2 页），批间让出事件循环保持 UI 流畅
    private func drainSoon() {
        guard !draining else { return }
        draining = true
        DispatchQueue.main.async { [weak self] in self?.drainStep() }
    }

    private func drainStep() {
        draining = false
        var rendered = 0
        while rendered < 2 {
            guard let docID = pending.first(where: { !$0.value.isEmpty })?.key,
                  let doc = docs[docID],
                  let page = pending[docID]?.first else { break }
            pending[docID]?.removeFirst()
            renderNow(document: doc, docID: docID, page: page, width: widths[docID] ?? 170)
            rendered += 1
        }
        if pending.values.contains(where: { !$0.isEmpty }) {
            drainSoon()
        } else {
            pulse()
        }
    }

    /// 逐出最久未用的文档缓存（保留最近 6 本，防扫描件多开内存膨胀）
    private func evictIfNeeded() {
        guard cache.count > 6,
              let oldest = lastUse.min(by: { $0.value < $1.value })?.key else { return }
        cache[oldest] = nil
        jobs[oldest] = nil
        pending[oldest] = nil
        docs[oldest] = nil
        widths[oldest] = nil
    }

    /// 批量刷新：同一 runloop 内到达的多张图合并为一次视图更新，避免逐张触发 body 重算
    private func pulse() {
        guard !notifying else { return }
        notifying = true
        DispatchQueue.main.async { [weak self] in
            self?.notifying = false
            self?.objectWillChange.send()
        }
    }
}

/// 统一卡片样式：大圆角 + 柔和投影（弹窗内容分区 / 卡片通用），
/// 让浅色与深色主题下的浮层都有「浮起」层次感。
struct DialogCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.10), radius: 7, x: 0, y: 2)
    }
}

extension View {
    /// 应用统一卡片样式（大圆角 + 柔和投影）
    func dialogCard() -> some View {
        modifier(DialogCardStyle())
    }
}

/// 弹窗底部按钮统一样式：加大尺寸更易点击（prominent = 主操作蓝底白字）
struct DialogButtonStyle: ButtonStyle {    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: prominent ? .semibold : .regular))
            .frame(minWidth: 104, minHeight: 28)
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(prominent ? AnyShapeStyle(Color.accentColor)
                          : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(prominent ? Color.clear : Color(nsColor: .separatorColor),
                                  lineWidth: 1)
            )
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.65 : 1)
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
