import SwiftUI
import CoreGraphics
import AppKit

/// 待创建的章图（从文件选择器读入内存）
struct PendingImport: Identifiable {
    let id = UUID()
    let image: NSImage
    let suggestedName: String
}

/// 新建图章对话框：透明化背景 + 容错阈值实时预览 + 取消/创建
struct SealCreateSheet: View {
    @EnvironmentObject private var seals: SealStore
    @EnvironmentObject private var settings: StampSettings
    @EnvironmentObject private var doc: DocumentStore
    let pending: PendingImport
    let onFinished: () -> Void

    @State private var name: String
    @State private var whiteToTransparent = true
    @State private var tolerance: Double = 35
    @State private var widthCm: Double = 4.0    // 章宽（cm）
    @State private var heightCm: Double = 4.0   // 章高（cm）
    @State private var lockAspect = true        // 锁定长宽比（默认开）
    @State private var imageAspect: Double = 1  // 底图宽高比
    @State private var processed: CGImage?
    @State private var baseCG: CGImage?
    @State private var processing = false

    init(pending: PendingImport, onFinished: @escaping () -> Void) {
        self.pending = pending
        self.onFinished = onFinished
        _name = State(initialValue: pending.suggestedName)
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(L("新建图章")).font(.headline)

            // 预览区：透明部分显示棋盘格
            ZStack {
                if whiteToTransparent {
                    Checkerboard()
                } else {
                    Rectangle().fill(Color.white)
                }
                if processing {
                    ProgressView()
                } else if let cg = processed {
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
                Toggle(L("白色转成透明"), isOn: $whiteToTransparent)
                Spacer()
                Text(L("尺寸(cm)")).font(.callout)
                TextField("宽", value: $widthCm, format: .number.precision(.fractionLength(0...1)))
                    .multilineTextAlignment(.center)
                    .frame(width: 54)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { clampSize() }
                    .onChange(of: widthCm) { _ in syncAspect(fromWidth: true) }
                Text("×").foregroundStyle(.secondary)
                TextField("高", value: $heightCm, format: .number.precision(.fractionLength(0...1)))
                    .multilineTextAlignment(.center)
                    .frame(width: 54)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { clampSize() }
                    .onChange(of: heightCm) { _ in syncAspect(fromWidth: false) }
                Toggle(L("锁定比例"), isOn: $lockAspect)
                    .font(.caption)
                    .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 4)

            HStack(spacing: 10) {
                Text(L("容错")).font(.callout)
                    .padding(.leading, 4)
                Slider(value: $tolerance, in: 0...100)
                    .disabled(!whiteToTransparent)
                Text("\(Int(tolerance))").monospacedDigit()
                    .frame(width: 32)
                    .foregroundStyle(whiteToTransparent ? .primary : .secondary)
            }

            HStack {
                Text(L("名称")).font(.callout)
                TextField(L("印章名称"), text: $name)
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
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || processing)
            }
        }
        .padding(18)
        .frame(width: 640)
        .task {
            baseCG = pending.image.cgImage(forProposedRect: nil, context: nil, hints: nil)?
                .normalizedRGBA()
            if let b = baseCG, b.height > 0 {
                imageAspect = Double(b.width) / Double(b.height)
            }
            await reprocess()
        }
        .task(id: whiteToTransparent) { await reprocess() }
        .task(id: tolerance) { await reprocess() }
    }

    /// 防抖后重新处理预览图
    private func reprocess() async {
        guard let base = baseCG else { return }
        processing = true
        try? await Task.sleep(nanoseconds: 120_000_000)
        if Task.isCancelled { return }
        let tol = tolerance
        let useTransparent = whiteToTransparent
        let result = await Task.detached(priority: .userInitiated) {
            useTransparent ? Self.makeTransparent(cg: base, tolerance: tol) : base
        }.value
        if Task.isCancelled { return }
        processed = result
        processing = false
    }

    private func create() {
        guard let cg = processed ?? baseCG else { onFinished(); return }
        clampSize()
        let finalName = name.trimmingCharacters(in: .whitespaces)
        seals.addProcessedSeal(name: finalName.isEmpty ? L("印章") : finalName, cgImage: cg)
        // 创建时固化该章的默认物理尺寸（cm），并立即套用到当前会话
        seals.fixPhysicalSize(widthCm: widthCm, heightCm: heightCm, for: seals.selectedID)
        settings.applySealPhysicalSize(widthCm: widthCm, heightCm: heightCm,
                                       pageHeightPt: doc.pageSizes.first?.height)
        onFinished()
    }

    /// 锁定长宽比联动与范围钳制（1–20cm）
    private func syncAspect(fromWidth: Bool) {
        guard lockAspect, imageAspect > 0 else { return }
        if fromWidth {
            heightCm = min(max(widthCm / imageAspect, 1), 20)
            widthCm = min(max(heightCm * imageAspect, 1), 20)
        } else {
            widthCm = min(max(heightCm * imageAspect, 1), 20)
            heightCm = min(max(widthCm / imageAspect, 1), 20)
        }
    }

    private func clampSize() {
        widthCm = min(max(widthCm, 1), 20)
        heightCm = min(max(heightCm, 1), 20)
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
