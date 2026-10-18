// 应用图标生成：swift scripts/make_icon.swift
// mPDF —— 品牌红圆角底 + 衬线艺术字 m + 右上 PDF(转曲) + 左下立体印章(橙金)
// 产出：scripts/AppIcon_1024_generated.png  +  scripts/mpdf-icon.svg  +  分层 layer_*.svg（供画布导入）
import AppKit
import CoreGraphics
import CoreText

let side: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(side), height: Int(side),
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func hexColor(_ s: String) -> CGColor {
    var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
    return CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

let redHex = "E01E1E"
let white = hexColor("FFFFFF")
let cRim = hexColor("C87A20"), cFace = hexColor("F2A94E"),
    cBody = hexColor("EC9A3E"), cKnob = hexColor("F6B45E"), cHi = hexColor("FCD79C")

// ---- 背景：品牌红圆角方形（统一半径，扁平）----
let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side),
                    cornerWidth: 230, cornerHeight: 230, transform: nil)
ctx.setFillColor(hexColor(redHex))
ctx.addPath(bgPath); ctx.fillPath()

// ---- 文字转曲：CoreText 取字形轮廓 ----
func textPath(_ text: String, font: CTFont, kern: CGFloat) -> CGMutablePath {
    let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTKernAttributeName: kern]
    let attr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attr)
    let path = CGMutablePath()
    let runs = CTLineGetGlyphRuns(line) as NSArray
    for rr in runs {
        let run = rr as! CTRun
        let n = CTRunGetGlyphCount(run)
        if n == 0 { continue }
        var glyphs = [CGGlyph](repeating: 0, count: n)
        var pos = [CGPoint](repeating: .zero, count: n)
        CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
        for i in 0..<n {
            if let gp = CTFontCreatePathForGlyph(font, glyphs[i], nil) {
                path.addPath(gp, transform: CGAffineTransform(translationX: pos[i].x, y: pos[i].y))
            }
        }
    }
    return path
}

// 衬线艺术字 m（Georgia Bold），居中略偏右
let serifBase = CTFontCreateWithName("Georgia" as CFString, 660, nil)
let mFont = CTFontCreateCopyWithSymbolicTraits(serifBase, 660, nil, .boldTrait, .boldTrait) ?? serifBase
let mGlyph = textPath("m", font: mFont, kern: 0)
let mBB = mGlyph.boundingBoxOfPath
let mPath = CGMutablePath()
mPath.addPath(mGlyph, transform: CGAffineTransform(translationX: 520 - mBB.midX, y: 490 - mBB.midY))

// PDF（Helvetica Bold，右上）
let pdfFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 150, nil)
let pdfGlyph = textPath("PDF", font: pdfFont, kern: -3)
let pdfBB = pdfGlyph.boundingBoxOfPath
let pdfPath = CGMutablePath()
pdfPath.addPath(pdfGlyph, transform: CGAffineTransform(translationX: side - 62 - pdfBB.maxX, y: 772))

// ---- 左下立体印章（橙金）：底盘 + 握柄 + 圆头 ----
func ellipsePath(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2), transform: nil)
}
let stampRim  = ellipsePath(280, 124, 120, 44)   // 底盘下沿（深）
let stampFace = ellipsePath(280, 148, 120, 44)   // 底盘顶面（亮）
let stampBody = CGMutablePath()                     // 握柄（收腰）
stampBody.move(to: CGPoint(x: 206, y: 150))
stampBody.addCurve(to: CGPoint(x: 252, y: 254), control1: CGPoint(x: 210, y: 200), control2: CGPoint(x: 244, y: 232))
stampBody.addLine(to: CGPoint(x: 252, y: 302))
stampBody.addLine(to: CGPoint(x: 308, y: 302))
stampBody.addLine(to: CGPoint(x: 308, y: 254))
stampBody.addCurve(to: CGPoint(x: 354, y: 150), control1: CGPoint(x: 316, y: 232), control2: CGPoint(x: 350, y: 200))
stampBody.closeSubpath()
let stampKnob = ellipsePath(280, 326, 34, 40)    // 圆头
let stampHi   = ellipsePath(268, 338, 9, 13)     // 高光

// ---- 落到位图（顺序：m → PDF → 印章，印章在最前）----
ctx.setFillColor(white)
ctx.addPath(mPath); ctx.fillPath()
ctx.addPath(pdfPath); ctx.fillPath()

ctx.setFillColor(cRim);  ctx.addPath(stampRim);  ctx.fillPath()
ctx.setFillColor(cFace); ctx.addPath(stampFace); ctx.fillPath()
ctx.setFillColor(cBody); ctx.addPath(stampBody); ctx.fillPath()
ctx.setFillColor(cKnob); ctx.addPath(stampKnob); ctx.fillPath()
ctx.setFillColor(cHi);   ctx.addPath(stampHi);   ctx.fillPath()

// ---- 输出路径（绝对，基于脚本位置）----
let scriptDir = NSString(string: #file).deletingLastPathComponent
let pngURL = URL(fileURLWithPath: scriptDir).appendingPathComponent("AppIcon_1024_generated.png")
let svgURL = URL(fileURLWithPath: scriptDir).appendingPathComponent("mpdf-icon.svg")

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: pngURL)

// ---- CGPath -> SVG path d（直接把 y 翻转为 SVG 坐标，不再用 transform 分组）----
func svgD(_ path: CGPath) -> String {
    func fy(_ y: CGFloat) -> CGFloat { side - y }
    var s = ""
    path.applyWithBlock { ptr in
        let e = ptr.pointee; let p = e.points
        switch e.type {
        case .moveToPoint:        s += String(format: "M%.1f %.1f ", p[0].x, fy(p[0].y))
        case .addLineToPoint:     s += String(format: "L%.1f %.1f ", p[0].x, fy(p[0].y))
        case .addQuadCurveToPoint:s += String(format: "Q%.1f %.1f %.1f %.1f ", p[0].x, fy(p[0].y), p[1].x, fy(p[1].y))
        case .addCurveToPoint:    s += String(format: "C%.1f %.1f %.1f %.1f %.1f %.1f ", p[0].x, fy(p[0].y), p[1].x, fy(p[1].y), p[2].x, fy(p[2].y))
        case .closeSubpath:       s += "Z "
        @unknown default: break
        }
    }
    return s
}

let dM = svgD(mPath), dPDF = svgD(pdfPath)
let dRim = svgD(stampRim), dFace = svgD(stampFace), dBody = svgD(stampBody),
    dKnob = svgD(stampKnob), dHi = svgD(stampHi)

// 印章分组（多层上色）
let stampGroup = """
    <path d="\(dRim)" fill="#C87A20"/>
    <path d="\(dFace)" fill="#F2A94E"/>
    <path d="\(dBody)" fill="#EC9A3E"/>
    <path d="\(dKnob)" fill="#F6B45E"/>
    <path d="\(dHi)" fill="#FCD79C"/>
"""

// ---- 完整矢量源 ----
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <rect x="0" y="0" width="1024" height="1024" rx="230" ry="230" fill="#\(redHex)"/>
  <path d="\(dM)" fill="#FFFFFF"/>
  <path d="\(dPDF)" fill="#FFFFFF"/>
\(stampGroup)
</svg>
"""
try! svg.write(to: svgURL, atomically: true, encoding: .utf8)

// ---- 分层 SVG（供画布逐层导入/可单独隐藏 PDF）----
func layerSVG(_ inner: String) -> String {
    let head = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">\n"
    let tail = "\n</svg>\n"
    return head + inner + tail
}
try! layerSVG("    <path d=\"\(dM)\" fill=\"#FFFFFF\"/>").write(to: URL(fileURLWithPath: scriptDir).appendingPathComponent("layer_m.svg"), atomically: true, encoding: .utf8)
try! layerSVG("    <path d=\"\(dPDF)\" fill=\"#FFFFFF\"/>").write(to: URL(fileURLWithPath: scriptDir).appendingPathComponent("layer_pdf.svg"), atomically: true, encoding: .utf8)
try! layerSVG(stampGroup).write(to: URL(fileURLWithPath: scriptDir).appendingPathComponent("layer_stamp.svg"), atomically: true, encoding: .utf8)

print("done -> \(pngURL.path)")
print("m bbox: \(mBB)")
