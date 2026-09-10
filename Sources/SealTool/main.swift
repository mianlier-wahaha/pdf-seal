import Foundation
import CoreGraphics
import AppKit
import PDFKit
import SealCore

// 无头验证工具：
//   swift run sealtool <workdir>
// 生成测试 PDF（10 页，第 3、7 页旋转 90°）和测试印章 → 骑缝+正文章盖章导出 → 渲染若干页 PNG 供人工校验
let workDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : URL(fileURLWithPath: "tmp-verify", isDirectory: true)

try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

func report(_ msg: String) { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!) }

do {
    let pdfURL = workDir.appendingPathComponent("test.pdf")
    let sealURL = workDir.appendingPathComponent("seal.png")

    try TestPDFGenerator.generate(url: pdfURL, pages: 10, rotatePages: [2, 6])
    try SealImageGenerator.generate(url: sealURL)
    report("✓ 测试 PDF（10 页，第 3/7 页旋转 90°）与印章已生成")

    guard let sealNS = NSImage(contentsOf: sealURL),
          var sealCG = sealNS.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw SealError.badSealImage
    }
    // 统一为 8bit RGBA，保证 cropping 稳定
    if let fixed = sealCG.fixOrientationAlpha() { sealCG = fixed }

    guard let doc = PDFDocument(url: pdfURL) else { throw SealError.cannotOpenInput }
    let pageSizes: [CGSize] = (0..<doc.pageCount).map {
        PageBox.displayedSize(doc.page(at: $0)!)
    }

    // 场景 1：骑缝章（右缝，全部 10 页）
    var q = QifengConfig()
    q.edge = .right
    q.range = 0...9
    q.sizeRatio = 0.15
    q.offset = 0
    let qp = StampGeometry.qifeng(config: q, pageSizes: pageSizes, sealAspect: 1.0, opacity: 0.9)

    var out1 = workDir.appendingPathComponent("qifeng-stamped.pdf")
    try PDFExporter.export(input: pdfURL, output: out1, placements: qp, seal: sealCG)
    report("✓ 骑缝章导出完成：\(out1.path)（\(qp.count) 条贴片）")

    // 场景 2：骑缝章（页范围 4...8）+ 正文章（尾页拖放位置）
    q.range = 3...7
    var f = FullStampConfig()
    f.range = 9...9
    f.anchor = CGPoint(x: 0.72, y: 0.82)
    f.sizeRatio = 0.18
    f.rotation = -8
    let mixed = StampGeometry.qifeng(config: q, pageSizes: pageSizes, sealAspect: 1.0, opacity: 0.9)
        + StampGeometry.full(config: f, pageSizes: pageSizes, sealAspect: 1.0, opacity: 0.9)
    let out2 = workDir.appendingPathComponent("mixed-stamped.pdf")
    try PDFExporter.export(input: pdfURL, output: out2, placements: mixed, seal: sealCG)
    report("✓ 混合盖章导出完成：\(out2.path)")

    // 场景 3：纯文本水印（平铺 45°，全部页；无任何章）
    let songtiPS = AppKit.NSFontManager.shared.availableMembers(ofFontFamily: "Songti SC")?.first?.first as? String
        ?? "PingFangSC-Regular"
    report("  - Songti SC PostScript 名：\(songtiPS)")
    var wm = WatermarkConfig()
    wm.text = "招商车研 内部资料"
    wm.fontPS = songtiPS
    wm.fontSize = 44
    wm.rotation = 45
    wm.opacity = 0.08
    wm.mode = .tiled
    let out3 = workDir.appendingPathComponent("watermark-only.pdf")
    try PDFExporter.export(input: pdfURL, output: out3, placements: [], seals: [:],
                           watermark: wm, watermarkPages: nil)
    report("✓ 纯水印导出完成：\(out3.path)")

    // 场景 4：水印（页范围 3...5）+ 骑缝章全页叠加，验证水印垫底与页码过滤
    let out4 = workDir.appendingPathComponent("watermark-stamped.pdf")
    try PDFExporter.export(input: pdfURL, output: out4, placements: qp, seals: [0: sealCG],
                           watermark: wm, watermarkPages: 2...4)
    report("✓ 水印+章叠加导出完成：\(out4.path)（水印仅第 3–5 页）")

    // 渲染验证图：骑缝版第 1/3 页（3 为旋转页）、混合版第 5/10 页
    out1 = workDir.appendingPathComponent("qifeng-stamped.pdf")
    let checks: [(URL, Int, Int, String)] = [
        (out1, 0, 480, "check-qifeng-p1.png"),
        (out1, 2, 480, "check-qifeng-p3-rotated.png"),
        (out2, 4, 480, "check-mixed-p5.png"),
        (out2, 9, 480, "check-mixed-p10-fullstamp.png"),
        (out3, 0, 480, "check-wm-p1.png"),
        (out3, 2, 480, "check-wm-p3-rotated.png"),
        (out4, 2, 480, "check-wm-stamp-p3.png"),
        (out4, 5, 480, "check-wm-stamp-p6-nowm.png"),
    ]
    for (src, page, w, name) in checks {
        try PDFRender.renderPagePNG(pdfURL: src, pageIndex: page, width: CGFloat(w),
                                    out: workDir.appendingPathComponent(name))
        report("  - 渲染 \(name)")
    }
    report("全部验证产物已写入 \(workDir.path)")

    // 附加实验：真实导出器处理带 /Rotate 90 的单页样本
    let labSrc = workDir.appendingPathComponent("rotlab-src.pdf")
    try TestPDFGenerator.generate(url: labSrc, pages: 1, rotatePages: [0])
    try PDFExporter.export(input: labSrc, output: workDir.appendingPathComponent("rotlab-export.pdf"),
                           placements: [], seal: sealCG)
    try PDFRender.renderPagePNG(pdfURL: workDir.appendingPathComponent("rotlab-export.pdf"),
                                pageIndex: 0, width: 600,
                                out: workDir.appendingPathComponent("d4-rotlab-export.png"))
    report("✓ 旋转单页导出实验完成（d4-rotlab-export.png）")
} catch {
    report("✗ 失败：\(error.localizedDescription)")
    exit(1)
}

extension CGImage {
    /// 重绘为 8bit RGBA（顺便归一化 DPI），避免特殊色彩空间下 cropping 异常
    func fixOrientationAlpha() -> CGImage? {
        let w = width, h = height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
