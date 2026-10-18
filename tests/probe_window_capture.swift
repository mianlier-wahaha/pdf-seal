// 探针 3：真实窗口 + CGWindowListCreateImage 验证 PDFView 实时渲染
import AppKit
import PDFKit

final class ShapePageCoords: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.setFillColor(NSColor.red.cgColor)
        context.fill(bounds)   // 页面空间
        context.restoreGState()
    }
}
final class ShapeRelCoords: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.setFillColor(NSColor(red: 0, green: 0.7, blue: 0, alpha: 1).cgColor)
        context.fill(NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height))  // bounds 相对
        context.restoreGState()
    }
}
final class TextProbe: PDFAnnotation {
    var bgColor: NSColor? = nil
    var textRotation: CGFloat = 0
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        if let bg = bgColor { bg.setFill(); context.fill(bounds) }
        context.translateBy(x: bounds.midX, y: bounds.midY)
        if textRotation.truncatingRemainder(dividingBy: 360) != 0 {
            context.rotate(by: -textRotation * .pi / 180)
        }
        let str = NSAttributedString(string: contents ?? "", attributes: [
            .font: font ?? .systemFont(ofSize: 20),
            .foregroundColor: fontColor ?? .black,
        ])
        let g = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        str.draw(at: NSPoint(x: -str.size().width / 2, y: -str.size().height / 2))
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}

let doc = PDFDocument()
let page = PDFPage()
doc.insert(page, at: 0)

let s1 = ShapePageCoords(bounds: NSRect(x: 60, y: 60, width: 120, height: 80), forType: .stamp, withProperties: nil)
s1.color = .clear
page.addAnnotation(s1)

let s2 = ShapeRelCoords(bounds: NSRect(x: 60, y: 200, width: 120, height: 80), forType: .stamp, withProperties: nil)
s2.color = .clear
page.addAnnotation(s2)

let t1 = TextProbe(bounds: NSRect(x: 300, y: 60, width: 140, height: 70), forType: .stamp, withProperties: nil)
t1.contents = "旋转90"
t1.font = .boldSystemFont(ofSize: 26)
t1.fontColor = .black
t1.bgColor = NSColor(red: 1, green: 0.9, blue: 0.3, alpha: 1)
t1.textRotation = 90
t1.color = .clear
page.addAnnotation(t1)

let t2 = TextProbe(bounds: NSRect(x: 300, y: 200, width: 140, height: 70), forType: .stamp, withProperties: nil)
t2.contents = "无旋转"
t2.font = .boldSystemFont(ofSize: 26)
t2.fontColor = .black
t2.bgColor = NSColor(red: 1, green: 0.9, blue: 0.3, alpha: 1)
t2.color = .clear
page.addAnnotation(t2)

let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 612, height: 792),
                   styleMask: [.titled], backing: .buffered, defer: false)
win.title = "probe"
let pv = PDFView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
pv.document = doc
pv.autoScales = true
win.contentView = pv
win.makeKeyAndOrderFront(nil)
win.display()
pv.displayIfNeeded()

for _ in 0..<30 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

let winID = CGWindowID(win.windowNumber)
if let cg = CGWindowListCreateImage(CGRect(x: 0, y: 0, width: 612, height: 792), .optionIncludingWindow, winID, [.bestResolution]) {
    let rep = NSBitmapImageRep(cgImage: cg)
    print("captured:", rep.pixelsWide, "x", rep.pixelsHigh, "scale:", pv.scaleFactor)
    let sf = rep.pixelsWide / 612
    // PDFView 居中显示，计算页面位置
    let pvRect = pv.bounds
    let scale = pv.scaleFactor
    let pageW = page.bounds(for: .mediaBox).width * scale
    let pageH = page.bounds(for: .mediaBox).height * scale
    let ox = (pvRect.width - pageW) / 2, oy = (pvRect.height - pageH) / 2
    func samplePage(_ px: CGFloat, _ py: CGFloat) -> (Int, Int, Int) {
        let x = Int((ox + px * scale) * CGFloat(sf))
        let yBitmap = Int((oy + py * scale) * CGFloat(sf))  // bitmap y 向下，PDFView 视图坐标 y 向上 → bitmap 行 = pixelsHigh - y
        guard let c = rep.colorAt(x: x, y: rep.pixelsHigh - 1 - yBitmap) else { return (-1,-1,-1) }
        return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
    print("1 页面空间红矩形中心(120,100):", samplePage(120, 100), "红=页面空间✓")
    print("2 rel矩形中心(120,240):", samplePage(120, 240), "绿=bounds相对✓")
    print("3 旋转90黄底中心(370,95):", samplePage(370, 95), "黄=背景✓")
    print("4 无旋转黄底中心(370,235):", samplePage(370, 235), "黄=背景✓")
    print("5 页面空白处(500,500):", samplePage(500, 500), "白=背景")
} else {
    print("CAPTURE FAILED - 无屏幕录制权限")
}
