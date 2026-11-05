import SwiftUI
import AppKit
import PDFKit
import CoreGraphics
import CoreText
import UniformTypeIdentifiers

// MARK: - 工具箱（v2.10.0）：合并文件 / 转换 PDF（创建）
//
// 转换核心全部输出 PDFDocument（内存内、 freshly-opened，可在后台线程操作）；
// 活文档不动，sheet 内文件面板一律 presentPanel()（非模态 begin）。
// ⚠️ 旧惯例 runModal() 在 macOS 26+ 会与 SwiftUI sheet 冲突把 App 整个锁死，已废弃。

enum PagePreset: String, CaseIterable, Identifiable {
    case a3 = "A3", a4 = "A4", a5 = "A5", b5 = "B5", letter = "Letter"
    var id: String { rawValue }
    /// 纵向尺寸（cm），短边在前
    var cm: (w: Double, h: Double) {
        switch self {
        case .a3: return (29.7, 42.0)
        case .a4: return (21.0, 29.7)
        case .a5: return (14.8, 21.0)
        case .b5: return (17.6, 25.0)
        case .letter: return (21.59, 27.94)
        }
    }
    /// cm → pt
    static func pt(wCm: Double, hCm: Double) -> CGSize {
        CGSize(width: wCm * 72 / 2.54, height: hCm * 72 / 2.54)
    }
}

struct PDFBuildError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: 转换核心

enum PDFBuilder {

    /// 合并：unified == nil 保持各页原始大小；否则每页按目标尺寸重绘（等比缩放居中）
    static func merge(urls: [URL], unified: CGSize?) throws -> PDFDocument {
        guard !urls.isEmpty else {
            throw PDFBuildError(message: L("请先添加要合并的文件"))
        }
        let out = PDFDocument()
        if unified == nil {
            var idx = 0
            for u in urls {
                guard let d = PDFDocument(url: u) else {
                    throw PDFBuildError(message: L("无法打开文件") + ": " + u.lastPathComponent)
                }
                for i in 0..<d.pageCount {
                    if let p = d.page(at: i) { out.insert(p, at: idx); idx += 1 }
                }
            }
            return out
        }
        let target = unified!
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: target)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, _: nil) else {
            throw PDFBuildError(message: L("创建 PDF 失败"))
        }
        for u in urls {
            guard let d = PDFDocument(url: u) else {
                throw PDFBuildError(message: L("无法打开文件") + ": " + u.lastPathComponent)
            }
            for i in 0..<d.pageCount {
                guard let page = d.page(at: i) else { continue }
                let sb = page.bounds(for: .mediaBox)
                ctx.beginPDFPage(nil)
                let scale = min(target.width / max(sb.width, 1), target.height / max(sb.height, 1))
                let w = sb.width * scale, h = sb.height * scale
                ctx.saveGState()
                ctx.translateBy(x: (target.width - w) / 2, y: (target.height - h) / 2)
                ctx.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: ctx)
                ctx.restoreGState()
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        guard let result = PDFDocument(data: data as Data) else {
            throw PDFBuildError(message: L("创建 PDF 失败"))
        }
        return result
    }

    /// 多图 → 每图一页（页面尺寸 = 图像 72dpi 自然尺寸）
    static func fromImages(_ urls: [URL]) throws -> PDFDocument {
        try fromImages(urls, unified: nil)
    }

    /// 多图 → 每图一页。unified == nil 保持图像自然尺寸；否则每页按目标尺寸、图像等比缩放居中。
    static func fromImages(_ urls: [URL], unified: CGSize?) throws -> PDFDocument {
        guard !urls.isEmpty else { throw PDFBuildError(message: L("请先添加图片")) }
        var imgs: [NSImage] = []
        for u in urls {
            guard let img = NSImage(contentsOf: u) else {
                throw PDFBuildError(message: L("无法读取图像") + ": " + u.lastPathComponent)
            }
            imgs.append(img)
        }
        return try images(imgs, unified: unified)
    }

    /// 图像数组 → PDF（「从图像创建 / 从剪贴板创建」共用核心）。
    /// unified == nil 每页尺寸 = 图像像素的自然尺寸；否则图像等比缩放居中到目标页面。
    static func images(_ imgs: [NSImage], unified: CGSize?) throws -> PDFDocument {
        guard !imgs.isEmpty else { throw PDFBuildError(message: L("无法读取图像")) }
        if unified == nil {
            let out = PDFDocument()
            for img in imgs {
                guard let p = PDFPage(image: img) else {
                    throw PDFBuildError(message: L("无法读取图像"))
                }
                out.insert(p, at: out.pageCount)
            }
            return out
        }
        let target = unified!
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: target)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, _: nil) else {
            throw PDFBuildError(message: L("创建 PDF 失败"))
        }
        for img in imgs {
            guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw PDFBuildError(message: L("无法读取图像"))
            }
            ctx.beginPDFPage(nil)
            let scale = min(target.width / max(CGFloat(cg.width), 1), target.height / max(CGFloat(cg.height), 1))
            let w = CGFloat(cg.width) * scale, h = CGFloat(cg.height) * scale
            ctx.saveGState()
            ctx.translateBy(x: (target.width - w) / 2, y: (target.height - h) / 2)
            ctx.scaleBy(x: scale, y: scale)
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        guard let result = PDFDocument(data: data as Data) else {
            throw PDFBuildError(message: L("创建 PDF 失败"))
        }
        return result
    }

    /// 剪贴板里的图像（按加入顺序）；也为拖到剪贴板的图片文件 URL 兜底。
    static func clipboardImages() -> [NSImage] {
        let pb = NSPasteboard.general
        if let imgs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], !imgs.isEmpty {
            return imgs
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            return urls.compactMap { NSImage(contentsOf: $0) }
        }
        return []
    }

    /// 剪贴板 → 图像（每张一页）或文字（A4 排版）
    static func fromClipboard() throws -> PDFDocument {
        let pb = NSPasteboard.general
        if let imgs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], !imgs.isEmpty {
            let out = PDFDocument()
            for img in imgs { out.insert(PDFPage(image: img)!, at: out.pageCount) }
            return out
        }
        if let str = pb.string(forType: .string), !str.isEmpty {
            return fromText(NSAttributedString(string: str), pageSize: PagePreset.pt(wCm: 21, hCm: 29.7))
        }
        throw PDFBuildError(message: L("剪贴板中没有可用的图像或文字"))
    }

    /// 富文本 → 分页 PDF（Word/RTF/TXT/HTML 通用）
    static func fromText(_ attr: NSAttributedString, pageSize: CGSize) -> PDFDocument {
        let margin: CGFloat = 36
        let frameRect = CGRect(x: margin, y: margin,
                               width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin)
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, _: nil)!
        var loc = 0
        while loc < attr.length {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: loc, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }   // 防异常死循环
            loc = visible.location + visible.length
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return PDFDocument(data: data as Data) ?? PDFDocument()
    }
}

// MARK: - 合并文件

struct MergeFilesView: View {
    let onOpen: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var files: [URL] = []
    @State private var unified = false
    @State private var preset: PagePreset = .a4
    @State private var widthCm: Double = 21.0
    @State private var heightCm: Double = 29.7
    @State private var landscape = false
    @State private var filename = L("合并")
    @State private var errorText: String?
    @State private var working = false
    @State private var draggingRow: URL?
    @State private var dragOverRow: URL?
    @State private var saveDir: URL?   // nil = 默认（第一个文件所在目录，无文件时用「下载」）

    /// 当前生效的保存目录
    private var effectiveSaveDir: URL {
        saveDir
            ?? files.first?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    var body: some View {
        HStack(spacing: 0) {
            fileListPanel
            Divider()
            settingsPanel
        }
        .frame(width: 920, height: 540)
        .alert(L("出错了"), isPresented: .init(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(L("好"), role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    // MARK: 左栏：文件列表

    private var fileListPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("合并")).font(.headline)
                Spacer()
                Button { addFiles() } label: {
                    Label(L("添加文件"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                Button(L("清除列表")) { files.removeAll() }
                    .disabled(files.isEmpty)
            }
            .handCursor()

            if files.isEmpty {
                dropArea
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(files.enumerated()), id: \.element.absoluteString) { i, url in
                            fileRow(i, url)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            files.append(contentsOf: pdfs)
            return !pdfs.isEmpty
        }
    }

    private var dropArea: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L("将文件拖至此处")).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func fileRow(_ i: Int, _ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .help(L("拖动调整顺序"))
            Image(systemName: "doc").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                Text(pageSummary(url)).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button { files.move(fromOffsets: IndexSet(integer: i), toOffset: i - 1) } label: {
                Image(systemName: "chevron.up")
            }.disabled(i == 0)
            Button { files.move(fromOffsets: IndexSet(integer: i), toOffset: i + 2) } label: {
                Image(systemName: "chevron.down")
            }.disabled(i == files.count - 1)
            Button { files.remove(at: i) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .handCursor()
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay {
            // 拖拽悬停指示：拖到某行上方时该行描蓝边
            if dragOverRow == url && draggingRow != url {
                RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2)
            }
        }
        .opacity(draggingRow == url ? 0.4 : 1)
        .onDrag {
            draggingRow = url
            return NSItemProvider(object: url.absoluteString as NSString)
        }
        .onDrop(of: [.text], delegate: FileReorderDelegate(target: url,
                                                           files: $files,
                                                           dragging: $draggingRow,
                                                           hovering: $dragOverRow))
    }

    private func pageSummary(_ url: URL) -> String {
        let n = PDFDocument(url: url)?.pageCount ?? 0
        return LF("%d 页", n)
    }

    // MARK: 右栏：设置

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("页面大小选项")).font(.headline)
            Picker("", selection: $unified) {
                Text(L("保持原始大小")).tag(false)
                Text(L("统一页面大小")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                Text(L("页面大小 (cm)")).font(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { preset },
                    set: { preset = $0; widthCm = $0.cm.w; heightCm = $0.cm.h })) {
                    ForEach(PagePreset.allCases) { p in Text(p.rawValue).tag(p) }
                }
                .labelsHidden()
                HStack(spacing: 10) {
                    Text("W")
                    TextField("", value: $widthCm, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                    Text("H")
                    TextField("", value: $heightCm, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                }
                Text(L("方向")).font(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: $landscape) {
                    Label(L("纵向"), systemImage: "rectangle.portrait").tag(false)
                    Label(L("横向"), systemImage: "rectangle.landscape").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .opacity(unified ? 1 : 0.35)
            .disabled(!unified)

            Text(L("保存路径")).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(effectiveSaveDir.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(L("浏览…")) { chooseSaveDir() }
                    .fixedSize()
                    .handCursor()
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))

            Text(L("文件名")).font(.subheadline).foregroundStyle(.secondary)
            TextField(L("合并"), text: $filename)
                .textFieldStyle(.roundedBorder)

            Spacer()

            HStack(spacing: 10) {
                Button {
                    applyMerge()
                } label: {
                    Text(working ? L("正在保存…") : L("应用"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)   // 应用为默认项（回车触发）
                .disabled(files.count < 2 || working)
                .handCursor()
                Button {
                    dismiss()
                } label: {
                    Text(L("取消"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .handCursor()
            }

            if working { ProgressView().progressViewStyle(.linear) }
        }
        .padding(16)
        .frame(width: 300, alignment: .topLeading)
    }

    // MARK: 动作

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf]
        presentPanel(panel) {
            files.append(contentsOf: panel.urls)
        }
    }

    /// 选择保存目录（文件夹面板）
    private func chooseSaveDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = effectiveSaveDir
        presentPanel(panel) {
            guard let dir = panel.url else { return }
            saveDir = dir
        }
    }

    private func applyMerge() {
        let targetSize: CGSize? = unified ? {
            var size = PagePreset.pt(wCm: widthCm, hCm: heightCm)
            if (size.width > size.height) != landscape { size = CGSize(width: size.height, height: size.width) }
            return size
        }() : nil
        let urls = files
        let baseName = filename.isEmpty ? L("合并") : filename
        let dir = effectiveSaveDir
        // 目标文件已存在时自动顺延（合并 2、合并 3…），避免静默覆盖
        var target = dir.appendingPathComponent(baseName + ".pdf")
        var n = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(baseName) \(n).pdf")
            n += 1
        }
        working = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let doc = try PDFBuilder.merge(urls: urls, unified: targetSize)
                guard doc.write(to: target) else {
                    throw PDFBuildError(message: L("写入失败，请检查目标位置是否可写"))
                }
                DispatchQueue.main.async {
                    working = false
                    dismiss()
                    onOpen(target)
                }
            } catch {
                DispatchQueue.main.async {
                    working = false
                    errorText = error.localizedDescription
                }
            }
        }
    }
}

/// 文件列表行拖拽排序（payload 用 text 类型，避免命中外层「拖入文件」的 URL dropDestination）
private struct FileReorderDelegate: DropDelegate {
    let target: URL
    @Binding var files: [URL]
    @Binding var dragging: URL?
    @Binding var hovering: URL?

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        hovering = target
        guard let dragging, dragging != target,
              let from = files.firstIndex(of: dragging),
              let to = files.firstIndex(of: target) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            files.move(fromOffsets: IndexSet(integer: from),
                       toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        hovering = nil
        return true
    }

    func dropExited(info: DropInfo) {
        if hovering == target { hovering = nil }
    }
}

// MARK: - 从图像创建 PDF（界面同合并文件：左列表 + 右页面大小/保存设置）

struct ImagesToPDFView: View {
    let onOpen: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var files: [URL] = []
    @State private var unified = false
    @State private var preset: PagePreset = .a4
    @State private var widthCm: Double = 21.0
    @State private var heightCm: Double = 29.7
    @State private var landscape = false
    @State private var filename = L("图像")
    @State private var errorText: String?
    @State private var working = false
    @State private var draggingRow: URL?
    @State private var dragOverRow: URL?
    @State private var saveDir: URL?
    @State private var thumbs: [String: NSImage] = [:]

    private var effectiveSaveDir: URL {
        saveDir
            ?? files.first?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    var body: some View {
        HStack(spacing: 0) {
            fileListPanel
            Divider()
            settingsPanel
        }
        .frame(width: 920, height: 540)
        .alert(L("出错了"), isPresented: .init(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(L("好"), role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    // MARK: 左栏：图片列表

    private var fileListPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("从图像创建 PDF")).font(.headline)
                Spacer()
                Button { addFiles() } label: {
                    Label(L("添加图片"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                Button(L("清除列表")) { files.removeAll() }
                    .disabled(files.isEmpty)
            }
            .handCursor()

            if files.isEmpty {
                dropArea
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(files.enumerated()), id: \.element.absoluteString) { i, url in
                            imageRow(i, url)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dropDestination(for: URL.self) { urls, _ in
            let imgs = urls.filter { Self.isImage($0) }
            files.append(contentsOf: imgs)
            loadThumbs()
            return !imgs.isEmpty
        }
    }

    private var dropArea: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L("将图片拖至此处")).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func imageRow(_ i: Int, _ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .help(L("拖动调整顺序"))
            Group {
                if let t = thumbs[url.absoluteString] {
                    Image(nsImage: t).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                Text(dimSummary(url)).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button { files.move(fromOffsets: IndexSet(integer: i), toOffset: i - 1) } label: {
                Image(systemName: "chevron.up")
            }.disabled(i == 0)
            Button { files.move(fromOffsets: IndexSet(integer: i), toOffset: i + 2) } label: {
                Image(systemName: "chevron.down")
            }.disabled(i == files.count - 1)
            Button {
                files.remove(at: i)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .handCursor()
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay {
            if dragOverRow == url && draggingRow != url {
                RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2)
            }
        }
        .opacity(draggingRow == url ? 0.4 : 1)
        .onDrag {
            draggingRow = url
            return NSItemProvider(object: url.absoluteString as NSString)
        }
        .onDrop(of: [.text], delegate: FileReorderDelegate(target: url,
                                                           files: $files,
                                                           dragging: $draggingRow,
                                                           hovering: $dragOverRow))
    }

    private func dimSummary(_ url: URL) -> String {
        guard let rep = NSImageRep(contentsOf: url) else { return "" }
        return LF("%d × %d 像素", rep.pixelsWide, rep.pixelsHigh)
    }

    static func isImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "webp"]
            .contains(url.pathExtension.lowercased())
    }

    private func loadThumbs() {
        DispatchQueue.global(qos: .userInitiated).async {
            var t: [String: NSImage] = [:]
            for u in files {
                guard thumbs[u.absoluteString] == nil, let img = NSImage(contentsOf: u) else { continue }
                img.size = NSSize(width: 68, height: 68)
                t[u.absoluteString] = img
            }
            DispatchQueue.main.async { thumbs.merge(t) { cur, _ in cur } }
        }
    }

    // MARK: 右栏：设置（与合并文件一致）

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("页面大小选项")).font(.headline)
            Picker("", selection: $unified) {
                Text(L("保持原始大小")).tag(false)
                Text(L("统一页面大小")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                Text(L("页面大小 (cm)")).font(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { preset },
                    set: { preset = $0; widthCm = $0.cm.w; heightCm = $0.cm.h })) {
                    ForEach(PagePreset.allCases) { p in Text(p.rawValue).tag(p) }
                }
                .labelsHidden()
                HStack(spacing: 10) {
                    Text("W")
                    TextField("", value: $widthCm, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                    Text("H")
                    TextField("", value: $heightCm, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                }
                Text(L("方向")).font(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: $landscape) {
                    Label(L("纵向"), systemImage: "rectangle.portrait").tag(false)
                    Label(L("横向"), systemImage: "rectangle.landscape").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .opacity(unified ? 1 : 0.35)
            .disabled(!unified)

            Text(L("保存路径")).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(effectiveSaveDir.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(L("浏览…")) { chooseSaveDir() }
                    .fixedSize()
                    .handCursor()
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))

            Text(L("文件名")).font(.subheadline).foregroundStyle(.secondary)
            TextField(L("图像"), text: $filename)
                .textFieldStyle(.roundedBorder)

            Spacer()

            HStack(spacing: 10) {
                Button {
                    apply()
                } label: {
                    Text(working ? L("正在保存…") : L("应用"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(files.isEmpty || working)
                .handCursor()
                Button {
                    dismiss()
                } label: {
                    Text(L("取消"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .handCursor()
            }

            if working { ProgressView().progressViewStyle(.linear) }
        }
        .padding(16)
        .frame(width: 300, alignment: .topLeading)
        .onChange(of: files) { _ in loadThumbs() }
    }

    // MARK: 动作

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        presentPanel(panel) {
            files.append(contentsOf: panel.urls)
        }
    }

    private func chooseSaveDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = effectiveSaveDir
        presentPanel(panel) {
            guard let dir = panel.url else { return }
            saveDir = dir
        }
    }

    private func apply() {
        let targetSize: CGSize? = unified ? {
            var size = PagePreset.pt(wCm: widthCm, hCm: heightCm)
            if (size.width > size.height) != landscape { size = CGSize(width: size.height, height: size.width) }
            return size
        }() : nil
        let urls = files
        let baseName = filename.isEmpty ? L("图像") : filename
        let dir = effectiveSaveDir
        var target = dir.appendingPathComponent(baseName + ".pdf")
        var n = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(baseName) \(n).pdf")
            n += 1
        }
        working = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let doc = try PDFBuilder.fromImages(urls, unified: targetSize)
                guard doc.write(to: target) else {
                    throw PDFBuildError(message: L("写入失败，请检查目标位置是否可写"))
                }
                DispatchQueue.main.async {
                    working = false
                    dismiss()
                    onOpen(target)
                }
            } catch {
                DispatchQueue.main.async {
                    working = false
                    errorText = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - 从剪贴板创建 PDF（左预览剪贴板图片，右选比例与保存设置）

struct ClipboardToPDFView: View {
    let onOpen: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var images: [NSImage] = []
    @State private var checked = false
    @State private var fitPage = false
    @State private var preset: PagePreset = .a4
    @State private var widthCm: Double = 21.0
    @State private var heightCm: Double = 29.7
    @State private var landscape = false
    @State private var filename = L("剪贴板")
    @State private var errorText: String?
    @State private var working = false
    @State private var saveDir: URL?

    private var effectiveSaveDir: URL {
        saveDir
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    var body: some View {
        HStack(spacing: 0) {
            previewPanel
            Divider()
            settingsPanel
        }
        .frame(width: 920, height: 540)
        .onAppear { reread() }
        .alert(L("出错了"), isPresented: .init(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(L("好"), role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    // MARK: 左栏：剪贴板图片预览

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("从剪贴板创建 PDF")).font(.headline)
                Spacer()
                Button { reread() } label: {
                    Label(L("重新读取剪贴板"), systemImage: "arrow.clockwise")
                }
                .handCursor()
            }

            if images.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: checked ? "clipboard" : "clipboard")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(checked ? L("剪贴板中没有图片") : L("正在读取剪贴板…"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            } else if images.count == 1, let img = images.first {
                VStack(spacing: 8) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(pixelSummary(img)).font(.caption).foregroundStyle(.tertiary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                            HStack(spacing: 8) {
                                Image(nsImage: img)
                                    .resizable().scaledToFit()
                                    .frame(width: 40, height: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(LF("图片 %d", i + 1)).lineLimit(1)
                                    Text(pixelSummary(img)).font(.caption).foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .controlBackgroundColor)))
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func pixelSummary(_ img: NSImage) -> String {
        guard let rep = img.representations.first else { return "" }
        return LF("%d × %d 像素", rep.pixelsWide, rep.pixelsHigh)
    }

    // MARK: 右栏：比例与保存设置

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("页面比例选项")).font(.headline)
            Picker("", selection: $fitPage) {
                Text(L("保持原始比例")).tag(false)
                Text(L("转换为指定比例")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                Text(L("页面大小 (cm)")).font(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { preset },
                    set: { preset = $0; widthCm = $0.cm.w; heightCm = $0.cm.h })) {
                    ForEach(PagePreset.allCases) { p in Text(p.rawValue).tag(p) }
                }
                .labelsHidden()
                HStack(spacing: 10) {
                    Text("W")
                    TextField("", value: $widthCm, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                    Text("H")
                    TextField("", value: $heightCm, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                }
                Text(L("方向")).font(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: $landscape) {
                    Label(L("纵向"), systemImage: "rectangle.portrait").tag(false)
                    Label(L("横向"), systemImage: "rectangle.landscape").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .opacity(fitPage ? 1 : 0.35)
            .disabled(!fitPage)

            Text(L("保存路径")).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(effectiveSaveDir.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(L("浏览…")) { chooseSaveDir() }
                    .fixedSize()
                    .handCursor()
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))

            Text(L("文件名")).font(.subheadline).foregroundStyle(.secondary)
            TextField(L("剪贴板"), text: $filename)
                .textFieldStyle(.roundedBorder)

            Spacer()

            HStack(spacing: 10) {
                Button {
                    apply()
                } label: {
                    Text(working ? L("正在保存…") : L("应用"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(images.isEmpty || working)
                .handCursor()
                Button {
                    dismiss()
                } label: {
                    Text(L("取消"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .handCursor()
            }

            if working { ProgressView().progressViewStyle(.linear) }
        }
        .padding(16)
        .frame(width: 300, alignment: .topLeading)
    }

    // MARK: 动作

    private func reread() {
        images = PDFBuilder.clipboardImages()
        checked = true
    }

    private func chooseSaveDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = effectiveSaveDir
        presentPanel(panel) {
            guard let dir = panel.url else { return }
            saveDir = dir
        }
    }

    private func apply() {
        let targetSize: CGSize? = fitPage ? {
            var size = PagePreset.pt(wCm: widthCm, hCm: heightCm)
            if (size.width > size.height) != landscape { size = CGSize(width: size.height, height: size.width) }
            return size
        }() : nil
        let imgs = images
        let baseName = filename.isEmpty ? L("剪贴板") : filename
        let dir = effectiveSaveDir
        var target = dir.appendingPathComponent(baseName + ".pdf")
        var n = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(baseName) \(n).pdf")
            n += 1
        }
        working = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let doc = try PDFBuilder.images(imgs, unified: targetSize)
                guard doc.write(to: target) else {
                    throw PDFBuildError(message: L("写入失败，请检查目标位置是否可写"))
                }
                DispatchQueue.main.async {
                    working = false
                    dismiss()
                    onOpen(target)
                }
            } catch {
                DispatchQueue.main.async {
                    working = false
                    errorText = error.localizedDescription
                }
            }
        }
    }
}
