// 应用图标生成：swift scripts/make_icon.swift
// 主题：纸张页面 + 骑缝红章切分
import AppKit
import CoreGraphics

let side: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(side), height: Int(side),
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

let red = CGColor(srgbRed: 0.82, green: 0.13, blue: 0.13, alpha: 1)

// 背景 squircle
let bg = CGRect(x: 0, y: 0, width: side, height: side)
ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.94, blue: 0.90, alpha: 1))
let bgPath = CGPath(roundedRect: bg.insetBy(dx: 8, dy: 8), cornerWidth: 230, cornerHeight: 230, transform: nil)
ctx.addPath(bgPath)
ctx.fillPath()

// 四张并排的纸（对应骑缝切分）
let pages = 4
let pw: CGFloat = 150, ph: CGFloat = 560, gap: CGFloat = 34
let totalW = CGFloat(pages) * pw + CGFloat(pages - 1) * gap
let x0 = (side - totalW) / 2 - 40
let y0 = (side - ph) / 2
for i in 0..<pages {
    let x = x0 + CGFloat(i) * (pw + gap)
    let r = CGRect(x: x, y: y0, width: pw, height: ph)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.setStrokeColor(CGColor(gray: 0.72, alpha: 1))
    ctx.setLineWidth(6)
    let path = CGPath(roundedRect: r, cornerWidth: 18, cornerHeight: 18, transform: nil)
    ctx.addPath(path)
    ctx.fillPath()
    ctx.addPath(path)
    ctx.strokePath()
    // 页面内容线条
    ctx.setStrokeColor(CGColor(gray: 0.82, alpha: 1))
    ctx.setLineWidth(8)
    for row in 1...5 {
        let ly = y0 + ph - 70 - CGFloat(row) * 80
        ctx.move(to: CGPoint(x: x + 26, y: ly))
        ctx.addLine(to: CGPoint(x: x + pw - 26, y: ly))
        ctx.strokePath()
    }
}

// 骑缝章：红章被切分，每页右边缘一竖条
let sealC = CGPoint(x: x0 + totalW - 40, y: side / 2 + 30)
let sealR: CGFloat = 190
for i in 0..<pages {
    let x = x0 + CGFloat(i) * (pw + gap)
    // 每页右边缘的切片窗口
    let wx = x + pw - 52
    ctx.saveGState()
    ctx.clip(to: CGRect(x: wx, y: sealC.y - sealR - 30, width: 52, height: sealR * 2 + 60))
    ctx.setStrokeColor(red)
    ctx.setFillColor(red)
    ctx.setLineWidth(22)
    ctx.strokeEllipse(in: CGRect(x: sealC.x - sealR, y: sealC.y - sealR, width: sealR * 2, height: sealR * 2))
    ctx.setLineWidth(8)
    ctx.strokeEllipse(in: CGRect(x: sealC.x - sealR * 0.8, y: sealC.y - sealR * 0.8, width: sealR * 1.6, height: sealR * 1.6))
    // 五角星
    let r1 = sealR * 0.42, r2 = sealR * 0.17
    let p = CGMutablePath()
    var up = true
    for k in 0..<10 {
        let ang = CGFloat(k) / 10 * 2 * .pi + .pi / 2
        let rr = up ? r1 : r2
        let pt = CGPoint(x: sealC.x + rr * cos(ang), y: sealC.y + rr * sin(ang))
        if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        up.toggle()
    }
    p.closeSubpath()
    ctx.addPath(p)
    ctx.fillPath()
    ctx.restoreGState()
}

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "scripts/AppIcon_1024.png"))
print("icon written")
