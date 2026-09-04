import SwiftUI
import CoreGraphics
import SealCore

/// 模拟拼合校验：把当前骑缝参数下各页的章条按印章图原始位置拼回完整章
struct JigsawView: View {
    @EnvironmentObject private var doc: DocumentStore
    @EnvironmentObject private var seals: SealStore
    @EnvironmentObject private var settings: StampSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text(L("模拟拼合校验"))
                .font(.headline)
            Text(L("把每页边缘的章条按页序拼合，应能还原出右侧的完整印章"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 28) {
                combinedAndOriginal
                original
            }
            .frame(maxHeight: .infinity)
            if !settings.allPages {
                Text(LF("当前页范围：第 %d — %d 页（共 %d 条）", settings.rangeStart, settings.rangeEnd, settings.rangeEnd - settings.rangeStart + 1))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(L("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 640, height: 460)
    }

    private var combinedAndOriginal: some View {
        VStack(spacing: 6) {
            if let img = combinedImage() {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 280)
                    .background(checker)
            } else {
                Text(L("请先选择印章")).foregroundStyle(.secondary)
                    .frame(height: 280)
            }
            Text(L("拼合结果")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var original: some View {
        VStack(spacing: 6) {
            if let img = seals.image(for: seals.selectedID) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 280)
                    .opacity(0.85)
            } else {
                Color.clear.frame(height: 280)
            }
            Text(L("原始印章")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var checker: some View {
        Rectangle()
            .fill(Color.white)
            .overlay {
                Rectangle().strokeBorder(.separator)
            }
    }

    private func combinedImage() -> NSImage? {
        guard doc.pageCount > 0,
              let sealCG = seals.cgImage(for: seals.selectedID) else { return nil }
        let aspect = seals.aspect(for: seals.selectedID)
        let cfg = settings.qifengConfig(pageCount: doc.pageCount)
        let pls = StampGeometry.qifeng(config: cfg, pageSizes: doc.pageSizes,
                                       sealAspect: aspect, opacity: 1)
        guard !pls.isEmpty else { return nil }

        let W = 520.0
        let H = W / aspect
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(W), pixelsHigh: Int(H),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        for pl in pls {
            let crop = CGRect(x: pl.source.minX * CGFloat(sealCG.width),
                              y: pl.source.minY * CGFloat(sealCG.height),
                              width: pl.source.width * CGFloat(sealCG.width),
                              height: pl.source.height * CGFloat(sealCG.height))
            guard let img = sealCG.cropping(to: crop) else { continue }
            let dr = CGRect(x: pl.source.minX * W,
                            y: (1 - pl.source.maxY) * H,
                            width: pl.source.width * W,
                            height: pl.source.height * H)
            ctx.draw(img, in: dr)
        }
        guard let out = rep.cgImage else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: W, height: H))
    }
}
