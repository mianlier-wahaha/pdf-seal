import Foundation
import CoreGraphics

/// 骑缝章缝位
public enum SeamEdge: String, Codable, CaseIterable, Identifiable {
    case right, left, top, bottom
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .right: return "右缝"
        case .left: return "左缝"
        case .top: return "上缝"
        case .bottom: return "下缝"
        }
    }
}

/// 一次印章贴片：描述「印章图的哪一块」贴到「某一页的哪个位置」
public struct StampPlacement {
    /// 0-based 页码
    public var pageIndex: Int
    /// 目标矩形，单位 pt，坐标原点左下（CG 显示空间，已考虑页面旋转）
    public var destRect: CGRect
    /// 目标矩形的归一化形式，原点左上（预览用）
    public var destNorm: CGRect
    /// 印章图上的取块区域，归一化，原点左上
    public var source: CGRect
    /// 旋转角度（度，顺时针）
    public var rotation: CGFloat
    /// 不透明度 0...1
    public var opacity: CGFloat
    /// 所用章图标识（多章混盖时区分不同章图，对应导出方的 seals 字典键）
    public var sealKey: Int = 0

    public init(pageIndex: Int, destRect: CGRect, pageW: CGFloat, pageH: CGFloat,
                source: CGRect, rotation: CGFloat = 0, opacity: CGFloat = 0.9) {
        self.pageIndex = pageIndex
        self.destRect = destRect
        self.destNorm = CGRect(x: destRect.minX / pageW,
                               y: 1 - destRect.maxY / pageH,
                               width: destRect.width / pageW,
                               height: destRect.height / pageH)
        self.source = source
        self.rotation = rotation
        self.opacity = opacity
    }
}

/// 骑缝章参数
public struct QifengConfig {
    public var edge: SeamEdge = .right
    /// 0-based 闭区间页范围
    public var range: ClosedRange<Int> = 0...0
    /// sizeRatio 语义：右/左缝 = 章高占页高比例；上/下缝 = 章宽占页宽比例
    public var sizeRatio: CGFloat = 0.15
    /// 沿缝方向偏移（归一化，正值向页心方向）
    public var offset: CGFloat = 0
    public init() {}
}

/// 正文章参数
public struct FullStampConfig {
    /// 章中心归一化位置，原点左上
    public var anchor: CGPoint = CGPoint(x: 0.75, y: 0.85)
    /// 章高占页高比例
    public var sizeRatio: CGFloat = 0.18
    public var rotation: CGFloat = 0
    /// 0-based 闭区间页范围
    public var range: ClosedRange<Int> = 0...0
    public init() {}
}

public enum StampGeometry {
    /// 骑缝章：整章按页数均分为 N 条，第 i 页贴第 i 条（左右缝纵向切，上下缝横向切）
    public static func qifeng(config: QifengConfig, pageSizes: [CGSize],
                              sealAspect: CGFloat, opacity: CGFloat) -> [StampPlacement] {
        let lo = max(0, config.range.lowerBound)
        let hi = min(pageSizes.count - 1, config.range.upperBound)
        guard hi >= lo else { return [] }
        let n = CGFloat(hi - lo + 1)
        var out: [StampPlacement] = []
        for p in lo...hi {
            let s = pageSizes[p]
            let i = p - lo
            let sliceIndex: Int
            switch config.edge {
            case .right, .top: sliceIndex = i
            case .left, .bottom: sliceIndex = (hi - lo) - i
            }
            let sn = CGFloat(sliceIndex)
            if config.edge == .right || config.edge == .left {
                var (w, h) = fitted(size: config.sizeRatio * s.height * sealAspect,
                                    height: config.sizeRatio * s.height, page: s)
                let sliceW = w / n
                let cy = s.height * 0.5 - config.offset * s.height
                let x = config.edge == .right ? s.width - sliceW : 0
                let r = clampedRect(x: x, y: cy - h / 2, w: sliceW, h: h, page: s)
                let src = CGRect(x: sn / n, y: 0, width: 1 / n, height: 1)
                out.append(StampPlacement(pageIndex: p, destRect: r, pageW: s.width,
                                          pageH: s.height, source: src, rotation: 0, opacity: opacity))
            } else {
                var (w, h) = fitted(size: config.sizeRatio * s.width,
                                    height: config.sizeRatio * s.width / sealAspect, page: s)
                let sliceH = h / n
                let cx = s.width * 0.5 + config.offset * s.width
                let y = config.edge == .top ? s.height - sliceH : 0
                let r = clampedRect(x: cx - w / 2, y: y, w: w, h: sliceH, page: s)
                let src = CGRect(x: 0, y: sn / n, width: 1, height: 1 / n)
                out.append(StampPlacement(pageIndex: p, destRect: r, pageW: s.width,
                                          pageH: s.height, source: src, rotation: 0, opacity: opacity))
            }
        }
        return out
    }

    /// 正文章：完整章按锚点定位，可应用页范围
    public static func full(config: FullStampConfig, pageSizes: [CGSize],
                            sealAspect: CGFloat, opacity: CGFloat) -> [StampPlacement] {
        let lo = max(0, config.range.lowerBound)
        let hi = min(pageSizes.count - 1, config.range.upperBound)
        guard hi >= lo else { return [] }
        var out: [StampPlacement] = []
        for p in lo...hi {
            let s = pageSizes[p]
            let (w, h) = fitted(size: config.sizeRatio * s.height * sealAspect,
                                height: config.sizeRatio * s.height, page: s)
            let cx = config.anchor.x * s.width
            let cy = (1 - config.anchor.y) * s.height
            let r = clampedRect(x: cx - w / 2, y: cy - h / 2, w: w, h: h, page: s)
            let src = CGRect(x: 0, y: 0, width: 1, height: 1)
            out.append(StampPlacement(pageIndex: p, destRect: r, pageW: s.width,
                                      pageH: s.height, source: src,
                                      rotation: config.rotation, opacity: opacity))
        }
        return out
    }

    /// 章超出页面时等比缩小
    private static func fitted(size w: CGFloat, height h: CGFloat, page: CGSize) -> (CGFloat, CGFloat) {
        var ww = w, hh = h
        let maxW = page.width * 0.98, maxH = page.height * 0.98
        if ww > maxW { let k = maxW / ww; ww *= k; hh *= k }
        if hh > maxH { let k = maxH / hh; ww *= k; hh *= k }
        return (ww, hh)
    }

    private static func clampedRect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                                    page: CGSize) -> CGRect {
        let xx = min(max(x, 0), max(0, page.width - w))
        let yy = min(max(y, 0), max(0, page.height - h))
        return CGRect(x: xx, y: yy, width: min(w, page.width), height: min(h, page.height))
    }
}
