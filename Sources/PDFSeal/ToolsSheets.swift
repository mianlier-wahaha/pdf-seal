import SwiftUI
import AppKit
import PDFKit
import CoreGraphics
import CoreText
import UniformTypeIdentifiers

// MARK: - 工具箱（v2.10.0）：合并文件 / 转换 PDF（创建）
//
// 转换核心全部输出 PDFDocument（内存内、 freshly-opened，可在后台线程操作）；
// 活文档不动，sheet 内 NSOpenPanel/NSSavePanel 一律 runModal()（sheet 嵌套惯例）。

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

    /// 空白页
    static func blank(pageSize: CGSize, count: Int) throws -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, _: nil) else {
            throw PDFBuildError(message: L("创建 PDF 失败"))
        }
        for _ in 0..<max(count, 1) {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(mediaBox)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        guard let d = PDFDocument(data: data as Data) else {
            throw PDFBuildError(message: L("创建 PDF 失败"))
        }
        return d
    }

    /// 多图 → 每图一页（页面尺寸 = 图像 72dpi 自然尺寸）
    static func fromImages(_ urls: [URL]) throws -> PDFDocument {
        let out = PDFDocument()
        for u in urls {
            guard let img = NSImage(contentsOf: u) else {
                throw PDFBuildError(message: L("无法读取图像") + ": " + u.lastPathComponent)
            }
            out.insert(PDFPage(image: img)!, at: out.pageCount)
        }
        guard out.pageCount > 0 else { throw PDFBuildError(message: L("无法读取图像")) }
        return out
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

    /// Word（.doc/.docx）：TextKit 自动识别读取，A4 排版
    static func fromWord(_ url: URL) throws -> PDFDocument {
        guard let attr = try? NSAttributedString(url: url, options: [:], documentAttributes: nil),
              !attr.string.isEmpty else {
            throw PDFBuildError(message: L("无法读取 Word 文件") + ": " + url.lastPathComponent)
        }
        return fromText(attr, pageSize: PagePreset.pt(wCm: 21, hCm: 29.7))
    }

    /// Excel / PowerPoint：经 Microsoft Office AppleScript 导出（未装 Office 时报错）
    static func fromOffice(_ url: URL) throws -> PDFDocument {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-\(UUID().uuidString.prefix(6)).pdf")
        let isExcel = ["xls", "xlsx"].contains(url.pathExtension.lowercased())
        let appPath = isExcel ? "/Applications/Microsoft Excel.app" : "/Applications/Microsoft PowerPoint.app"
        guard FileManager.default.fileExists(atPath: appPath) else {
            throw PDFBuildError(message: isExcel ? L("未检测到 Microsoft Excel，无法转换 Excel 文件")
                                                 : L("未检测到 Microsoft PowerPoint，无法转换演示文稿"))
        }
        let script: String
        if isExcel {
            script = """
            tell application "Microsoft Excel"
                open POSIX file "\(url.path)"
                save workbook as active workbook filename "\(outURL.path)" file format PDF file format
                close active workbook saving no
            end tell
            """
        } else {
            script = """
            tell application "Microsoft PowerPoint"
                open POSIX file "\(url.path)"
                save active presentation in "\(outURL.path)" as save as PDF
                close active presentation saving no
            end tell
            """
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: outURL.path),
              let d = PDFDocument(url: outURL) else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw PDFBuildError(message: L("转换失败") + (msg.isEmpty ? "" : ": " + msg.prefix(160)))
        }
        return d
    }

    /// 按扩展名分派（从文件创建 / 批量创建共用）
    static func dispatch(_ url: URL) throws -> PDFDocument {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let d = PDFDocument(url: url) else {
                throw PDFBuildError(message: L("无法打开文件") + ": " + url.lastPathComponent)
            }
            return d
        }
        if ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "webp"].contains(ext) {
            return try fromImages([url])
        }
        if ["doc", "docx", "rtf", "rtfd", "txt", "html", "htm"].contains(ext) {
            guard let attr = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else {
                throw PDFBuildError(message: L("无法读取文件") + ": " + url.lastPathComponent)
            }
            return fromText(attr, pageSize: PagePreset.pt(wCm: 21, hCm: 29.7))
        }
        if ["xls", "xlsx", "ppt", "pptx", "key"].contains(ext) {
            return try fromOffice(url)
        }
        throw PDFBuildError(message: L("不支持的文件类型") + ": ." + ext)
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

            Text(L("文件名")).font(.subheadline).foregroundStyle(.secondary)
            TextField(L("合并"), text: $filename)
                .textFieldStyle(.roundedBorder)

            Spacer()

            HStack(spacing: 10) {
                Button(L("取消")) { dismiss() }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .handCursor()
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
        if panel.runModal() == .OK {
            files.append(contentsOf: panel.urls)
        }
    }

    private func applyMerge() {
        let targetSize: CGSize? = unified ? {
            var size = PagePreset.pt(wCm: widthCm, hCm: heightCm)
            if (size.width > size.height) != landscape { size = CGSize(width: size.height, height: size.width) }
            return size
        }() : nil
        let urls = files
        let name = filename.isEmpty ? L("合并") : filename
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = name + ".pdf"
        panel.directoryURL = urls.first?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let target = panel.url else { return }
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

// MARK: - 转换 PDF（创建）

enum CreateKind: String, Identifiable {
    case blank, image, clipboard, file, word, excel, ppt, batch
    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: return L("空白页面")
        case .image: return L("从图像创建 PDF")
        case .clipboard: return L("从剪贴板创建 PDF")
        case .file: return L("从文件创建 PDF")
        case .word: return L("从 Word 创建 PDF")
        case .excel: return L("从 Excel 创建 PDF")
        case .ppt: return L("从 PowerPoint 创建 PDF")
        case .batch: return L("创建多个 PDF 文件")
        }
    }
    var icon: String {
        switch self {
        case .blank: return "file"
        case .image: return "photo.on.rectangle"
        case .clipboard: return "clipboard"
        case .file: return "doc.badge.arrow.up"
        case .word: return "doc.text"
        case .excel: return "tablecells"
        case .ppt: return "slideshow"
        case .batch: return "square.stack.3d.up"
        }
    }
    var subtitle: String {
        switch self {
        case .blank: return L("生成指定尺寸和页数的空白 PDF")
        case .image: return L("每张图片一页")
        case .clipboard: return L("把剪贴板中的图像或文字变成 PDF")
        case .file: return L("图像 / 文本 / Word / Excel / PowerPoint")
        case .word: return L("Word 文档排版为 PDF")
        case .excel: return L("需要安装 Microsoft Excel")
        case .ppt: return L("需要安装 Microsoft PowerPoint")
        case .batch: return L("批量转换多个文件，各自生成 PDF")
        }
    }
}

struct CreatePDFView: View {
    let onOpen: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var expandedBlank = false
    @State private var preset: PagePreset = .a4
    @State private var landscape = false
    @State private var pageCount = 1
    @State private var working = false
    @State private var errorText: String?

    private let allKinds: [CreateKind] = [.blank, .image, .clipboard, .file, .word, .excel, .ppt, .batch]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("转换 PDF")).font(.headline)
            Text(L("选择创建方式")).font(.subheadline).foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(allKinds) { kind in
                        kindRow(kind)
                    }
                }
            }

            if working { ProgressView().progressViewStyle(.linear) }
        }
        .padding(16)
        .frame(width: 520, height: 460, alignment: .topLeading)
        .alert(L("出错了"), isPresented: .init(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(L("好"), role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func kindRow(_ kind: CreateKind) -> some View {
        VStack(spacing: 0) {
            Button {
                switch kind {
                case .blank: withAnimation { expandedBlank.toggle() }
                case .batch: pickBatch()
                default: pickAndConvert(kind)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: kind.icon)
                        .font(.system(size: 20))
                        .frame(width: 30)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title).font(.callout.weight(.medium))
                        Text(kind.subtitle).font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Image(systemName: kind == .blank && expandedBlank ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()

            if kind == .blank && expandedBlank {
                HStack(spacing: 12) {
                    Picker("", selection: $preset) {
                        ForEach(PagePreset.allCases) { p in Text(p.rawValue).tag(p) }
                    }
                    .frame(width: 100)
                    Picker("", selection: $landscape) {
                        Text(L("纵向")).tag(false)
                        Text(L("横向")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                    HStack(spacing: 4) {
                        Text(L("页数"))
                        TextField("", value: $pageCount, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 54)
                    }
                    Button(L("创建")) { createBlank() }
                        .buttonStyle(.borderedProminent)
                        .disabled(working)
                }
                .padding(.leading, 52).padding(.trailing, 10).padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: 动作

    private func createBlank() {
        var size = PagePreset.pt(wCm: preset.cm.w, hCm: preset.cm.h)
        if landscape { size = CGSize(width: size.height, height: size.width) }
        let count = max(pageCount, 1)
        saveAndOpen(name: L("空白")) { try PDFBuilder.blank(pageSize: size, count: count) }
    }

    private func pickAndConvert(_ kind: CreateKind) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        switch kind {
        case .image:
            panel.allowedContentTypes = [.image]
        case .word, .excel, .ppt:
            panel.allowedContentTypes = []   // 按扩展名在转换器内校验
        default:
            panel.allowedContentTypes = []
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        saveAndOpen(name: name) {
            switch kind {
            case .image: return try PDFBuilder.fromImages([url])
            case .word:
                guard ["doc", "docx"].contains(url.pathExtension.lowercased()) else {
                    throw PDFBuildError(message: L("请选择 Word 文件（.doc/.docx）"))
                }
                return try PDFBuilder.fromWord(url)
            case .excel:
                guard ["xls", "xlsx"].contains(url.pathExtension.lowercased()) else {
                    throw PDFBuildError(message: L("请选择 Excel 文件（.xls/.xlsx）"))
                }
                return try PDFBuilder.fromOffice(url)
            case .ppt:
                guard ["ppt", "pptx"].contains(url.pathExtension.lowercased()) else {
                    throw PDFBuildError(message: L("请选择 PowerPoint 文件（.ppt/.pptx）"))
                }
                return try PDFBuilder.fromOffice(url)
            default: return try PDFBuilder.dispatch(url)
            }
        }
    }

    private func pickBatch() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        let dirPanel = NSOpenPanel()
        dirPanel.canChooseFiles = false
        dirPanel.canChooseDirectories = true
        dirPanel.message = L("选择输出文件夹")
        guard dirPanel.runModal() == .OK, let dir = dirPanel.url else { return }
        working = true
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = 0, failed: [String] = []
            for u in urls {
                do {
                    let doc = try PDFBuilder.dispatch(u)
                    let out = dir.appendingPathComponent(u.deletingPathExtension().lastPathComponent + ".pdf")
                    if doc.write(to: out) { ok += 1 } else { failed.append(u.lastPathComponent) }
                } catch { failed.append(u.lastPathComponent) }
            }
            DispatchQueue.main.async {
                working = false
                if !failed.isEmpty {
                    errorText = L("转换失败") + ": " + failed.joined(separator: "、")
                } else {
                    errorText = LF("已创建 %d 个 PDF（输出至选定文件夹）", ok)
                }
            }
        }
    }

    /// 保存面板 → 后台构建写盘 → 关 sheet 并在新标签打开
    private func saveAndOpen(name: String, _ build: @escaping () throws -> PDFDocument) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = name + ".pdf"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        working = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let doc = try build()
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
