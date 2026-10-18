import SwiftUI
import PDFKit
import AppKit
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - 导出工具（P1 压缩 / P2 加密 / P3 导出图片 / 图像型 PDF）
//
// 栅格化统一走 CoreGraphics（线程安全，可整段后台执行）：
// 压缩、图像型 PDF、导出图片三件事共用 PDFRaster 引擎；
// 加密走 PDFKit 写出选项（矢量无损、批注保留）。

// MARK: 栅格化引擎

enum PDFRaster {
    /// 打开 PDF 数据（CG 线程安全，可后台调用）
    static func open(_ data: Data) -> CGPDFDocument? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGPDFDocument(provider)
    }

    /// 渲染单页为位图（后台线程安全）。返回 (位图, 显示尺寸 pt)。
    /// 旋转页先按 /Rotate 转正（与 PDFExporter 同一套四角度变换），再按 DPI 缩放。
    static func renderPage(_ doc: CGPDFDocument, index: Int, dpi: CGFloat) -> (image: CGImage, displaySize: CGSize)? {
        guard let page = doc.page(at: index + 1) else { return nil }
        let mb = page.getBoxRect(.mediaBox)
        let rot = Int(page.rotationAngle) % 360
        let display: CGSize
        switch rot {
        case 90, -270, 270, -90: display = CGSize(width: mb.height, height: mb.width)
        default: display = mb.size
        }
        let scale = max(dpi / 72, 0.1)
        let pw = max(Int(display.width * scale), 1)
        let ph = max(Int(display.height * scale), 1)
        guard let bmp = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bmp.setFillColor(CGColor(gray: 1, alpha: 1))   // 白底：透明背景页避免导出黑底
        bmp.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        bmp.interpolationQuality = .high
        bmp.saveGState()
        switch rot {
        case 90: bmp.concatenate(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: mb.width))
        case 180: bmp.concatenate(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: mb.width, ty: mb.height))
        case 270, -90: bmp.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: mb.height, ty: 0))
        default: break
        }
        bmp.scaleBy(x: scale, y: scale)   // 此时用户空间=显示空间(pt)，缩放映射到像素
        bmp.drawPDFPage(page)
        bmp.restoreGState()
        guard let img = bmp.makeImage() else { return nil }
        return (img, display)
    }

    /// JPEG 有损编码（控制压缩质量），解码回 CGImage
    static func jpeg(_ img: CGImage, quality: CGFloat) -> CGImage? {
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]),
              let ns = NSImage(data: data) else { return nil }
        var rect = CGRect(origin: .zero, size: ns.size)
        return ns.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// 把整本 PDF 按指定 DPI/质量重写为位图 PDF（图像型 PDF / 压缩共用）。
    /// macOS 26 上 beginPDFPage 的 per-page MediaBox 不生效（PDFExporter 实测），
    /// 与盖章导出同策略：按显示尺寸分组写出临时文件，再由 PDFKit 按原页序合并。
    /// progress(i, total) 在后台线程回调，返回 false 可中止。
    static func writeRasterPDF(from data: Data, dpi: CGFloat, jpegQuality: CGFloat?,
                               to url: URL, progress: @escaping (Int, Int) -> Bool) -> Bool {
        guard let src = open(data), src.numberOfPages > 0 else { return false }
        let total = src.numberOfPages
        let tmpDir = url.deletingLastPathComponent()
        let prefix = ".pdftool-raster-\(UUID().uuidString)-"
        var stale: [URL] = []
        defer { for u in stale { try? FileManager.default.removeItem(at: u) } }

        // 按显示尺寸分组（组内保持页序）
        var groups: [String: [Int]] = [:]
        var order: [String] = []
        for i in 0..<total {
            guard let page = src.page(at: i + 1) else { continue }
            let mb = page.getBoxRect(.mediaBox)
            let rot = Int(page.rotationAngle) % 360
            let size: CGSize
            switch rot {
            case 90, -270, 270, -90: size = CGSize(width: mb.height, height: mb.width)
            default: size = mb.size
            }
            let key = "\(Int(size.width))x\(Int(size.height))"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(i)
        }

        // 逐组写临时 PDF
        var groupFiles: [String: URL] = [:]
        var done = 0
        for key in order {
            let pages = groups[key]!
            guard let firstIdx = pages.first,
                  let meta = renderPage(src, index: firstIdx, dpi: dpi) else { continue }
            let fileURL = tmpDir.appendingPathComponent("\(prefix)\(key).pdf")
            stale.append(fileURL)
            var mediaBox = CGRect(origin: .zero, size: meta.displaySize)
            guard let ctx = CGContext(fileURL as CFURL, mediaBox: &mediaBox, nil) else { return false }
            for i in pages {
                guard progress(done, total) else { return false }
                if let r = renderPage(src, index: i, dpi: dpi) {
                    var img = r.image
                    if let q = jpegQuality { img = jpeg(img, quality: q) ?? img }
                    ctx.beginPDFPage(nil)
                    ctx.draw(img, in: CGRect(origin: .zero, size: r.displaySize))
                    ctx.endPDFPage()
                }
                done += 1
            }
            ctx.closePDF()
            groupFiles[key] = fileURL
        }

        // PDFKit 按原页序合并
        let merged = PDFDocument()
        var groupDocs: [String: PDFDocument] = [:]
        var counters: [String: Int] = [:]
        for (key, f) in groupFiles {
            if let d = PDFDocument(url: f) { groupDocs[key] = d }
        }
        for i in 0..<total {
            guard let page = src.page(at: i + 1) else { continue }
            let mb = page.getBoxRect(.mediaBox)
            let rot = Int(page.rotationAngle) % 360
            let size: CGSize
            switch rot {
            case 90, -270, 270, -90: size = CGSize(width: mb.height, height: mb.width)
            default: size = mb.size
            }
            let key = "\(Int(size.width))x\(Int(size.height))"
            guard let d = groupDocs[key] else { continue }
            let idx = counters[key, default: 0]
            counters[key] = idx + 1
            if let p = d.page(at: idx) { merged.insert(p, at: merged.pageCount) }
        }
        guard let out = merged.dataRepresentation() else { return false }
        try? FileManager.default.removeItem(at: url)
        do { try out.write(to: url, options: .atomic) } catch { return false }
        progress(total, total)
        return true
    }
}

// MARK: - 导出工具弹窗

enum ExportToolKind: Int, Identifiable {
    case compress, encrypt, images, imagePDF
    var id: Int { rawValue }
}

struct ExportToolsSheet: View {
    @State var kind: ExportToolKind
    /// 完成后回传状态栏文案
    let onDone: (String) -> Void

    @EnvironmentObject private var doc: DocumentStore
    @Environment(\.dismiss) private var dismiss

    @State private var running = false
    @State private var progressValue: Double = 0
    @State private var errorText: String?

    // 压缩
    @State private var compressLevel = 1
    // 加密
    @State private var openPwd = ""
    @State private var ownerPwd = ""
    // 导出图片
    @State private var imageFormat = 0   // 0 PNG 1 JPG
    @State private var imageDPI = 1      // 0 96 / 1 150 / 2 300
    // 图像型 PDF
    @State private var rasterDPI = 1

    private var pageCount: Int { max(doc.pageCount, 0) }
    private var srcSize: Int {
        guard let u = doc.url else { return 0 }
        return (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
    }

    static let dpiTable: [CGFloat] = [96, 150, 300]
    static let dpiLabels = [L("草稿 96 DPI"), L("标准 150 DPI"), L("高清 300 DPI")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("导出工具")).font(.headline)

            Picker("", selection: $kind) {
                Text(L("压缩")).tag(ExportToolKind.compress)
                Text(L("设置密码")).tag(ExportToolKind.encrypt)
                Text(L("导出为图片")).tag(ExportToolKind.images)
                Text(L("图像型 PDF")).tag(ExportToolKind.imagePDF)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()

            Group {
                switch kind {
                case .compress: compressPane
                case .encrypt: encryptPane
                case .images: imagesPane
                case .imagePDF: imagePDFPane
                }
            }

            if running {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progressValue)
                    Text(LF("正在处理 %d 页…", pageCount))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let e = errorText { Text(e).font(.callout).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button(L("取消"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(DialogButtonStyle())
                Button(actionLabel) { runTool() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(DialogButtonStyle(prominent: true))
                    .disabled(running || !canRun)
            }
        }
        .padding(22)
        .frame(width: 480)
        .dialogCard()
    }

    private var actionLabel: String {
        switch kind {
        case .compress: return L("压缩并保存…")
        case .encrypt: return L("加密并保存…")
        case .images: return L("导出图片…")
        case .imagePDF: return L("生成图像型 PDF…")
        }
    }

    private var canRun: Bool {
        guard doc.document != nil, doc.url != nil, pageCount > 0 else { return false }
        if kind == .encrypt { return !openPwd.isEmpty }
        return true
    }

    // MARK: 各工具参数区

    private var compressPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("压缩方式")).foregroundStyle(.secondary)
            Picker("", selection: $compressLevel) {
                Text(L("无损优化（重写文档，体积略减）")).tag(0)
                Text(L("高清压缩（200 DPI）")).tag(1)
                Text(L("标准压缩（150 DPI）")).tag(2)
                Text(L("高度压缩（96 DPI）")).tag(3)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if compressLevel > 0 {
                Text(L("图像压缩会把每页转为位图（文字不可选中），扫描件与图片型文档体积显著减小"))
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("保持文字矢量与可选中，仅重写文档结构去冗余"))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Text(LF("当前文件大小：%@", ByteCountFormatter.string(fromByteCount: Int64(srcSize), countStyle: .file)))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var encryptPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L("打开密码")).foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                SecureField(L("可选，留空则打开不需密码"), text: $openPwd)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 210)
            }
            HStack(spacing: 8) {
                Text(L("编辑密码")).foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                SecureField(L("可选，留空则编辑不受限"), text: $ownerPwd)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 210)
            }
            Text(L("打开密码：打开此 PDF 时必须输入。编辑密码：可直接打开阅读，但编辑被锁定，输入编辑密码解锁；也可用来打开设置了打开密码的文件。两项至少填一项。"))
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var imagesPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L("图片格式")).foregroundStyle(.secondary)
                Picker("", selection: $imageFormat) {
                    Text("PNG").tag(0)
                    Text("JPG").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 140)
            }
            HStack(spacing: 8) {
                Text(L("分辨率")).foregroundStyle(.secondary)
                Picker("", selection: $imageDPI) {
                    ForEach(0..<ExportToolsSheet.dpiLabels.count, id: \.self) { i in
                        Text(ExportToolsSheet.dpiLabels[i]).tag(i)
                    }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 160)
            }
            Text(LF("将为 %d 页每页生成一张图片，输出到所选文件夹（文件名形如「%@-001.png」）",
                    pageCount, doc.url?.deletingPathExtension().lastPathComponent ?? "文档"))
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var imagePDFPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L("分辨率")).foregroundStyle(.secondary)
                Picker("", selection: $rasterDPI) {
                    ForEach(0..<ExportToolsSheet.dpiLabels.count, id: \.self) { i in
                        Text(ExportToolsSheet.dpiLabels[i]).tag(i)
                    }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 160)
            }
            Text(L("每页转为整幅位图，内容不可选中、不可编辑，适合对外发送防改动版本；文字将不可搜索。"))
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 执行

    private func runTool() {
        errorText = nil
        guard let d = doc.document else { return }
        switch kind {
        case .compress: runCompress(d)
        case .encrypt: runEncrypt(d)
        case .images: runImages(d)
        case .imagePDF: runImagePDF(d)
        }
    }

    private func beginRun() { running = true; progressValue = 0 }
    private func endRun(_ msg: String?) {
        running = false
        progressValue = 0
        if let msg {
            onDone(msg)
            dismiss()
        }
    }

    /// 后台整段执行，主线程收结果
    private func background(_ work: @escaping @Sendable () -> String?, progress: @escaping (Double) -> Void = { _ in }) {
        beginRun()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async { endRun(result) }
        }
    }

    // 压缩：内存文档快照 → 后台压缩 → 状态栏回报前后大小
    private func runCompress(_ d: PDFDocument) {
        let panel = NSSavePanel()
        let stem = doc.url?.deletingPathExtension().lastPathComponent ?? "文档"
        panel.directoryURL = doc.url?.deletingLastPathComponent()
        panel.nameFieldStringValue = "\(stem)-\(L("压缩")).pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        background { [weak doc] in
            guard let doc else { return nil }
            let before = srcFileSize(of: doc.url)
            let data = d.dataRepresentation() ?? Data()
            guard !data.isEmpty else { return L("压缩失败：无法读取文档") }
            let out: Data?
            switch compressLevel {
            case 0:
                out = PDFDocument(data: data)?.dataRepresentation()   // 重写去冗余
            default:
                let dpi: CGFloat = compressLevel == 1 ? 200 : (compressLevel == 2 ? 150 : 96)
                let q: CGFloat = compressLevel == 1 ? 0.85 : (compressLevel == 2 ? 0.72 : 0.55)
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("compress-\(UUID().uuidString).pdf")
                defer { try? FileManager.default.removeItem(at: tmp) }
                var last = 0.0
                let ok = PDFRaster.writeRasterPDF(from: data, dpi: dpi, jpegQuality: q, to: tmp) { i, n in
                    let v = Double(i) / Double(max(n, 1))
                    if v - last > 0.02 || i == n {
                        last = v
                        DispatchQueue.main.async { self.progressValue = v }
                    }
                    return true
                }
                out = ok ? try? Data(contentsOf: tmp) : nil
            }
            guard let outData = out, !outData.isEmpty else { return L("压缩失败：无法生成压缩文档") }
            do {
                try outData.write(to: target, options: .atomic)
            } catch {
                return L("写入失败，请检查目标位置是否可写")
            }
            let after = outData.count
            return LF("已压缩：%@（%@ → %@）", target.lastPathComponent,
                      ByteCountFormatter.string(fromByteCount: Int64(before), countStyle: .file),
                      ByteCountFormatter.string(fromByteCount: Int64(after), countStyle: .file))
        } progress: { v in progressValue = v }
    }

    // 加密：PDFKit 写出选项（矢量无损，批注保留）
    // 打开密码 = user password（打开文件必须输入）；编辑密码 = owner password（可打开阅读但编辑锁定，输密码解锁）
    private func runEncrypt(_ d: PDFDocument) {
        let open = openPwd.trimmingCharacters(in: .whitespaces)
        let edit = ownerPwd.trimmingCharacters(in: .whitespaces)
        guard !open.isEmpty || !edit.isEmpty else {
            errorText = L("打开密码与编辑密码至少填一项")
            return
        }
        let panel = NSSavePanel()
        let stem = doc.url?.deletingPathExtension().lastPathComponent ?? "文档"
        panel.directoryURL = doc.url?.deletingLastPathComponent()
        panel.nameFieldStringValue = "\(stem)-\(L("加密")).pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        background { [weak doc] in
            guard let doc else { return nil }
            let data = d.dataRepresentation() ?? Data()
            guard let dd = PDFDocument(data: data) else { return L("加密失败：无法读取文档") }
            let ok = dd.write(to: target, withOptions: [
                .userPasswordOption: open,                      // 空 = 打开不需密码
                .ownerPasswordOption: edit.isEmpty ? open : edit,
            ])
            guard ok else { return L("加密失败：写入被拒绝") }
            let tail: String
            switch (!open.isEmpty, !edit.isEmpty) {
            case (true, true):   tail = L("打开与编辑均需密码")
            case (true, false):  tail = L("打开需密码")
            default:             tail = L("可直接打开阅读，编辑需密码")
            }
            return LF("已加密导出：%@（%@）", target.lastPathComponent, tail)
        }
    }

    // 导出图片：选文件夹 → 逐页渲染
    private func runImages(_ d: PDFDocument) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = L("选择图片输出文件夹")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let useJPG = imageFormat == 1
        let dpi = ExportToolsSheet.dpiTable[imageDPI]
        let ext = useJPG ? "jpg" : "png"
        let stem = doc.url?.deletingPathExtension().lastPathComponent ?? "文档"
        background { [weak doc] in
            guard let doc else { return nil }
            let data = d.dataRepresentation() ?? Data()
            guard let src = PDFRaster.open(data), src.numberOfPages > 0 else { return L("导出失败：无法读取文档") }
            let digits = max(String(src.numberOfPages).count, 3)
            for i in 0..<src.numberOfPages {
                guard let r = PDFRaster.renderPage(src, index: i, dpi: dpi) else { continue }
                var img = r.image
                if useJPG { img = PDFRaster.jpeg(img, quality: 0.9) ?? img }
                let rep = NSBitmapImageRep(cgImage: img)
                guard let fileData = rep.representation(
                    using: useJPG ? .jpeg : .png,
                    properties: useJPG ? [.compressionFactor: 0.9] : [:]) else { continue }
                let url = dir.appendingPathComponent(
                    String(format: "%@-%0\(digits)d.%@", stem, i + 1, ext))
                do { try fileData.write(to: url) } catch { return L("写入失败，请检查目标文件夹是否可写") }
                let v = Double(i + 1) / Double(src.numberOfPages)
                DispatchQueue.main.async { self.progressValue = v }
            }
            return LF("已导出 %d 张图片：%@", src.numberOfPages, dir.path)
        }
    }

    // 图像型 PDF
    private func runImagePDF(_ d: PDFDocument) {
        let panel = NSSavePanel()
        let stem = doc.url?.deletingPathExtension().lastPathComponent ?? "文档"
        panel.directoryURL = doc.url?.deletingLastPathComponent()
        panel.nameFieldStringValue = "\(stem)-\(L("图像版")).pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let dpi = ExportToolsSheet.dpiTable[rasterDPI]
        background { [weak doc] in
            guard let doc else { return nil }
            let data = d.dataRepresentation() ?? Data()
            var last = 0.0
            let ok = PDFRaster.writeRasterPDF(from: data, dpi: dpi, jpegQuality: 0.9, to: target) { i, n in
                let v = Double(i) / Double(max(n, 1))
                if v - last > 0.02 || i == n {
                    last = v
                    DispatchQueue.main.async { self.progressValue = v }
                }
                return true
            }
            guard ok else { return L("生成失败：无法读取文档或写入目标位置") }
            return LF("已生成图像型 PDF：%@", target.lastPathComponent)
        }
    }

    private func srcFileSize(of url: URL?) -> Int {
        guard let u = url else { return 0 }
        return (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
    }
}
