import SwiftUI
import AppKit
import CoreGraphics

// MARK: - 工作中心（空白起始页）：最近打开的文件 + 快速操作
//
// 最近文件存 UserDefaults（路径数组，最多 8 条）；
// 缩略图用 CG 渲染（后台线程安全，不动 PDFKit），按路径缓存。

enum RecentFiles {
    static let key = "recentPDFPaths"
    static let limit = 8

    static func urls() -> [URL] {
        UserDefaults.standard.stringArray(forKey: key)?
            .compactMap { URL(string: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) } ?? []
    }

    static func record(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == url.absoluteString }
        list.insert(url.absoluteString, at: 0)
        if list.count > limit { list = Array(list.prefix(limit)) }
        UserDefaults.standard.set(list, forKey: key)
    }

    static func remove(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == url.absoluteString }
        UserDefaults.standard.set(list, forKey: key)
    }

    static func clearAll() {
        UserDefaults.standard.set([String](), forKey: key)
    }
}

struct WorkspaceHomeView: View {
    let onOpen: (URL) -> Void
    let onPick: () -> Void
    var onMerge: () -> Void = {}
    var onCreate: () -> Void = {}

    @State private var recents: [URL] = RecentFiles.urls()
    @State private var thumbs: [String: NSImage] = [:]
    @State private var thumbFailed: Set<String> = []

    private let thumbCache = NSCache<NSString, NSImage>()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L("工作中心")).font(.title2.weight(.semibold))

                quickTools
                openZone

                HStack {
                    Text(L("最近打开")).font(.headline).foregroundStyle(.secondary)
                    Spacer()
                    if !recents.isEmpty {
                        Button(L("清除最近")) {
                            RecentFiles.clearAll()
                            recents = []
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                        .handCursor()
                    }
                }
                if recents.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock")
                            .font(.system(size: 30))
                            .foregroundStyle(.tertiary)
                        Text(L("暂无最近文件，打开一个 PDF 开始"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    VStack(spacing: 8) {
                        ForEach(recents, id: \.absoluteString) { url in
                            recentRow(url)
                        }
                    }
                }
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { recents = RecentFiles.urls() }
    }

    // MARK: 快速工具：合并文件 / 转换 PDF（无需先打开文档）

    private var quickTools: some View {
        HStack(spacing: 12) {
            quickCard(icon: "square.on.square.intersection.dashed",
                      title: L("合并文件"),
                      subtitle: L("多个 PDF 合并为一个"),
                      action: onMerge)
            quickCard(icon: "arrow.2.squarepath",
                      title: L("转换 PDF"),
                      subtitle: L("空白页 / 图像 / Word / Excel / PPT / 剪贴板"),
                      action: onCreate)
        }
    }

    private func quickCard(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(12)
            .dialogCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
    }

    // MARK: 打开区（未打开文件时不显示盖章/页面管理入口——那些功能需要先有文档）

    private var openZone: some View {
        Button(action: onPick) {
            VStack(spacing: 10) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(L("选择文件"))
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor))
                    .foregroundStyle(.white)
                Text(L("或将文件拖至此处"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .dialogCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
    }

    // MARK: 最近文件行

    private func recentRow(_ url: URL) -> some View {
        Button { onOpen(url) } label: {
            HStack(spacing: 12) {
                thumbView(url)
                VStack(alignment: .leading, spacing: 3) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
                RecentRemoveButton(url: url) {
                    RecentFiles.remove(url)
                    recents = RecentFiles.urls()
                }
            }
            .padding(10)
            .dialogCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .onAppear { loadThumb(url) }
    }

    private func thumbView(_ url: URL) -> some View {
        Group {
            if let img = thumbs[url.absoluteString] {
                Image(nsImage: img).resizable().scaledToFit()
            } else if thumbFailed.contains(url.absoluteString) {
                Image(systemName: "doc")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
        }
        .frame(width: 40, height: 52)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    /// 缩略图：CG 后台渲染首页（不动 PDFKit 主线程），按路径缓存
    private func loadThumb(_ url: URL) {
        let key = url.absoluteString
        guard thumbs[key] == nil, !thumbFailed.contains(key),
              thumbCache.object(forKey: key as NSString) == nil else {
            if let c = thumbCache.object(forKey: key as NSString) { thumbs[key] = c }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            guard let cg = CGPDFDocument(url as CFURL), cg.numberOfPages > 0,
                  let page = cg.page(at: 1) else {
                DispatchQueue.main.async { thumbFailed.insert(key) }
                return
            }
            let mb = page.getBoxRect(.mediaBox)
            let scale = 170 / max(mb.width, 1)
            let w = max(Int(mb.width * scale), 1), h = max(Int(mb.height * scale), 1)
            guard let bmp = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                DispatchQueue.main.async { thumbFailed.insert(key) }
                return
            }
            bmp.setFillColor(CGColor(gray: 1, alpha: 1))
            bmp.fill(CGRect(x: 0, y: 0, width: w, height: h))
            bmp.scaleBy(x: scale, y: scale)
            bmp.drawPDFPage(page)
            let img: NSImage?
            if let cgimg = bmp.makeImage() {
                img = NSImage(cgImage: cgimg, size: NSSize(width: mb.width, height: mb.height))
            } else { img = nil }
            DispatchQueue.main.async {
                if let img {
                    thumbCache.setObject(img, forKey: key as NSString)
                    thumbs[key] = img
                } else {
                    thumbFailed.insert(key)
                }
            }
        }
    }
}

/// hover 才出现的移除按钮
private struct RecentRemoveButton: View {
    let url: URL
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(hovering ? Color.primary : Color(nsColor: .quaternaryLabelColor))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("从最近列表移除"))
    }
}
