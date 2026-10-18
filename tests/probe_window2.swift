// 探针 3b：真实窗口 + screencapture CLI 截屏验证 PDFView 实时渲染
import AppKit
import PDFKit

final class ShapePageCoords: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.setFillColor(NSColor.red.cgColor)
        context.fill(bounds)
        context.restoreGState()
    }
}
final class ShapeRelCoords: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.setFillColor(NSColor(red: 0, green: 0.7, blue: 0, alpha: 1).cgColor)
        context.fill(NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
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

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)

let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 612, height: 792),
                   styleMask: [.titled], backing: .buffered, defer: false)
win.title = "probe"
let pv = PDFView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
pv.document = doc
pv.autoScales = true
win.contentView = pv
win.makeKeyAndOrderFront(nil)

for _ in 0..<40 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

let out = "/tmp/mPDF_probe_capture.png"
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
p.arguments = ["-x", "-l", "\(win.windowNumber)", "-o", out]
try? p.run()
p.waitUntilExit()

guard let img = NSImage(contentsOfFile: out),
      let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    print("CAPTURE FAILED")
    exit(0)
}
print("captured:", rep.pixelsWide, "x", rep.pixelsHigh, "scale:", pv.scaleFactor)
let sf = Double(rep.pixelsWide) / 612.0
let scale = pv.scaleFactor
let pageW = page.bounds(for: .mediaBox).width * scale
let pageH = page.bounds(for: .mediaBox).height * scale
let ox = (pv.bounds.width - pageW) / 2, oy = (pv.bounds.height - pageH) / 2
func samplePage(_ px: CGFloat, _ py: CGFloat) -> (Int, Int, Int) {
    let x = Int((ox + px * scale) * CGFloat(sf))
    let yBitmap = Int((oy + py * scale) * CGFloat(sf))
    guard let c = rep.colorAt(x: x, y: rep.pixelsHigh - 1 - yBitmap) else { return (-1,-1,-1) }
    return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
}
print("1 页面空间红矩形中心:", samplePage(120, 100), "红=页面空间✓")
print("2 rel矩形中心:", samplePage(120, 240), "绿=bounds相对✓")
print("3 旋转90黄底中心:", samplePage(370, 95), "黄=背景✓")
print("4 无旋转黄底中心:", samplePage(370, 235), "黄=背景✓")
print("5 页面空白处:", samplePage(500, 500), "白=背景")
exit(0)
