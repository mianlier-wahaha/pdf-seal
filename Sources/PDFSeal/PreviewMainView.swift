import SwiftUI
import PDFKit
import AppKit
import SealCore

// MARK: - 预览主界面（默认落点）：左栏 缩略图/标签/大纲 + 单页大图 + 翻页条

struct PreviewMainView: View {
    @EnvironmentObject private var doc: DocumentStore
    @State private var sidebar: Int = 0          // 0 缩略图 1 标签 2 大纲
    /// 全局共享缩略图缓存（按文档身份隔离 + 后台预取）：切标签回来零重渲染
    @ObservedObject private var thumbStore = ThumbStore.shared
    @State private var currentPage: Int = 0
    @State private var revisionForCache: Int = -1
    @State private var sidebarWidth: CGFloat = 216   // 左栏宽度，可拖动调整
    @State private var dragStartWidth: CGFloat? = nil
    @State private var editingPage = false           // 当前页数字点击后进入输入跳页
    @State private var pageInput = ""
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
            // 关键：用全局坐标计算位移——视图自身随宽度移动，若用本地坐标会形成
            // 「移动→坐标漂移→再移动」的反馈回路，表现为果冻般弹性 + 抽搐
            Rectangle()
                .fill(Color.clear)
                .frame(width: 6)
                .contentShape(Rectangle())
                .onHover { hovering in
                    NSCursor.resizeLeftRight.set()
                    if !hovering { NSCursor.arrow.set() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in
                            if dragStartWidth == nil { dragStartWidth = sidebarWidth }
                            let dx = v.location.x - v.startLocation.x   // 全局差值，与分隔条自身移动无关
                            sidebarWidth = min(max((dragStartWidth ?? 216) + dx, 160), 460)
                        }
                        .onEnded { _ in
                            dragStartWidth = nil
                            NSCursor.arrow.set()
                        }
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
            thumbStore.invalidate(document: doc.document)   // 页操作后整本失效重渲染
        }
        .onChange(of: doc.url) { _ in
            // 切换会话（换文档）：新文档载入即预取；旧文档缓存保留（切回即用）
            thumbStore.prefetch(document: doc.document, width: 170)
        }
        .onAppear {
            thumbStore.prefetch(document: doc.document, width: 170)
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
                        Group {
                            if let d = doc.document,
                               let img = thumbStore.image(for: ObjectIdentifier(d), page: i) {
                                Image(nsImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 110)
                            } else {
                                // 占位：按真实页型比例留位，后台渲染完成后自动替换
                                let asp = doc.pageSizes.indices.contains(i)
                                    ? max(doc.pageSizes[i].width / max(doc.pageSizes[i].height, 1), 0.3)
                                    : 0.707
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .aspectRatio(asp, contentMode: .fit)
                                    .frame(maxHeight: 110)
                                    .overlay(ProgressView().controlSize(.mini))
                            }
                        }
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
                    .onAppear { requestThumb(i) }
                }
            }
            .padding(10)
        }
    }

    /// 请求某页缩略图：命中全局缓存即时返回；未命中由 ThumbStore 后台渲染（防重复提交）
    private func requestThumb(_ index: Int) {
        guard let d = doc.document else { return }
        thumbStore.request(document: d, page: index, width: 170)
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
            if editingPage {
                TextField(L("页"), text: $pageInput, onCommit: { commitJump() })
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .multilineTextAlignment(.center)
                    .onExitCommand { editingPage = false }   // Esc 取消
                    .font(.callout.monospacedDigit())
            } else {
                HStack(spacing: 3) {
                    Text(L("第"))
                    Text("\(currentPage + 1)")
                        .foregroundStyle(Color.accentColor)
                        .underline()
                        .onTapGesture {
                            pageInput = "\(currentPage + 1)"
                            editingPage = true
                        }
                        .help(L("点击输入页码跳转"))
                    Text(LF("/ %d 页", doc.pageCount))
                }
                .font(.callout)
                .monospacedDigit()
            }
            Button { controller.step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(currentPage >= doc.pageCount - 1)
            Spacer()
        }
    }

    /// 输入页码跳转：越界自动钳制，非法输入忽略
    private func commitJump() {
        editingPage = false
        guard let n = Int(pageInput.trimmingCharacters(in: .whitespaces)), n >= 1 else { return }
        let target = min(n, doc.pageCount)
        controller.goto(target - 1)
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
