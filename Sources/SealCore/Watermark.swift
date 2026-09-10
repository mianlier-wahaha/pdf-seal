import Foundation
import CoreGraphics
import CoreText

// MARK: - 文本水印

/// 文本水印配置（物理单位：字号 pt、偏移 mm）。
/// 与「章」的逐对象模型完全独立：水印是文档级绘制层，不参与选中/拖拽/撤销。
public struct WatermarkConfig: Equatable {
    public enum Mode: Equatable {
        case single      // 单行
        case twoRows     // 一页两行
        case tiled       // 平铺多枚
    }

    public enum Align: String, CaseIterable {
        case start, center, end
    }

    public var text: String
    public var fontPS: String          // PostScript 名（App 层解析好再传入）
    public var fontSize: CGFloat       // pt
    public var red: Double
    public var green: Double
    public var blue: Double
    public var rotation: CGFloat       // 度，逆时针
    public var opacity: Double         // 0...1
    public var mode: Mode
    public var hAlign: Align
    public var vAlign: Align
    public var offsetXmm: Double       // 相对基准点的水平偏移
    public var offsetYmm: Double       // 相对基准点的垂直偏移

    public init(text: String = "",
                fontPS: String = "PingFangSC-Regular",
                fontSize: CGFloat = 48,
                red: Double = 0.55, green: Double = 0.55, blue: Double = 0.55,
                rotation: CGFloat = 45,
                opacity: Double = 0.08,
                mode: Mode = .single,
                hAlign: Align = .center,
                vAlign: Align = .center,
                offsetXmm: Double = 0,
                offsetYmm: Double = 0) {
        self.text = text
        self.fontPS = fontPS
        self.fontSize = fontSize
        self.red = red
        self.green = green
        self.blue = blue
        self.rotation = rotation
        self.opacity = opacity
        self.mode = mode
        self.hAlign = hAlign
        self.vAlign = vAlign
        self.offsetXmm = offsetXmm
        self.offsetYmm = offsetYmm
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || opacity <= 0 }
}

/// 水印绘制引擎：导出与预览共用，保证所见即所得。
/// 坐标系 = PDF 显示空间（原点左下、y 向上），pageSize 为显示尺寸（pt）。
public enum WatermarkRenderer {
    static let mmToPt: CGFloat = 72.0 / 25.4
    /// 平铺拷贝数上限（防极端小字号导致巨量绘制）
    static let maxCopies = 80

    /// 在 ctx（显示空间）上绘制水印。ctx 需已处于页面显示坐标系。
    public static func draw(_ c: WatermarkConfig, in ctx: CGContext, pageSize: CGSize) {
        guard !c.isEmpty, pageSize.width > 1, pageSize.height > 1 else { return }
        let font = CTFontCreateWithName(c.fontPS as CFString, c.fontSize, nil)
        let color = CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
        let attr = NSAttributedString(string: c.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let textW = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let textH = CTFontGetAscent(font) + CTFontGetDescent(font)
        let descent = CTFontGetDescent(font)

        for p in copyPositions(c, pageSize: pageSize, textW: textW, textH: textH) {
            ctx.saveGState()
            ctx.translateBy(x: p.x, y: p.y)
            ctx.rotate(by: c.rotation * .pi / 180)
            ctx.setAlpha(CGFloat(c.opacity))
            // 文本几何中心对准原点：基线 y = -(textH/2 - descent)
            ctx.textPosition = CGPoint(x: -textW / 2, y: -(textH / 2 - descent))
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    /// 计算所有水印拷贝的中心点位置
    static func copyPositions(_ c: WatermarkConfig, pageSize: CGSize,
                              textW: CGFloat, textH: CGFloat) -> [CGPoint] {
        let base = basePoint(c, pageSize: pageSize)
        switch c.mode {
        case .single:
            return [base]
        case .twoRows:
            // 两行：沿垂直轴上下各错开页高的 18%
            let gap = pageSize.height * 0.18
            return [CGPoint(x: base.x, y: base.y + gap),
                    CGPoint(x: base.x, y: base.y - gap)]
        case .tiled:
            // 平铺：以页面中心对称铺满整页（含旋转后的对角余量），间距随字号/文本宽度自适应
            let diag = hypot(pageSize.width, pageSize.height)
            let colStep = max(textW + c.fontSize * 4, 120)
            let rowStep = max(textH + c.fontSize * 8, 150)
            var pts: [CGPoint] = []
            var y = -diag / 2
            while y <= diag / 2 {
                var x = -diag / 2
                while x <= diag / 2 {
                    let p = CGPoint(x: pageSize.width / 2 + x,
                                    y: pageSize.height / 2 + y)
                    // 只保留落在页内（留半字余量）的拷贝
                    if p.x > -textW / 2, p.x < pageSize.width + textW / 2,
                       p.y > -textH / 2, p.y < pageSize.height + textH / 2 {
                        pts.append(p)
                        if pts.count >= maxCopies { return pts }
                    }
                    x += colStep
                }
                y += rowStep
            }
            return pts.isEmpty ? [base] : pts
        }
    }

    /// 基准点：对齐预设（上/中/下 × 左/中/右）映射到页面比例点，再叠加毫米偏移
    static func basePoint(_ c: WatermarkConfig, pageSize: CGSize) -> CGPoint {
        let xFrac: CGFloat
        switch c.hAlign {
        case .start: xFrac = 0.2
        case .center: xFrac = 0.5
        case .end: xFrac = 0.8
        }
        let yFrac: CGFloat
        switch c.vAlign {
        case .start: yFrac = 0.8     // 上（PDF 坐标 y 向上，start=顶部 → y 大）
        case .center: yFrac = 0.5
        case .end: yFrac = 0.2
        }
        return CGPoint(x: pageSize.width * xFrac + CGFloat(c.offsetXmm) * mmToPt,
                       y: pageSize.height * yFrac + CGFloat(c.offsetYmm) * mmToPt)
    }
}
