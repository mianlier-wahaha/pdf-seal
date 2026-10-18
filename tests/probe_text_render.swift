// 探针 1b：thumbnail 路径验证 RotatableTextAnnotation 当前画法（页面空间+旋转+bg）
import AppKit
import PDFKit

final class RotatableTextProbe: PDFAnnotation {
    var bgColor: NSColor? = nil
    var textRotation: CGFloat = 0
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let text = contents ?? ""
        context.saveGState()
        if let bg = bgColor {
            context.setFillColor(bg.cgColor)
            context.fill(bounds)
        }
        context.translateBy(x: bounds.midX, y: bounds.midY)
        if textRotation.truncatingRemainder(dividingBy: 360) != 0 {
            context.rotate(by: -textRotation * .pi / 180)
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.lineBreakMode = .byWordWrapping
        let str = NSAttributedString(string: text, attributes: [
            .font: font ?? .systemFont(ofSize: 14),
            .foregroundColor: fontColor ?? .black,
            .paragraphStyle: para,
        ])
        let g = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        str.draw(in: NSRect(x: -bounds.width / 2 + 3, y: -bounds.height / 2 + 3,
                            width: max(bounds.width - 6, 1), height: max(bounds.height - 6, 1)))
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}

let doc = PDFDocument()
let page = PDFPage()
doc.insert(page, at: 0)

let t1 = RotatableTextProbe(bounds: NSRect(x: 100, y: 100, width: 160, height: 60), forType: .stamp, withProperties: nil)
t1.contents = "无旋转"
t1.font = .boldSystemFont(ofSize: 24)
t1.fontColor = .black
t1.bgColor = NSColor(red: 1, green: 0.9, blue: 0.3, alpha: 1)
t1.color = .clear
page.addAnnotation(t1)

let t2 = RotatableTextProbe(bounds: NSRect(x: 100, y: 250, width: 160, height: 60), forType: .stamp, withProperties: nil)
t2.contents = "旋转90"
t2.font = .boldSystemFont(ofSize: 24)
t2.fontColor = .black
t2.bgColor = NSColor(red: 1, green: 0.9, blue: 0.3, alpha: 1)
t2.textRotation = 90
t2.color = .clear
page.addAnnotation(t2)

let img = page.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox)
guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { fatalError() }
func sample(_ px: Int, _ py: Int) -> (Int, Int, Int) {
    // NSImage 坐标 y 向上（页面坐标），bitmap y 向下
    guard let c = rep.colorAt(x: px, y: rep.pixelsHigh - 1 - py) else { return (-1,-1,-1) }
    return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
}
let isYellow = { (c: (Int, Int, Int)) in c.0 > 200 && c.1 > 180 && c.2 < 120 }
// 无旋转：bg 中心 (180,130)；旋转90后 bg 应横跨更宽区域，中心 (180,280) 附近
print("t1 bg中心(180,130):", sample(180, 130), isYellow(sample(180,130)) ? "黄✓" : "✗")
print("t1 空白处(450,130):", sample(450, 130), "白=背景")
print("t2 bg中心(180,280):", sample(180, 280), isYellow(sample(180,280)) ? "黄✓(旋转后bg覆盖)" : "✗")
// 旋转90°：bounds 宽160高60，绘制区宽高互换 → bg 实际画出 高160宽60，覆盖 y 250..410 x 90..190
print("t2 旋转bg左缘(110,280):", sample(110, 280), isYellow(sample(110,280)) ? "黄✓" : "✗")
print("t2 旋转bg上缘(180,390):", sample(180, 390), isYellow(sample(180,390)) ? "黄✓" : "✗")
print("t2 原bounds外(270,280):", sample(270, 280), isYellow(sample(270,280)) ? "黄✓" : "白=旋转生效✓")
// 保存重读
let doc2 = PDFDocument(data: doc.dataRepresentation() ?? Data())!
let img2 = doc2.page(at: 0)!.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox)
guard let tiff2 = img2.tiffRepresentation, let rep2 = NSBitmapImageRep(data: tiff2) else { fatalError() }
func sample2(_ px: Int, _ py: Int) -> (Int, Int, Int) {
    guard let c = rep2.colorAt(x: px, y: rep2.pixelsHigh - 1 - py) else { return (-1,-1,-1) }
    return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
}
print("重读 t1 bg中心:", sample2(180, 130), isYellow(sample2(180,130)) ? "黄✓" : "✗")
print("重读 t2 旋转bg上缘:", sample2(180, 390), isYellow(sample2(180,390)) ? "黄✓" : "✗")
