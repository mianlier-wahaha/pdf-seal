import Foundation
import CoreGraphics

/// 骑缝章缝位
public enum SeamEdge: String, Codable, CaseIterable, Identifiable {
    case right, left
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .right: return "右缝"
        case .left: return "左缝"
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
    /// sizeRatio 语义：右/左缝 = 章高占页高比例
    public var sizeRatio: CGFloat = 0.15
    /// 沿缝方向偏移（归一化，正值向页心方向）
    public var offset: CGFloat = 0
    /// 是否让首页占比更大
    public var firstPageLarger: Bool = false
    /// 首页占总章图的比例（仅 firstPageLarger 为 true 时生效）
    public var firstPageRatio: CGFloat = 0.25
    /// 是否单独控制内页占比（仅 firstPageLarger 为 true 时生效）
    /// - true：中间页各占 middleRatio，尾页取剩余到整数边界
    /// - false：首尾页各占 firstPageRatio，中间页均分剩余 1-2*firstPageRatio
    public var middleRatioEnabled: Bool = true
    /// 中间页（首尾之外）每页占总章图的比例（firstPageLarger=true 且 middleRatioEnabled=true 时生效）
    public var middleRatio: CGFloat = 0.05
    /// 内页→尾页章条朝页心一侧边缘的渐变带宽（物理毫米，0 = 关闭）。
    /// 纸厚仿真：边缘浅、向内渐深，避免生硬直线边界。
    public var fadeWidthMm: CGFloat = 0.05
    /// 渐变带最边缘的深度系数（0.9 = 边缘为章深的 90%）
    public var fadeEdgeAlpha: CGFloat = 0.9
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
    /// 骑缝章：整章按页数切分为 N 条，第 i 页贴第 i 条（左/右缝纵向切）。
    /// - 默认：各页均分（每页 1/n）。
    /// - 开启 firstPageLarger：
    ///   - middleRatioEnabled=true：首页占 firstPageRatio，中间页各占 middleRatio，尾页从累积
    ///     位置取到下一个整数边界（本份印章最右缘）。
    ///   - middleRatioEnabled=false：首尾页各占 firstPageRatio，中间页均分剩余部分。
    ///   跨边界的条自动 wrap 拆成多片拼接，dest 始终贴在边缘缝、不溢出页面。
    /// - 纸厚仿真：内页→尾页章条朝页心一侧的边缘带 fadeWidthMm 渐变（边缘深度
    ///   fadeEdgeAlpha×opacity 线性过渡到 opacity），模拟纸张厚度造成的由浅入深。
    public static func qifeng(config: QifengConfig, pageSizes: [CGSize],
                              sealAspect: CGFloat, opacity: CGFloat) -> [StampPlacement] {
        let lo = max(0, config.range.lowerBound)
        let hi = min(pageSizes.count - 1, config.range.upperBound)
        guard hi >= lo else { return [] }
        let count = hi - lo + 1

        // 每 slice 的权重与源图起始位置（沿缝方向连续累积，0..total 份）
        let (weights, srcStarts): ([CGFloat], [CGFloat]) = {
            guard config.firstPageLarger, count >= 2 else {
                let w = Array(repeating: 1 / CGFloat(count), count: count)
                return (w, Array(stride(from: 0, through: 1 - 1 / CGFloat(count), by: 1 / CGFloat(count))))
            }
            var w = [CGFloat](repeating: 0, count: count)
            var starts = [CGFloat](repeating: 0, count: count)
            w[0] = config.firstPageRatio
            starts[0] = 0
            if config.middleRatioEnabled {
                // 模式 A：中间页固定 middleRatio，尾页取到整数边界
                for i in 1..<count - 1 {
                    w[i] = config.middleRatio
                    starts[i] = starts[i - 1] + w[i - 1]
                }
                let lastStart = starts[count - 2] + w[count - 2]
                var lastW = ceil(lastStart) - lastStart
                if lastW < 0.02 { lastW = 1.0 }   // 压边界/浮点误差：给完整一份
                w[count - 1] = lastW
                starts[count - 1] = lastStart
            } else {
                // 模式 B：首尾页各占 firstPageRatio，中间页均分剩余
                if count == 2 {
                    w[1] = 1 - config.firstPageRatio
                    starts[1] = config.firstPageRatio
                } else {
                    let avg = (1 - 2 * config.firstPageRatio) / CGFloat(count - 2)
                    for i in 1..<count - 1 {
                        w[i] = avg
                        starts[i] = starts[i - 1] + w[i - 1]
                    }
                    w[count - 1] = config.firstPageRatio
                    starts[count - 1] = starts[count - 2] + w[count - 2]
                }
            }
            return (w, starts)
        }()

        var out: [StampPlacement] = []
        for p in lo...hi {
            let s = pageSizes[p]
            let i = p - lo
            let sliceIndex = config.edge == .right ? i : (hi - lo) - i
            let weight = weights[sliceIndex]
            let srcStart = srcStarts[sliceIndex]
            // 该 slice 在章图 [0,1) 上的子段（跨整数边界拆成多片，destFrac 为其在 dest 条内的相对起点）
            let segs = sourceSegments(start: srcStart, weight: weight)
            let (w, h) = fitted(size: config.sizeRatio * s.height * sealAspect,
                                height: config.sizeRatio * s.height, page: s)
            let sliceW = w * weight
            let cy = s.height * 0.5 - config.offset * s.height
            // 尾页章条不贴页缘，向页心内移整章宽度的 1/3（贴近现实手工盖章位置）
            let inset: CGFloat = (p == hi) ? w / 3 : 0
            let x0 = config.edge == .right ? s.width - sliceW - inset : inset
            for seg in segs {
                let dx = x0 + seg.destFrac * w
                // dest 子段宽度 = 源图子段占比 × 整章目标宽度；偏移按整章目标宽累计
                let dw = seg.srcW * w
                let r = clampedRect(x: dx, y: cy - h / 2, w: dw, h: h, page: s)
                let src = CGRect(x: seg.srcX, y: 0, width: seg.srcW, height: 1)
                out.append(StampPlacement(pageIndex: p, destRect: r, pageW: s.width,
                                          pageH: s.height, source: src, rotation: 0, opacity: opacity))
            }
        }
        return out
    }

    /// 把沿缝方向的源区间 [start, start+weight] 映射到单张章图 [0,1) 上：
    /// 超过一份印章（start≥1 或跨整数边界）时自动 wrap，并拆成多个不跨边界的子段。
    /// - Returns: 每个子段的源起始（已 wrap 到 [0,1)）、源宽、以及其在 dest 条内的相对起点 (0..1)。
    private static func sourceSegments(start: CGFloat, weight: CGFloat) -> [(srcX: CGFloat, srcW: CGFloat, destFrac: CGFloat)] {
        guard weight > 0 else { return [] }
        var out: [(CGFloat, CGFloat, CGFloat)] = []
        var cursor = start
        var destCursor: CGFloat = 0
        let end = start + weight
        while cursor < end - 1e-9 {
            let unitEnd = floor(cursor) + 1
            let segEnd = min(unitEnd, end)
            let segLen = segEnd - cursor
            let srcX = cursor - floor(cursor)
            out.append((srcX, segLen, destCursor))
            destCursor += segLen
            cursor = segEnd
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
