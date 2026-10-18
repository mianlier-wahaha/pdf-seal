// 探针：验证 PDFKit 自绘批注渲染约定
// 1) 自定义 draw(with:in:) 是否被调用（矩形/文本）
// 2) 绘制坐标系：页面空间 还是 bounds 相对空间
// 3) Ink 批注的 border.lineWidth 是否生效
import AppKit
import PDFKit

// 用全局标志记录 draw 是否被调用
nonisolated(unsafe) var shapeDrawCalled = false
nonisolated(unsafe) var textDrawCalled = false

final class ProbeShape: PDFAnnotation {
    var usePageCoords = true
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        shapeDrawCalled = true
        context.saveGState()
        context.setFillColor(NSColor.red.cgColor)
        let r: NSRect
        if usePageCoords {
            r = bounds   // 页面空间（当前实现）
        } else {
            r = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height) // bounds 相对
        }
        context.fill(r)
        context.restoreGState()
    }
}

final class ProbeText: PDFAnnotation {
    var usePageCoords = true
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        textDrawCalled = true
        context.saveGState()
        context.setFillColor(NSColor.blue.cgColor)
        let r: NSRect
        if usePageCoords {
            r = bounds
        } else {
            r = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        }
        context.fill(r)
        context.restoreGState()
    }
}

func samplePixel(_ image: NSImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return (-1, -1, -1) }
    // NSImage 坐标系 y 向上；bitmap y 向下
    let yy = rep.pixelsHigh - 1 - y
    guard let c = rep.colorAt(x: x, y: yy) else { return (-1, -1, -1) }
    return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
}

let doc = PDFDocument()
let page = PDFPage()
doc.insert(page, at: 0)

// A. 页面空间矩形（红色填充）放在 (100, 100, 120, 80)
let shapeA = ProbeShape(bounds: NSRect(x: 100, y: 100, width: 120, height: 80), forType: .stamp, withProperties: nil)
shapeA.usePageCoords = true
shapeA.color = .clear
page.addAnnotation(shapeA)

// B. bounds 相对矩形（绿色填充）放在 (300, 100, 120, 80)
let shapeB = ProbeShape(bounds: NSRect(x: 300, y: 100, width: 120, height: 80), forType: .stamp, withProperties: nil)
shapeB.usePageCoords = false
shapeB.color = .clear
page.addAnnotation(shapeB)

// C. 文本类蓝色填充，两种坐标
let textA = ProbeText(bounds: NSRect(x: 100, y: 300, width: 120, height: 80), forType: .stamp, withProperties: nil)
textA.usePageCoords = true
textA.color = .clear
page.addAnnotation(textA)

let textB = ProbeText(bounds: NSRect(x: 300, y: 300, width: 120, height: 80), forType: .stamp, withProperties: nil)
textB.usePageCoords = false
textB.color = .clear
page.addAnnotation(textB)

// D. Ink 粗线：border.lineWidth = 14，从 (100, 550) 到 (400, 550)
let inkRect = NSRect(x: 90, y: 520, width: 320, height: 60)
let ink = PDFAnnotationInk(bounds: inkRect, forType: .ink, withProperties: nil)
let p = NSBezierPath()
p.move(to: NSPoint(x: 10, y: 30))
p.line(to: NSPoint(x: 310, y: 30))
ink.add(p)
ink.color = .black
let border = PDFBorder()
border.lineWidth = 14
ink.border = border
page.addAnnotation(ink)

// E. Ink 细线：border.lineWidth = 2
let ink2Rect = NSRect(x: 90, y: 440, width: 320, height: 60)
let ink2 = PDFAnnotationInk(bounds: ink2Rect, forType: .ink, withProperties: nil)
let p2 = NSBezierPath()
p2.move(to: NSPoint(x: 10, y: 30))
p2.line(to: NSPoint(x: 310, y: 30))
ink2.add(p2)
ink2.color = .black
let border2 = PDFBorder()
border2.lineWidth = 2
ink2.border = border2
page.addAnnotation(ink2)

let img = page.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox)
// thumbnail 可能带缩放，改为直接用 NSImage size 检查
print("thumbnail size:", img.size)

// 采样：A 中心 (160, 140)、B 中心 (360, 140)、C 中心 (160, 340)、D 线上 (250, 550)、E 线上 (250, 470)
print("A pageCoords 中心:", samplePixel(img, 160, 140), "（红色=页面空间生效）")
print("B relCoords 中心:", samplePixel(img, 360, 140), "（绿色=bounds相对生效）")
print("C pageCoords 文本区:", samplePixel(img, 160, 340), "（蓝色=页面空间生效）")
print("C2 relCoords 文本区:", samplePixel(img, 360, 340), "（蓝色=bounds相对生效）")

// 测 Ink 线宽：在 x=250 竖直扫描，统计黑色像素段长度
func inkThickness(_ image: NSImage, x: Int, yAround: Int) -> Int {
    var count = 0
    for y in (yAround - 40)...(yAround + 40) {
        let c = samplePixel(image, x, y)
        if c.r < 60 && c.g < 60 && c.b < 60 { count += 1 }
    }
    return count
}
print("D Ink lineWidth=14 实测厚度:", inkThickness(img, x: 250, yAround: 550))
print("E Ink lineWidth=2  实测厚度:", inkThickness(img, x: 250, yAround: 470))
print("shapeDraw called:", shapeDrawCalled, "textDraw called:", textDrawCalled)

// F. 保存后重新读取，检查外观流是否持久化 + 再渲染一次
let data = doc.dataRepresentation() ?? Data()
let doc2 = PDFDocument(data: data)!
let page2 = doc2.page(at: 0)!
let img2 = page2.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox)
print("重读后 A:", samplePixel(img2, 160, 140), " B:", samplePixel(img2, 360, 140),
      " D厚度:", inkThickness(img2, x: 250, yAround: 550), " E厚度:", inkThickness(img2, x: 250, yAround: 470))
