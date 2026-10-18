import AppKit
import QuartzCore

/// macOS 27 PDFKit 注记马赛克修复（上游 FB24882188 / FB24843022）。
///
/// 症状：macOS 27 起，PDFView 中的批注（图形/墨迹/文本/表单控件）显示为低分辨率马赛克，
/// 放大越明显；Preview.app 不受影响。根因：PDFKit 把注记渲染进私有层
/// `PDFPageLayerAnnotationEffect`，该层 contentsScale 恒为 1.0、magnificationFilter = nearest，
/// 而旁边画页面内容的 tile 层用真实屏幕密度 + linear——注记被 1px/pt 栅格化后最近邻拉伸。
///
/// 修法：在该私有类的 -display 前把 contentsScale 纠正为真实屏幕密度（含缩放）、滤镜改 linear。
/// PDFKit 每次重绘会重置层属性，所以必须挂在 -display 上每次纠正。
/// 仅替换该私有子类的方法（不动 CALayer 本身）；私有类不存在（系统已修复/改名）时静默跳过。
enum PDFKitAnnotationQualityFix {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        guard let cls = NSClassFromString("PDFPageLayerAnnotationEffect"),
              let method = class_getInstanceMethod(cls, #selector(CALayer.display)) else { return }
        typealias DisplayFn = @convention(c) (CALayer, Selector) -> Void
        let original = method_getImplementation(method)
        let block: @convention(block) (CALayer) -> Void = { layer in
            if Thread.isMainThread {
                correctScale(of: layer)
            }
            unsafeBitCast(original, to: DisplayFn.self)(layer, #selector(CALayer.display))
        }
        class_replaceMethod(cls, #selector(CALayer.display),
                            imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }

    /// 给该层真实屏幕密度（屏幕 backing scale × 层在窗口中的合成放大倍数）与线性采样
    private static func correctScale(of layer: CALayer) {
        guard let window = hostWindow(of: layer) else { return }
        let bounds = layer.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let baseScale = window.screen?.backingScaleFactor ?? window.backingScaleFactor
        guard baseScale > 0 else { return }
        // 层在窗口中可能被放大（PDFView 缩放）：换算合成倍数
        var magnification: CGFloat = 1
        if let rootLayer = window.contentView?.layer {
            let inWindow = layer.convert(bounds, to: rootLayer)
            if inWindow.width > 0, inWindow.height > 0 {
                magnification = sqrt((inWindow.width * inWindow.height) / (bounds.width * bounds.height))
            }
        }
        let scale = magnification * baseScale
        guard scale.isFinite, scale > 0 else { return }
        layer.contentsScale = scale
        layer.magnificationFilter = .linear
    }

    /// 沿层树向上找宿主 NSView 的窗口
    private static func hostWindow(of layer: CALayer) -> NSWindow? {
        var current: CALayer? = layer.superlayer
        while let l = current {
            if let view = l.delegate as? NSView, let window = view.window {
                return window
            }
            current = l.superlayer
        }
        return nil
    }
}
