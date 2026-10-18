// 探针 2：用 PDFView 离屏渲染验证（App 实际显示路径）
// 1) 自绘 stamp 批注在 PDFView 中是否渲染、坐标系
// 2) RotatableText 背景色/旋转在 PDFView 中的表现
// 3) Ink + alpha 颜色 lineWidth 在 PDFView 中的厚度
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

// 复刻 App 当前 PatternShapeAnnotation 的画法（NSGraphicsContext 桥 + bounds 相对）
final class ShapeAppReplica: PDFAnnotation {
    var contentRect: NSRect = .zero
    var strokeCol: NSColor = .red
    var strokeW: CGFloat = 3
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let drawRect = NSRect(x: contentRect.minX - bounds.minX, y: contentRect.minY - bounds.minY,
                              width: contentRect.width, height: contentRect.height)
        let path = NSBezierPath(rect: drawRect)
        context.saveGState()
        let g = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        strokeCol.setStroke()
        path.lineWidth = strokeW
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}

// 复刻 App 当前 RotatableTextAnnotation 画法（bg fill + 旋转 + NSAttributedString）
final class TextAppReplica: PDFAnnotation {
    var bgColor: NSColor? = nil
    var textRotation: CGFloat = 0
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        if let bg = bgColor {
            bg.setFill()
            context.fill(bounds)
        }
        context.translateBy(x: bounds.midX, y: bounds.midY)
        if textRotation.truncatingRemainder(dividingBy: 360) != 0 {
            context.rotate(by: -textRotation * .pi / 180)
        }
        let str = NSAttributedString(string: contents ?? "", attributes: [
            .font: font ?? .systemFont(ofSize: 14),
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

func render(_ view: NSView) -> NSBitmapImageRep {
    view.needsDisplay = true
    view.displayIfNeeded()
    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
        pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = view.bounds.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    view.layer?.render(in: NSGraphicsContext.current!.cgContext)
    view.cacheDisplay(in: view.bounds, to: rep)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let doc = PDFDocument()
let page = PDFPage()
doc.insert(page, at: 0)

// 1. 红色填充页面空间矩形 (60,80,120,80)
let s1 = ShapePageCoords(bounds: NSRect(x: 60, y: 80, width: 120, height: 80), forType: .stamp, withProperties: nil)
s1.color = .clear
page.addAnnotation(s1)

// 2. App 复刻形状：bounds=(140,240,140,100)（已外扩 pad=8），contentRect=(148,248,124,84)
let s2 = ShapeAppReplica(bounds: NSRect(x: 140, y: 240, width: 140, height: 100), forType: .stamp, withProperties: nil)
s2.contentRect = NSRect(x: 148, y: 248, width: 124, height: 84)
s2.color = .clear
page.addAnnotation(s2)

// 3. 文本复刻：黄底 + 旋转 90°，bounds=(380,300,120,60)
let t1 = TextAppReplica(bounds: NSRect(x: 380, y: 300, width: 120, height: 60), forType: .stamp, withProperties: nil)
t1.contents = "测试"
t1.font = .systemFont(ofSize: 24)
t1.fontColor = .black
t1.bgColor = NSColor(red: 1, green: 0.9, blue: 0.3, alpha: 1)
t1.textRotation = 90
t1.color = .clear
page.addAnnotation(t1)

// 3b. 文本无旋转对照 (380,80,120,60)
let t2 = TextAppReplica(bounds: NSRect(x: 380, y: 80, width: 120, height: 60), forType: .stamp, withProperties: nil)
t2.contents = "对照"
t2.font = .systemFont(ofSize: 24)
t2.fontColor = .black
t2.bgColor = NSColor(red: 1, green: 0.9, blue: 0.3, alpha: 1)
t2.color = .clear
page.addAnnotation(t2)

// 4. Ink lineWidth=8 + alpha 0.8 颜色
let inkRect = NSRect(x: 60, y: 480, width: 400, height: 60)
let ink = PDFAnnotationInk(bounds: inkRect, forType: .ink, withProperties: nil)
let p = NSBezierPath()
p.move(to: NSPoint(x: 10, y: 30))
p.line(to: NSPoint(x: 390, y: 30))
ink.add(p)
ink.color = NSColor.black.withAlphaComponent(0.8)
let b = PDFBorder(); b.lineWidth = 8
ink.border = b
page.addAnnotation(ink)

// 5. Ink lineWidth=1（默认对照）
let ink2Rect = NSRect(x: 60, y: 580, width: 400, height: 60)
let ink2 = PDFAnnotationInk(bounds: ink2Rect, forType: .ink, withProperties: nil)
let p2 = NSBezierPath()
p2.move(to: NSPoint(x: 10, y: 30))
p2.line(to: NSPoint(x: 390, y: 30))
ink2.add(p2)
ink2.color = .black
let b2 = PDFBorder(); b2.lineWidth = 1
ink2.border = b2
page.addAnnotation(ink2)

let pv = PDFView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
pv.document = doc
pv.autoScales = true
pv.layoutSubtreeIfNeeded()

let img = render(pv)
print("view bounds:", pv.bounds, "scale:", pv.scaleFactor)

// 全图扫描特征色包围盒（避免依赖页面定位计算）
func bbox(of rep: NSBitmapImageRep, match: (Int, Int, Int) -> Bool, name: String) {
    var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            let r = Int(c.redComponent * 255), g = Int(c.greenComponent * 255), b = Int(c.blueComponent * 255)
            if match(r, g, b) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    if maxX < 0 { print(name, "NOT FOUND") } else { print(name, "bbox x:\(minX)-\(maxX) y:\(minY)-\(maxY) 尺寸 \(maxX-minX+1)x\(maxY-minY+1)") }
}
let isRed = { (r: Int, g: Int, b: Int) in r > 180 && g < 90 && b < 90 }
let isYellow = { (r: Int, g: Int, b: Int) in r > 200 && g > 180 && b < 120 }

let imgRep = render(pv)
bbox(of: imgRep, match: isRed, name: "1+2 红色形状（页面空间fill + App复刻边框）")
bbox(of: imgRep, match: isYellow, name: "3+3b 黄底文本")

// 测 Ink 厚度：黑像素按 y 分布
func inkThickness(_ rep: NSBitmapImageRep) {
    var rows: [Int: [Int]] = [:]
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            if c.redComponent < 0.3 && c.greenComponent < 0.3 && c.blueComponent < 0.3 {
                rows[x, default: []].append(y)
            }
        }
    }
    let ys = rows.values.flatMap { $0 }.sorted()
    guard let minY = ys.min(), let maxY = ys.max() else { print("无黑像素"); return }
    print("黑像素 y 范围:", minY, "-", maxY)
    // 两条线：y 小=lw1，y 大=lw8；各取中段某列的连续段长
    for (label, yTarget) in [("上线 lw=1", (minY + (minY + maxY) / 2) / 2), ("下线 lw=8", (minY + maxY) / 2 + (maxY - (minY + maxY) / 2) / 2)] {
        var best = 0
        for (_, seg) in rows {
            let s = seg.sorted()
            var cur = 0
            for i in 0..<s.count {
                if i > 0 && s[i] - s[i - 1] <= 1 { cur += 1 } else { cur = 1 }
                if abs((s[i] - cur / 2) - yTarget) < 25 { best = max(best, cur) }
            }
        }
        print(label, "最大连续厚度:", best)
    }
}
inkThickness(imgRep)

// 保存重读再渲染（验证外观流在 PDFView 重读后仍可见）
let doc2 = PDFDocument(data: doc.dataRepresentation() ?? Data())!
pv.document = doc2
pv.layoutSubtreeIfNeeded()
let rep2 = render(pv)
bbox(of: rep2, match: isRed, name: "重读后 红色形状")
bbox(of: rep2, match: isYellow, name: "重读后 黄底文本")
