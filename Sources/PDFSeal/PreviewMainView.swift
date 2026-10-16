import SwiftUI
import PDFKit
import AppKit
import SealCore

// MARK: - 预览主界面（默认落点）：左栏 缩略图/标签/大纲 + 单页大图 + 翻页条

struct PreviewMainView: View {
    @EnvironmentObject private var doc: DocumentStore
    @State private var sidebar: Int = 0          // 0 缩略图 1 标签 2 大纲
    @State private var thumbs: [Int: NSImage] = [:]
    @State private var currentPage: Int = 0
    @State private var revisionForCache: Int = -1
    @State private var sidebarWidth: CGFloat = 216   // 左栏宽度，可拖动调整
    @State private var dragStartWidth: CGFloat? = nil
    private let controller = PDFPageController()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Picker("", selection: $sidebar) {
                    Text(L("缩略图")).tag(0)
                    Text(L("标签")).tag(1)
                    Text(L("大纲")).tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                Divider()
                switch sidebar {
                case 0: thumbnailPane
                case 1: outlinePane(flat: true)
                default: outlinePane(flat: false)
                }
            }
            .frame(width: sidebarWidth)
            // 可拖动分隔条：拖动调整左栏宽度；缩略图列数随宽度自适应（宽→2列，窄→1列）
            Rectangle()
                .fill(Color.clear)
                .frame(width: 6)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            if dragStartWidth == nil { dragStartWidth = sidebarWidth }
                            sidebarWidth = min(max((dragStartWidth ?? 216) + v.translation.width, 160), 460)
                        }
                        .onEnded { _ in dragStartWidth = nil }
                )
            VStack(spacing: 0) {
                PDFPageView(controller: controller) { page in
                    currentPage = page
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                pagerBar
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
        }
        .onChange(of: doc.revision) { _ in
            thumbs.removeAll()   // 页操作后缩略图整体失效
        }
        .onAppear {
            // 页面管理双击某页跳转过来：定位到该页（异步等 PDFView 就绪）
            if let p = doc.pendingJumpPage {
                doc.pendingJumpPage = nil
                DispatchQueue.main.async { controller.goto(p) }
            }
        }
    }

    // MARK: 缩略图

    private var thumbnailPane: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 10)], spacing: 10) {
                ForEach(0..<doc.pageCount, id: \.self) { i in
                    VStack(spacing: 4) {
                        Image(nsImage: thumb(at: i))
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 110)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(i == currentPage ? Color.accentColor : Color(nsColor: .separatorColor),
                                            lineWidth: i == currentPage ? 2 : 0.5)
                            )
                        Text("\(i + 1)")
                            .font(.caption2)
                            .foregroundStyle(i == currentPage ? Color.accentColor : .secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { controller.goto(i) }
                }
            }
            .padding(10)
        }
    }

    private func thumb(at index: Int) -> NSImage {
        if let t = thumbs[index] { return t }
        guard let p = doc.document?.page(at: index) else { return NSImage() }
        let size = PageBox.displayedSize(p)
        let scale = 170.0 / max(size.width, 1)
        let img = p.thumbnail(of: CGSize(width: 170, height: max(size.height * scale, 40)),
                              for: .mediaBox)
        thumbs[index] = img
        return img
    }

    // MARK: 标签 / 大纲（均来自 PDFOutline：标签=一级平铺，大纲=整树缩进）

    private func outlinePane(flat: Bool) -> some View {
        let rows: [OutlineRow] = {
            guard let root = doc.document?.outlineRoot else { return [] }
            return flat ? flatten(root, level: 0).filter { $0.level == 0 }
                        : flatten(root, level: 0)
        }()
        return Group {
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.left").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(L("本文档没有目录")).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { row in
                            Text(row.title)
                                .lineLimit(1)
                                .font(.system(size: 13))
                                .padding(.leading, CGFloat(row.level * 14 + 8))
                                .padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let p = row.pageIndex { controller.goto(p) }
                                }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func flatten(_ outline: PDFOutline?, level: Int) -> [OutlineRow] {
        guard let outline else { return [] }
        var rows: [OutlineRow] = []
        for i in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: i) else { continue }
            let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else {
                rows += flatten(child, level: level)   // 无标题节点下钻
                continue
            }
            let pageIndex = child.destination?.page.flatMap { doc.document?.index(for: $0) }
            rows.append(OutlineRow(level: level, title: title, pageIndex: pageIndex))
            rows += flatten(child, level: level + 1)
        }
        return rows
    }

    // MARK: 翻页条

    private var pagerBar: some View {
        HStack(spacing: 14) {
            Spacer()
            Button { controller.step(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(currentPage <= 0)
            Text(LF("第 %d / %d 页", currentPage + 1, doc.pageCount))
                .font(.callout)
                .monospacedDigit()
            Button { controller.step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(currentPage >= doc.pageCount - 1)
            Spacer()
        }
    }
}

struct OutlineRow: Identifiable {
    let id = UUID()
    let level: Int
    let title: String
    let pageIndex: Int?
}

// MARK: - PDFView 包装（单页模式 + 翻页控制）

@MainActor
final class PDFPageController {
    fileprivate weak var view: PDFView?

    func goto(_ page: Int) {
        guard let v = view, let d = v.document, let p = d.page(at: page) else { return }
        v.go(to: p)
    }

    func step(_ delta: Int) {
        guard let v = view, let d = v.document, let cur = v.currentPage else { return }
        let j = min(max(d.index(for: cur) + delta, 0), d.pageCount - 1)
        if let p = d.page(at: j) { v.go(to: p) }
    }
}

struct PDFPageView: NSViewRepresentable {
    let controller: PDFPageController
    let onPageChange: (Int) -> Void

    @EnvironmentObject private var doc: DocumentStore

    final class Coordinator {
        var observer: NSObjectProtocol?
        let onPageChange: (Int) -> Void
        init(_ cb: @escaping (Int) -> Void) { onPageChange = cb }
        deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPageChange) }

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.displayMode = .singlePageContinuous   // 连续滚动浏览（可上下拖动），翻页条/缩略图/大纲仍可跳页
        v.autoScales = true
        v.document = doc.document
        controller.view = v
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: v, queue: .main
        ) { [weak v, coordinator = context.coordinator] _ in
            guard let v, let d = v.document, let cur = v.currentPage else { return }
            coordinator.onPageChange(d.index(for: cur))
        }
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        controller.view = v   // 每次都回填：视图重建后新 controller 实例必须拿到 NSView
        if v.document !== doc.document {
            v.document = doc.document
        }
    }
}
