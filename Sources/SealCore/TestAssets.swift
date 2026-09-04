import Foundation
import CoreGraphics
import CoreText
import AppKit
import PDFKit

public enum TestPDFGenerator {
    /// 生成多页测试 PDF。rotatePages 中出现的 0-based 页码会被 PDFKit 设为 /Rotate 90。
    public static func generate(url: URL, pages: Int, rotatePages: [Int] = []) throws {
        let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)
        var mediaBox = a4
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw SealError.cannotCreateContext("generic")
        }
        for i in 0..<pages {
            ctx.beginPDFPage(nil)
            drawPageBody(ctx, index: i, bounds: a4)
            ctx.endPDFPage()
        }
        ctx.closePDF()

        guard !rotatePages.isEmpty else { return }
        guard let pdfDoc = PDFDocument(url: url) else { throw SealError.cannotOpenInput }
        for idx in rotatePages where idx < pdfDoc.pageCount {
            pdfDoc.page(at: idx)?.rotation = 90
        }
        guard let data = pdfDoc.dataRepresentation() else { throw SealError.cannotCreateContext("generic2") }
        try data.write(to: url)
    }

    private static func drawPageBody(_ ctx: CGContext, index: Int, bounds: CGRect) {
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(bounds)
        ctx.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
        ctx.setLineWidth(1)
        ctx.stroke(bounds.insetBy(dx: 28, dy: 28))
        for row in 0..<14 {
            drawText(ctx, text: String(repeating: "合同条款测试内容 ", count: 3),
                     at: CGPoint(x: 48, y: bounds.height - 90 - CGFloat(row) * 42),
                     size: 13, color: CGColor(gray: 0.25, alpha: 1))
        }
        drawText(ctx, text: "第 \(index + 1) 页",
                 at: CGPoint(x: bounds.width / 2 - 40, y: bounds.height / 2 - 20),
                 size: 34, color: CGColor(gray: 0.4, alpha: 1))
    }

    @discardableResult
    public static func drawText(_ ctx: CGContext, text: String, at point: CGPoint,
                                size: CGFloat, color: CGColor) -> CGFloat {
        let font = CTFontCreateWithName("PingFang SC" as CFString, size, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font,
                                      kCTForegroundColorAttributeName: color]
        guard let attr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary) else { return 0 }
        let line = CTLineCreateWithAttributedString(attr)
        ctx.saveGState()
        ctx.textPosition = point
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

public enum SealImageGenerator {
    /// 生成一枚测试电子章（透明底）：双圈 + 五角星 + 文字
    public static func generate(url: URL, side: CGFloat = 800) throws {
        guard let ctx = CGContext(data: nil, width: Int(side), height: Int(side),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw SealError.cannotCreateContext("generic2") }
        let c = CGPoint(x: side / 2, y: side / 2)
        let red = CGColor(srgbRed: 0.85, green: 0.11, blue: 0.11, alpha: 1)
        ctx.setStrokeColor(red)
        ctx.setFillColor(red)
        ctx.setLineWidth(side * 0.035)
        ctx.strokeEllipse(in: CGRect(x: c.x - side * 0.46, y: c.y - side * 0.46,
                                     width: side * 0.92, height: side * 0.92))
        ctx.setLineWidth(side * 0.012)
        ctx.strokeEllipse(in: CGRect(x: c.x - side * 0.40, y: c.y - side * 0.40,
                                     width: side * 0.80, height: side * 0.80))
        let r1 = side * 0.16, r2 = side * 0.065
        let path = CGMutablePath()
        var up = true
        for k in 0..<10 {
            let ang = CGFloat(k) / 10 * 2 * .pi + .pi / 2
            let r = up ? r1 : r2
            let pt = CGPoint(x: c.x + r * cos(ang), y: c.y + r * sin(ang))
            if k == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            up.toggle()
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()
        TestPDFGenerator.drawText(ctx, text: "测试专用章",
                                  at: CGPoint(x: c.x - side * 0.24, y: c.y + side * 0.24),
                                  size: side * 0.10, color: red)
        TestPDFGenerator.drawText(ctx, text: "900101-9",
                                  at: CGPoint(x: c.x - side * 0.14, y: c.y - side * 0.20),
                                  size: side * 0.08, color: red)
        guard let img = ctx.makeImage() else { throw SealError.badSealImage }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SealError.badSealImage
        }
        try png.write(to: url)
    }
}

public enum PDFRender {
    /// 用 PDFKit 渲染某页为 PNG（含旋转），供验证输出效果
    public static func renderPagePNG(pdfURL: URL, pageIndex: Int, width: CGFloat, out: URL) throws {
        guard let doc = PDFDocument(url: pdfURL), let page = doc.page(at: pageIndex) else {
            throw SealError.cannotOpenInput
        }
        let size = PageBox.displayedSize(page)
        let scale = width / size.width
        let img = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale),
                                 for: .mediaBox)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw SealError.cannotCreateContext("generic")
        }
        try png.write(to: out)
    }
}
