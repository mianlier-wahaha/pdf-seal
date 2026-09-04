import Foundation
import CoreGraphics
import PDFKit

public enum SealError: LocalizedError {
    case cannotOpenInput
    case cannotCreateContext(String)
    case badSealImage

    public var errorDescription: String? {
        switch self {
        case .cannotOpenInput: return "无法打开输入 PDF（可能已加密或损坏）"
        case .cannotCreateContext(let stage): return "无法创建输出 PDF（\(stage)）"
        case .badSealImage: return "印章图片无效"
        }
    }
}

public enum PDFExporter {
    /// 将盖章后的 PDF 写入 output。一律另存，不触碰原文件。
    /// placements 的 destRect 基于显示空间（已考虑 /Rotate）。
    ///
    /// 实现说明：macOS 26 上 beginPDFPage 的 per-page MediaBox 不生效，
    /// 故按页面尺寸分组写出临时 PDF，再由 PDFKit 按原始页序合并（保持矢量）。
    public static func export(input: URL, output: URL,
                              placements: [StampPlacement],
                              seal: CGImage) throws {
        try export(input: input, output: output, placements: placements, seals: [0: seal])
    }

    /// 多章版本：placement.sealKey 对应 seals 字典的键
    public static func export(input: URL, output: URL,
                              placements: [StampPlacement],
                              seals: [Int: CGImage]) throws {
        guard let doc = CGPDFDocument(input as CFURL) else { throw SealError.cannotOpenInput }
        let pageCount = doc.numberOfPages

        struct PageMeta {
            let index: Int          // 0-based 原始页码
            let angle: CGFloat
            let size: CGSize        // 显示尺寸
            let mb: CGRect
        }
        var metas: [PageMeta] = []
        for i in 0..<pageCount {
            guard let page = doc.page(at: i + 1) else { continue }
            let mb = page.getBoxRect(.mediaBox)
            let rot = Int(page.rotationAngle) % 360
            let angle: CGFloat
            let size: CGSize
            switch rot {
            case 90, -270: angle = 90; size = CGSize(width: mb.height, height: mb.width)
            case 180, -180: angle = 180; size = mb.size
            case 270, -90: angle = 270; size = CGSize(width: mb.height, height: mb.width)
            default: angle = 0; size = mb.size
            }
            metas.append(PageMeta(index: i, angle: angle, size: size, mb: mb))
        }

        var byPage: [Int: [StampPlacement]] = [:]
        for p in placements { byPage[p.pageIndex, default: []].append(p) }

        // 按显示尺寸分组（组内保持页序）
        var groups: [String: [PageMeta]] = [:]
        for m in metas { groups[sizeKey(m.size), default: []].append(m) }

        // 临时组文件放到输出文件同目录（/var/folders 临时目录在本机存在被即时回收的异常）
        let tmpDir = output.deletingLastPathComponent()
        let tmpPrefix = ".pdfseal-tmp-\(UUID().uuidString)-"
        var staleCleanup: [URL] = []
        defer {
            for u in staleCleanup { try? FileManager.default.removeItem(at: u) }
        }

        var groupFiles: [String: URL] = [:]
        for (key, pages) in groups {
            let fileURL = tmpDir.appendingPathComponent("\(tmpPrefix)\(key).pdf")
            staleCleanup.append(fileURL)
            guard let first = pages.first else { continue }
            var mediaBox = CGRect(origin: .zero, size: first.size)
            guard let ctx = CGContext(fileURL as CFURL, mediaBox: &mediaBox, nil) else {
                throw SealError.cannotCreateContext("group ctx \(fileURL.lastPathComponent) errno=\(errno)")
            }
            for m in pages {
                ctx.beginPDFPage(nil)
                // 原页内容：显示空间 → 原始用户空间
                ctx.saveGState()
                switch m.angle {
                case 90:
                    ctx.concatenate(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: m.mb.width))
                case 180:
                    ctx.concatenate(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: m.mb.width, ty: m.mb.height))
                case 270:
                    ctx.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: m.mb.height, ty: 0))
                default:
                    break
                }
                if let page = doc.page(at: m.index + 1) {
                    ctx.drawPDFPage(page)
                }
                ctx.restoreGState()

                for pl in (byPage[m.index] ?? []).sorted(by: { $0.source.minX < $1.source.minX }) {
                    guard let sealImg = seals[pl.sealKey] else { continue }
                    drawPlacement(pl, seal: sealImg, in: ctx)
                }
                ctx.endPDFPage()
            }
            ctx.closePDF()
            groupFiles[key] = fileURL
        }

        // PDFKit 按原始页序合并
        let merged = PDFDocument()
        var groupDocs: [String: PDFDocument] = [:]
        var counters: [String: Int] = [:]
        for (key, fileURL) in groupFiles {
            if let d = PDFDocument(url: fileURL) { groupDocs[key] = d }
        }
        for m in metas {
            let key = sizeKey(m.size)
            guard let d = groupDocs[key] else { continue }
            let idx = counters[key, default: 0]
            counters[key] = idx + 1
            if let page = d.page(at: idx) {
                merged.insert(page, at: merged.pageCount)
            }
        }
        guard let data = merged.dataRepresentation() else { throw SealError.cannotCreateContext("merge dataRepresentation") }
        try data.write(to: output, options: .atomic)
    }

    private static func sizeKey(_ s: CGSize) -> String { "\(Int(s.width))x\(Int(s.height))" }

    private static func drawPlacement(_ pl: StampPlacement, seal: CGImage, in ctx: CGContext) {
        let iw = CGFloat(seal.width), ih = CGFloat(seal.height)
        let crop = CGRect(x: pl.source.minX * iw, y: pl.source.minY * ih,
                          width: pl.source.width * iw, height: pl.source.height * ih)
        guard let img = seal.cropping(to: crop) else { return }
        ctx.saveGState()
        ctx.setAlpha(pl.opacity)
        if pl.rotation != 0 {
            ctx.translateBy(x: pl.destRect.midX, y: pl.destRect.midY)
            ctx.rotate(by: -pl.rotation * .pi / 180)
            ctx.draw(img, in: CGRect(x: -pl.destRect.width / 2, y: -pl.destRect.height / 2,
                                     width: pl.destRect.width, height: pl.destRect.height))
        } else {
            ctx.draw(img, in: pl.destRect)
        }
        ctx.restoreGState()
    }
}
