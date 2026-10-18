// 探针 1c：Ink alpha 颜色/小数线宽 + .line 类型 border.lineWidth
import AppKit
import PDFKit

let doc = PDFDocument()
let page = PDFPage()
doc.insert(page, at: 0)

func addInk(y: CGFloat, lw: CGFloat, alpha: CGFloat) {
    let rect = NSRect(x: 60, y: y - 20, width: 400, height: 40)
    let ink = PDFAnnotationInk(bounds: rect, forType: .ink, withProperties: nil)
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 10, y: 20))
    p.line(to: NSPoint(x: 390, y: 20))
    ink.add(p)
    ink.color = NSColor.black.withAlphaComponent(alpha)
    let b = PDFBorder(); b.lineWidth = lw
    ink.border = b
    page.addAnnotation(ink)
}
addInk(y: 600, lw: 9.5, alpha: 0.6)   // 小数宽 + 透明色
addInk(y: 500, lw: 3, alpha: 1.0)     // 整数对照

// .line 类型
let lineRect = NSRect(x: 50, y: 380, width: 420, height: 60)
let l = PDFAnnotation(bounds: lineRect, forType: .line, withProperties: nil)
l.startPoint = NSPoint(x: 20, y: 30)
l.endPoint = NSPoint(x: 400, y: 30)
l.color = .black
let lb = PDFBorder(); lb.lineWidth = 10
l.border = lb
page.addAnnotation(l)

let img = page.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox)
guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { fatalError() }
func thick(_ yPage: Int) -> Int {
    // x=250 处竖直扫描深色段（alpha 0.6 的黑在白底上≈灰 102）
    var best = 0, cur = 0
    for py in (yPage - 45)...(yPage + 45) {
        guard let c = rep.colorAt(x: 250, y: rep.pixelsHigh - 1 - py) else { continue }
        let lum = c.redComponent * 255
        if lum < 180 { cur += 1; best = max(best, cur) } else { cur = 0 }
    }
    return best
}
print("Ink lw=9.5 alpha=0.6 实测:", thick(600), "（期望≈10）")
print("Ink lw=3 alpha=1.0 实测:", thick(500), "（期望≈3）")
print("line lw=10 实测:", thick(410), "（期望≈10）")
// 保存重读
let doc2 = PDFDocument(data: doc.dataRepresentation() ?? Data())!
let rep2 = NSBitmapImageRep(data: doc2.page(at: 0)!.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox).tiffRepresentation!)!
func thick2(_ yPage: Int) -> Int {
    var best = 0, cur = 0
    for py in (yPage - 45)...(yPage + 45) {
        guard let c = rep2.colorAt(x: 250, y: rep2.pixelsHigh - 1 - py) else { continue }
        if c.redComponent * 255 < 180 { cur += 1; best = max(best, cur) } else { cur = 0 }
    }
    return best
}
print("重读 Ink 9.5:", thick2(600), " Ink 3:", thick2(500), " line 10:", thick2(410))
