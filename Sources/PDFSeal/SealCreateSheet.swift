import SwiftUI
import CoreGraphics
import AppKit

/// 待创建的章图（从文件选择器读入内存）
struct PendingImport: Identifiable {
    let id = UUID()
    let image: NSImage
    let suggestedName: String
}

/// 新建图章 Sheet 的状态（ObservableObject 避免 escaping 闭包里 self 不可变）
private final class SealCreateState: ObservableObject {
    @Published var name: String
    @Published var whiteToTransparent = true
    @Published var tolerance: Double = 35
    @Published var widthCm: Double = 4.0
    @Published var heightCm: Double = 4.0
    @Published var lockAspect = true
    @Published var imageAspect: Double = 1
    @Published var processed: CGImage?
    @Published var baseCG: CGImage?
    @Published var processing = false

    init(suggestedName: String) {
        name = suggestedName
    }

    func clampSize() {
        widthCm = min(max(widthCm, 1), 20)
        heightCm = min(max(heightCm, 1), 20)
    }

    func syncAspect(fromWidth: Bool) {
        guard lockAspect, imageAspect > 0 else { return }
        if fromWidth {
            heightCm = min(max(widthCm / imageAspect, 1), 20)
            widthCm = min(max(heightCm * imageAspect, 1), 20)
        } else {
            widthCm = min(max(heightCm * imageAspect, 1), 20)
            heightCm = min(max(widthCm / imageAspect, 1), 20)
        }
    }
}

/// 新建图章对话框：透明化背景 + 容错阈值实时预览 + 取消/创建
struct SealCreateSheet: View {
    @EnvironmentObject private var seals: SealStore
    @EnvironmentObject private var settings: StampSettings
    @EnvironmentObject private var doc: DocumentStore
    let pending: PendingImport
    let onFinished: () -> Void
    @StateObject private var state: SealCreateState

    init(pending: PendingImport, onFinished: @escaping () -> Void) {
        self.pending = pending
        self.onFinished = onFinished
        _state = StateObject(wrappedValue: SealCreateState(suggestedName: pending.suggestedName))
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(L("新建图章")).font(.headline)

            // 预览区：透明部分显示棋盘格
            ZStack {
                if state.whiteToTransparent {
                    Checkerboard()
                } else {
                    Rectangle().fill(Color.white)
                }
                if state.processing {
                    ProgressView()
                } else if let cg = state.processed {
                    Image(cg, scale: 1, label: Text(L("章预览")))
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 350, maxHeight: 380)
            .overlay {
                Rectangle().strokeBorder(.separator)
            }

            HStack(spacing: 14) {
                Toggle(L("白色转成透明"), isOn: $state.whiteToTransparent)
                Spacer()
                Text(L("尺寸(cm)")).font(.callout)
                TextField("宽", value: $state.widthCm, format: .number.precision(.fractionLength(0...1)))
                    .multilineTextAlignment(.center)
                    .frame(width: 54)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { state.clampSize() }
                    .onChange(of: state.widthCm) { _ in state.syncAspect(fromWidth: true) }
                Text("×").foregroundStyle(.secondary)
                TextField("高", value: $state.heightCm, format: .number.precision(.fractionLength(0...1)))
                    .multilineTextAlignment(.center)
                    .frame(width: 54)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { state.clampSize() }
                    .onChange(of: state.heightCm) { _ in state.syncAspect(fromWidth: false) }
                Toggle(L("锁定比例"), isOn: $state.lockAspect)
                    .font(.caption)
                    .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 4)

            HStack(spacing: 10) {
                Text(L("容错")).font(.callout)
                    .padding(.leading, 4)
                Slider(value: $state.tolerance, in: 0...100)
                    .disabled(!state.whiteToTransparent)
                Text("\(Int(state.tolerance))").monospacedDigit()
                    .frame(width: 32)
                    .foregroundStyle(state.whiteToTransparent ? .primary : .secondary)
            }

            HStack {
                Text(L("名称")).font(.callout)
                TextField(L("印章名称"), text: $state.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
            }

            HStack {
                Spacer()
                Button(L("取消"), role: .cancel) { onFinished() }
                    .keyboardShortcut(.cancelAction)
                Button(L("创建")) { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(state.name.trimmingCharacters(in: .whitespaces).isEmpty || state.processing)
            }
        }
        .padding(18)
        .frame(width: 640)
        .task {
            state.baseCG = pending.image.cgImage(forProposedRect: nil, context: nil, hints: nil)?
                .normalizedRGBA()
            if let b = state.baseCG, b.height > 0 {
                state.imageAspect = Double(b.width) / Double(b.height)
            }
            // 按图片元数据计算真实物理尺寸（cm）
            let (w, h) = Self.realWorldCm(of: pending.image)
            state.widthCm = min(max(w, 1), 20)
            state.heightCm = min(max(h, 1), 20)
            // 保证与底图比例一致
            if state.lockAspect, state.imageAspect > 0 {
                state.heightCm = min(max(state.widthCm / state.imageAspect, 1), 20)
                state.widthCm = min(max(state.heightCm * state.imageAspect, 1), 20)
            }
            await reprocess()
        }
        .task(id: state.whiteToTransparent) { await reprocess() }
        .task(id: state.tolerance) { await reprocess() }
    }

    /// 按图片的 DPI 元数据换算真实物理尺寸（cm）；
    /// 无有效 DPI 信息（size≈像素数）时按 300 DPI（常规扫描精度）估算
    nonisolated static func realWorldCm(of image: NSImage) -> (widthCm: Double, heightCm: Double) {
        guard let rep = image.representations.first else { return (4, 4) }
        let pw = Double(rep.pixelsWide), ph = Double(rep.pixelsHigh)
        let sw = Double(image.size.width), sh = Double(image.size.height)
        // NSImage.size = 像素 / DPI × 72；若与像素数几乎相等，说明 DPI 缺失（被当作 72 处理）
        if abs(sw - pw) > 0.5, abs(sh - ph) > 0.5,
           (1...60).contains(sw / 72 * 2.54), (1...60).contains(sh / 72 * 2.54) {
            return (sw / 72 * 2.54, sh / 72 * 2.54)
        }
        return (pw / 300 * 2.54, ph / 300 * 2.54)
    }

    /// 防抖后重新处理预览图
    private func reprocess() async {
        guard let base = state.baseCG else { return }
        state.processing = true
        try? await Task.sleep(nanoseconds: 120_000_000)
        if Task.isCancelled { return }
        let tol = state.tolerance
        let useTransparent = state.whiteToTransparent
        let result = await Task.detached(priority: .userInitiated) {
            useTransparent ? Self.makeTransparent(cg: base, tolerance: tol) : base
        }.value
        if Task.isCancelled { return }
        state.processed = result
        state.processing = false
    }

    private func create() {
        guard let cg = state.processed ?? state.baseCG else { onFinished(); return }
        state.clampSize()
        let finalName = state.name.trimmingCharacters(in: .whitespaces)
        seals.addProcessedSeal(name: finalName.isEmpty ? L("印章") : finalName, cgImage: cg)
        // 创建时固化该章的默认物理尺寸（cm），并立即套用到当前会话
        seals.fixPhysicalSize(widthCm: state.widthCm, heightCm: state.heightCm, for: seals.selectedID)
        settings.applySealPhysicalSize(widthCm: state.widthCm, heightCm: state.heightCm,
                                       pageHeightPt: doc.pageSizes.first?.height)
        onFinished()
    }

    // MARK: 白色转透明

    /// whiteness = (min(r,g,b) + (255-(max-min))) / 2，高于阈值的像素按渐变带变透明
    nonisolated static func makeTransparent(cg: CGImage, tolerance: Double) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height,
                                  bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let buf = ctx.data else { return nil }
        let p = buf.bindMemory(to: UInt8.self, capacity: cg.width * cg.height * 4)
        let count = cg.width * cg.height * 4
        let threshold = 150.0 + tolerance   // 150...250
        let fade = 45.0
        for i in stride(from: 0, to: count, by: 4) {
            let r = Double(p[i]), g = Double(p[i + 1]), b = Double(p[i + 2])
            let mn = min(r, g, b), mx = max(r, g, b)
            let whiteness = (mn + (255.0 - (mx - mn))) / 2
            let alpha = max(0, min(255, ((threshold - whiteness) / fade * 255)))
            p[i + 3] = UInt8(alpha)
        }
        return ctx.makeImage()
    }
}

/// 棋盘格背景（表示透明区域）
struct Checkerboard: View {
    var cell: CGFloat = 10
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, size in
            let cols = Int(ceil(size.width / cell)), rows = Int(ceil(size.height / cell))
            let light: Double = scheme == .dark ? 0.28 : 0.82
            for row in 0..<rows {
                for col in 0..<cols where (row + col) % 2 == 0 {
                    let rect = CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell,
                                      width: cell, height: cell)
                    ctx.fill(Path(rect), with: .color(Color(white: light)))
                }
            }
        }
        .background(Color(white: scheme == .dark ? 0.18 : 0.94))
    }
}

extension CGImage {
    /// 统一转为 8bit RGBA（保证像素操作稳定）
    func normalizedRGBA() -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
