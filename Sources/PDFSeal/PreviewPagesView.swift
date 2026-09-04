import SwiftUI
import CoreGraphics
import SealCore

struct PreviewPagesView: View {
    @EnvironmentObject private var doc: DocumentStore
    @EnvironmentObject private var settings: StampSettings
    var statusText: String? = nil

    @State private var zoomPercent: Double = 100
    @State private var pageInput: Int = 1
    @State private var pinchBase: Double?
    private let presets = [25, 50, 75, 100, 150, 200]

    private var displayWidth: CGFloat {
        470 * CGFloat(min(max(zoomPercent, 10), 400) / 100)
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach(0..<doc.pageCount, id: \.self) { i in
                            PagePreview(index: i, displayW: displayWidth)
                                .id(i)
                        }
                    }
                    .padding(.vertical, 16)
                }
                .onChange(of: settings.fullStamps.count) { _ in
                    // 点「添加」新增章后，自动滚到该章页范围的起始页
                    if let inst = settings.selectedInstance, doc.pageCount > 0 {
                        let target = inst.effectiveRange(pageCount: doc.pageCount).lowerBound
                        withAnimation {
                            proxy.scrollTo(target, anchor: .center)
                        }
                        pageInput = target + 1
                    }
                }
                // 触控板双指捏合缩放
                .gesture(
                    MagnificationGesture()
                        .onChanged { v in
                            if pinchBase == nil { pinchBase = zoomPercent }
                            zoomPercent = min(max((pinchBase! * v), 10), 400)
                        }
                        .onEnded { _ in pinchBase = nil }
                )
                statusBar(proxy: proxy)
            }
        }
    }

    /// 底部状态栏：缩放百分比（可输入+下拉预设）、页码跳转
    private func statusBar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 14) {
            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()

            HStack(spacing: 4) {
                // 缩放输入框：下拉按钮集成在框内部右侧
                HStack(spacing: 2) {
                    TextField(L("缩放"), value: $zoomPercent,
                              format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { zoomPercent = min(max(zoomPercent, 10), 400) }
                    Menu {
                        ForEach(presets, id: \.self) { p in
                            Button("\(p)%") { zoomPercent = Double(p) }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 18)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.leading, 8)
                .padding(.trailing, 2)
                .frame(width: 84, height: 22)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                Text("%").font(.caption).foregroundStyle(.secondary)
            }

            Divider().frame(height: 16)

            HStack(spacing: 4) {
                TextField(L("页码"), value: $pageInput,
                          format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 46)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { jumpTo(proxy: proxy) }
                Text("/ \(doc.pageCount)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func jumpTo(proxy: ScrollViewProxy) {
        guard doc.pageCount > 0 else { return }
        let target = min(max(pageInput, 1), doc.pageCount)
        pageInput = target
        withAnimation {
            proxy.scrollTo(target - 1, anchor: .top)
        }
    }
}

struct PagePreview: View {
    @EnvironmentObject private var doc: DocumentStore
    @EnvironmentObject private var seals: SealStore
    @EnvironmentObject private var settings: StampSettings

    let index: Int
    let displayW: CGFloat
    @State private var thumb: NSImage?
    @State private var resizeUndoID: UUID?

    /// 预览页宽（pt 显示）
    var body: some View {
        let size = index < doc.pageSizes.count ? doc.pageSizes[index] : CGSize(width: 595, height: 842)
        let displayH = displayW * size.height / max(size.width, 1)
        ZStack(alignment: .topLeading) {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .frame(width: displayW, height: displayH)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            } else {
                Rectangle()
                    .fill(.quaternary.opacity(0.3))
                    .frame(width: displayW, height: displayH)
                    .overlay { ProgressView() }
            }
            qifengOverlays(displayH: displayH)
            fullStampOverlays(displayH: displayH)
        }
        .frame(width: displayW, height: displayH)
        .coordinateSpace(name: "page-\(index)")
        .onTapGesture { location in
            // 正文章模式：点击空白处 = 在该位置新增一枚章（仅盖此页，不自动选中/不显示控制框）；
            // 再点击该章才选中显示控制框
            guard settings.pageCount > 0 else { return }
            let pt = CGPoint(x: min(max(location.x / displayW, 0.02), 0.98),
                             y: min(max(location.y / displayH, 0.02), 0.98))
            settings.addFullStamp(sealID: seals.selectedID, pageIndex: index, anchor: pt)
            settings.selectedFullStampID = nil
        }
        .onHover { hovering in
            guard settings.pageCount > 0 else { return }
            if hovering {
                NSCursor.crosshair.push()
            } else {
                NSCursor.pop()
            }
        }
        .task(id: "\(doc.url?.absoluteString ?? "")|\(Int(displayW))") {
            thumb = renderThumb(aspect: size.height / max(size.width, 1))
        }
    }

    private func renderThumb(aspect: CGFloat) -> NSImage? {
        guard let page = doc.document?.page(at: index) else { return nil }
        let w = displayW * 2
        return page.thumbnail(of: CGSize(width: w, height: w * aspect), for: .mediaBox)
    }

    /// 渲染本页上的所有骑缝章条（每条实例独立，可按页删除/恢复）
    private static func qifengConfig(for q: QifengInstance, pageCount: Int) -> QifengConfig {
        var c = QifengConfig()
        c.edge = q.edge
        c.range = q.effectiveRange(pageCount: pageCount)
        c.sizeRatio = CGFloat(q.size)
        c.offset = CGFloat(q.offset)
        return c
    }

    private func qifengOverlays(displayH: CGFloat) -> some View {
        ForEach(settings.qifengStamps) { (q: QifengInstance) in
            if q.effectiveRange(pageCount: settings.pageCount).contains(index) {
                let removed = q.removedPages.contains(index)
                let c = Self.qifengConfig(for: q, pageCount: settings.pageCount)
                let placements = StampGeometry.qifeng(config: c, pageSizes: doc.pageSizes,
                                                      sealAspect: seals.aspect(for: q.sealID),
                                                      opacity: CGFloat(settings.qifengOpacity))
                    .filter { $0.pageIndex == index }
                ForEach(Array(placements.enumerated()), id: \.offset) { _, pl in
                    let w = pl.destNorm.width * displayW
                    let h = pl.destNorm.height * displayH
                    let x = pl.destNorm.minX * displayW
                    let y = pl.destNorm.minY * displayH
                    Group {
                        if removed {
                            // 已删除：虚线占位框，右键恢复
                            Rectangle()
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .foregroundStyle(.orange.opacity(0.45))
                                .frame(width: w, height: h)
                                .offset(x: x, y: y)
                                .contentShape(Rectangle())
                                .contextMenu {
                                    Button(L("恢复本页骑缝章条")) {
                                        settings.restoreQifengPage(index, of: q.id)
                                    }
                                }
                        } else if let slice = seals.sliceImage(for: q.sealID, source: pl.source) {
                            Image(nsImage: slice)
                                .resizable()
                                .frame(width: w, height: h)
                                .offset(x: x, y: y)
                                .contextMenu {
                                    Button(L("删除本页骑缝章条"), role: .destructive) {
                                        settings.removeQifengPage(index, of: q.id)
                                    }
                                    Button(L("删除此骑缝章（所有页）"), role: .destructive) {
                                        settings.removeQifengStamp(q.id)
                                    }
                                }
                        }
                    }
                }
            }
        }
    }

    /// 渲染本页上的所有正文章实例（选中章带四角缩放手柄）
    @ViewBuilder
    private func fullStampOverlays(displayH: CGFloat) -> some View {
        ForEach(settings.fullStamps) { inst in
            if let seal = seals.image(for: inst.sealID) {
                if inst.covers(index, pageCount: settings.pageCount) {
                    // 物理尺寸 → 当前页显示像素
                    let pagePt = index < doc.pageSizes.count ? doc.pageSizes[index] : CGSize(width: 595, height: 842)
                    let cmScale = displayW / max(pagePt.width, 1)   // 显示像素 / pt
                    let w = CGFloat(inst.widthCm * 28.3465) * cmScale
                    let h = CGFloat(inst.heightCm * 28.3465) * cmScale
                    let x = inst.anchor.x * displayW - w / 2
                    let y = inst.anchor.y * displayH - h / 2
                    if inst.removedPages.contains(index) {
                        // 已按页删除：虚线占位框，右键恢复
                        Rectangle()
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.orange.opacity(0.45))
                            .frame(width: w, height: h)
                            .offset(x: x, y: y)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button(L("恢复本页章")) {
                                    settings.restorePage(index, of: inst.id)
                                }
                            }
                    } else {
                        FullStampDraggableView(instanceID: inst.id,
                                               pageIndex: index, seal: seal,
                                               w: w, h: h, x: x, y: y,
                                               rotation: inst.rotation,
                                               opacity: inst.opacity,
                                               isSelected: inst.id == settings.selectedFullStampID,
                                               displayW: displayW, displayH: displayH)
                            .contextMenu {
                                Button(L("删除本页章"), role: .destructive) {
                                    settings.removePage(index, of: inst.id)
                                }
                                Button(L("删除此章（所有页）"), role: .destructive) {
                                    settings.removeFullStamp(inst.id)
                                }
                            }
                        // 选中章：四角缩放手柄
                        if inst.id == settings.selectedFullStampID {
                            cornerHandles(inst: inst, w: w, h: h, displayH: displayH)
                        }
                    }
                }
            }
        }
    }

    private func cornerHandles(inst: FullStampInstance, w: CGFloat, h: CGFloat,
                               displayH: CGFloat) -> some View {
        let cx = inst.anchor.x * displayW
        let cy = inst.anchor.y * displayH
        let signs: [(CGFloat, CGFloat)] = [(-1, -1), (1, -1), (-1, 1), (1, 1)]
        return ForEach(0..<4, id: \.self) { ci in
            Group {
                if ci == 3 {
                    // 仅右下角控制点可缩放：高优先级手势，光标为斜向箭头
                    Circle()
                        .fill(Color.orange)
                        .overlay { Circle().strokeBorder(Color.white, lineWidth: 1.5) }
                        .frame(width: 12, height: 12)
                        .position(x: cx + signs[ci].0 * w / 2, y: cy + signs[ci].1 * h / 2)
                        .contentShape(Circle().inset(by: -8))
                        .highPriorityGesture(resizeGesture(inst: inst, corner: ci,
                                                           cx: cx, cy: cy, w: w, h: h,
                                                           displayH: displayH))
                        .onHover { hovering in
                            if hovering { NSCursor.crosshair.push() } else { NSCursor.pop() }
                        }
                } else {
                    // 其余三个角点仅装饰：不拦截事件，拖动穿透到章体（移动）
                    Circle()
                        .fill(Color.orange.opacity(0.55))
                        .overlay { Circle().strokeBorder(Color.white, lineWidth: 1.5) }
                        .frame(width: 10, height: 10)
                        .position(x: cx + signs[ci].0 * w / 2, y: cy + signs[ci].1 * h / 2)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// 拖角等比缩放：对角固定，按指针到对角的垂直距离定新高度
    private func resizeGesture(inst: FullStampInstance, corner: Int,
                               cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat,
                               displayH: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("page-\(index)"))
            .onChanged { v in
                guard let i = settings.fullStamps.firstIndex(where: { $0.id == inst.id }) else { return }
                if resizeUndoID != inst.id {
                    settings.pushUndo(inst.id)   // 本次缩放开始前记快照
                    resizeUndoID = inst.id
                }
                let aspect = seals.aspect(for: inst.sealID)
                let pageH = index < doc.pageSizes.count ? doc.pageSizes[index].height : 842
                let sx: CGFloat = (corner == 0 || corner == 2) ? -1 : 1
                let sy: CGFloat = (corner == 0 || corner == 1) ? -1 : 1
                let oppX = cx - sx * w / 2
                let oppY = cy - sy * h / 2
                let newH = max(24, abs(v.location.y - oppY))
                let newW = max(24, newH * aspect)
                let newHcm = Double(newH / displayH * pageH / 28.3465)
                let newWcm = newHcm * Double(aspect)
                let newCx = oppX + sx * newW / 2
                let newCy = oppY + sy * newH / 2
                settings.fullStamps[i].heightCm = newHcm
                settings.fullStamps[i].widthCm = newWcm
                settings.fullStamps[i].anchor = CGPoint(
                    x: min(max(newCx / displayW, 0.02), 0.98),
                    y: min(max(newCy / displayH, 0.02), 0.98))
            }
            .onEnded { _ in
                resizeUndoID = nil
                // 缩放结束：物理尺寸固化到该章（下次添加沿用）
                if let cur = settings.selectedInstance {
                    settings.fullWidthCm = cur.widthCm
                    settings.fullHeightCm = cur.heightCm
                    seals.fixPhysicalSize(widthCm: cur.widthCm, heightCm: cur.heightCm,
                                          for: cur.sealID)
                }
            }
    }
}

private struct FullStampDraggableView: View {
    @EnvironmentObject private var settings: StampSettings
    let instanceID: UUID
    let pageIndex: Int
    let seal: NSImage
    let w: CGFloat, h: CGFloat, x: CGFloat, y: CGFloat
    let rotation: Double
    let opacity: Double
    let isSelected: Bool
    let displayW: CGFloat, displayH: CGFloat

    @State private var dragStart: CGPoint?

    var body: some View {
        Image(nsImage: seal)
            .resizable()
            .frame(width: w, height: h)
            .overlay {
                // 仅选中的章显示虚线框
                if isSelected {
                    Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundStyle(Color.orange.opacity(0.9))
                }
            }
            .background {
                // 稍大的隐形热区，方便抓取
                Color.clear
                    .frame(width: w + 24, height: h + 24)
                    .contentShape(Rectangle())
            }
            .rotationEffect(.degrees(rotation))
            .opacity(opacity)
            .offset(x: x, y: y)
            // 拖移手势：系统「三指拖移」开启时无需按下即可拖动；鼠标点击按住拖动亦可
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        if dragStart == nil {
                            dragStart = settings.anchor(of: instanceID)
                            settings.pushUndo(instanceID)   // 拖动前记快照
                        }
                        guard let s = dragStart else { return }
                        settings.setAnchor(of: instanceID, to: CGPoint(
                            x: min(max(s.x + v.translation.width / displayW, 0.02), 0.98),
                            y: min(max(s.y + v.translation.height / displayH, 0.02), 0.98)))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.openHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}
