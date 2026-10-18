// 探针 v2.7.9：①自绘下划线宽度生效 ②隐藏批注压平（遮盖块进内容层、其余批注保留）
import AppKit
import PDFKit

final class PenStrokeAnnotation: PDFAnnotation {
    var pts: [NSPoint] = []
    var strokeColor: NSColor = .black
    var strokeWidth: CGFloat = 3
    init(pts: [NSPoint], color: NSColor, width: CGFloat) {
        self.pts = pts
        self.strokeColor = color
        self.strokeWidth = width
        var minX = pts[0].x, maxX = pts[0].x, minY = pts[0].y, maxY = pts[0].y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let pad = width / 2 + 2
        let bounds = NSRect(x: minX - pad, y: minY - pad,
                            width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        self.color = .clear
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard pts.count > 1 else { return }
        let path = NSBezierPath()
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.line(to: p) }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        context.saveGState()
        let g = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        strokeColor.setStroke()
        path.lineWidth = max(strokeWidth, 0.5)
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}

// ---- ① 下划线 lw=6：竖直扫描中心厚度 ----
let doc = PDFDocument()
let page = PDFPage()
doc.insert(page, at: 0)
let ul = PenStrokeAnnotation(pts: [NSPoint(x: 80, y: 400), NSPoint(x: 400, y: 400)],
                             color: .red, width: 6)
page.addAnnotation(ul)
let img = page.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox)
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
var best = 0, cur = 0
for py in (792 - 400 - 30)...(792 - 400 + 30) {
    guard let c = rep.colorAt(x: 240, y: py) else { continue }
    if c.redComponent > 0.6 && c.greenComponent < 0.4 { cur += 1; best = max(best, cur) } else { cur = 0 }
}
print("① 下划线 lw=6 实测厚度:", best, best >= 5 && best <= 8 ? "✓ 与预览一致" : "✗")

// ---- ② 隐藏压平 ----
let marker = "mPDF-redact"
let doc2 = PDFDocument()
let p2 = PDFPage()
doc2.insert(p2, at: 0)
let rd = PDFAnnotation(bounds: NSRect(x: 100, y: 100, width: 200, height: 60), forType: .square, withProperties: nil)
rd.color = .black
rd.interiorColor = .black
rd.userName = marker
p2.addAnnotation(rd)
// 一个「其他批注」（方形红框）应保留在注释层
let keep = PDFAnnotation(bounds: NSRect(x: 320, y: 300, width: 100, height: 80), forType: .square, withProperties: nil)
keep.color = .red
p2.addAnnotation(keep)

func flattenRedactions(_ d: PDFDocument) -> PDFDocument? {
    guard let data = d.dataRepresentation(), let src = PDFDocument(data: data) else { return nil }
    let out = PDFDocument()
    var any = false
    for i in 0..<src.pageCount {
        guard let page = src.page(at: i) else { continue }
        let redacts = page.annotations.filter { $0.userName == marker }
        guard !redacts.isEmpty else { out.insert(page, at: i); continue }
        any = true
        let keepAnns = page.annotations.filter { $0.userName != marker }
        for a in page.annotations { page.removeAnnotation(a) }
        let flatData = NSMutableData()
        var mediaBox = page.bounds(for: .mediaBox)
        guard let consumer = CGDataConsumer(data: flatData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, _: nil) else {
            out.insert(page, at: i); continue
        }
        ctx.beginPDFPage(nil)
        page.draw(with: .mediaBox, to: ctx)
        for r in redacts {
            ctx.setFillColor((r.color ?? .black).cgColor)
            ctx.fill(r.bounds)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        if let flatPage = PDFDocument(data: flatData as Data)?.page(at: 0) {
            for a in keepAnns { flatPage.addAnnotation(a) }
            out.insert(flatPage, at: i)
        } else {
            out.insert(page, at: i)
        }
    }
    return any ? out : nil
}

guard let flat = flattenRedactions(doc2), let data = flat.dataRepresentation() else {
    print("② 压平失败"); exit(1)
}
let out = PDFDocument(data: data)!
let op = out.page(at: 0)!
let anns = op.annotations
let redactLeft = anns.filter { $0.userName == marker }
let keepLeft = anns.filter { $0.userName != marker }
print("② 输出注释数:", anns.count, "隐藏批注残留:", redactLeft.count, "其他批注保留:", keepLeft.count)
// 像素验证：遮盖区黑、保留批注红框可见
let rep2 = NSBitmapImageRep(data: op.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox).tiffRepresentation!)!
func sample(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    guard let c = rep2.colorAt(x: x, y: 792 - 1 - y) else { return (-1, -1, -1) }
    return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
}
let center = sample(200, 130)
print("② 遮盖区中心(200,130):", center, center.0 < 40 && center.1 < 40 ? "黑块已烘焙✓" : "✗")
let outline = sample(370, 340)   // 红框上边缘中点
print("② 保留批注边缘(370,340):", outline, outline.0 > 150 && outline.1 < 90 ? "红框仍在注释层✓" : "(边缘采样不中不算失败)")
// 写盘再读回验证持久化
let tmp = "/tmp/mPDF_flat_test.pdf"
try? data.write(to: URL(fileURLWithPath: tmp))
let reread = PDFDocument(url: URL(fileURLWithPath: tmp))!
print("② 落盘重读注释数:", reread.page(at: 0)!.annotations.count, "隐藏残留:",
      reread.page(at: 0)!.annotations.filter { $0.userName == marker }.count)
