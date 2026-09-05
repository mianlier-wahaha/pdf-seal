import SwiftUI
import SealCore

struct ParamsPanelView: View {
    @EnvironmentObject private var doc: DocumentStore
    @EnvironmentObject private var seals: SealStore
    @EnvironmentObject private var settings: StampSettings

    /// 正在用滑杆调尺寸的章（用于只在拖动开始时记一次撤销快照）
    @State private var sizeDragID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(L("骑缝章")) {
                    Picker("缝位", selection: $settings.edge) {
                        ForEach(SeamEdge.allCases) { e in Text(L(e.label)).tag(e) }
                    }
                    .pickerStyle(.segmented)
                    rangeControls(all: $settings.allPages,
                                  start: $settings.rangeStart,
                                  end: $settings.rangeEnd)
                    // 拖动实时调整最新一条骑缝章的上下位置，同时作为下一条的默认偏移
                    HStack(spacing: 8) {
                        Text(L("上")).font(.caption).foregroundStyle(.secondary)
                        OffsetSlider(value: settings.qifengOffset) { v in
                            settings.qifengOffset = v
                            if let last = settings.qifengStamps.indices.last {
                                settings.qifengStamps[last].offset = v
                            }
                        }
                        Text(L("下")).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Button {
                            settings.addQifengStamp(sealID: seals.selectedID)
                        } label: {
                            Label(L("添加"), systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(doc.document == nil || seals.selectedID == nil)
                        if !settings.qifengStamps.isEmpty {
                            Button(role: .destructive) {
                                settings.removeAllQifengStamps()
                            } label: {
                                Label(L("移除全部"), systemImage: "trash")
                            }
                        }
                    }
                    if !settings.qifengStamps.isEmpty {
                        Text(LF("已添加 %d 条骑缝章；调整本滑杆后点「添加」可错开上下位置", settings.qifengStamps.count))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section(L("正文章")) {
                    Text(L("添加一枚按当前选项盖章的章；可多次添加多枚。添加后点击页面落位、拖动微调、右键章可删除"))
                        .font(.caption).foregroundStyle(.secondary)
                    rangeControls(all: $settings.fullAllPages,
                                  start: $settings.fullRangeStart,
                                  end: $settings.fullRangeEnd)
                    HStack(spacing: 10) {
                        Button {
                            settings.addFullStamp(sealID: seals.selectedID)
                        } label: {
                            Label(L("添加"), systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(doc.document == nil || seals.selectedID == nil)
                        if !settings.fullStamps.isEmpty {
                            Button(role: .destructive) {
                                settings.removeAllFullStamps()
                            } label: {
                                Label(L("移除全部"), systemImage: "trash")
                            }
                        }
                    }
                    if !settings.fullStamps.isEmpty {
                        Text(LF("已添加 %d 枚章；点击预览中的章可选中它；按住 ⌘ 点击可累加选择多枚", settings.fullStamps.count))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // 选中信息：计数 + 移除（多选时一并移除）；尺寸滑杆仅单选时显示
                    if !settings.fullStamps.isEmpty {
                        let count = settings.selectedFullStampIDs.count
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(LF("已选中 %d 枚 / 共 %d 枚", count, settings.fullStamps.count))
                                    .font(.callout)
                                Spacer()
                                Button(role: .destructive) {
                                    settings.removeSelectedFullStamps()
                                } label: {
                                    Label(L("移除"), systemImage: "trash")
                                }
                                .disabled(count == 0)
                                .help(L("移除选中的章（Delete 键）"))
                            }
                            // 仅单选时显示尺寸滑杆（调整主选中章的物理大小）
                            if let inst = settings.selectedInstance, count == 1 {
                                let aspect = seals.aspect(for: inst.sealID)
                                HStack {
                                    Text(L("章体大小")).font(.callout)
                                    Spacer()
                                    Text(String(format: "%.1f × %.1f cm",
                                                settings.selectedInstance?.widthCm ?? inst.widthCm,
                                                settings.selectedInstance?.heightCm ?? inst.heightCm))
                                        .font(.caption).monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                OffsetSlider(value: settings.selectedInstance?.heightCm ?? inst.heightCm,
                                             range: 1...20,
                                             onChanged: { v in
                                    if sizeDragID != inst.id {
                                        settings.pushUndo(inst.id)   // 本次调整开始前记快照
                                        sizeDragID = inst.id
                                    }
                                    settings.setSize(widthCm: v * Double(aspect), heightCm: v, of: inst.id)
                                }, onEnded: {
                                    if let cur = settings.selectedInstance {
                                        seals.fixPhysicalSize(widthCm: cur.widthCm, heightCm: cur.heightCm,
                                                              for: cur.sealID)
                                    }
                                    sizeDragID = nil
                                })
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func rangeControls(all: Binding<Bool>, start: Binding<Int>, end: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L("全部页"), isOn: all)
            if !all.wrappedValue {
                HStack {
                    Text(L("页码"))
                    pageField(start)
                    Text("—")
                    pageField(end)
                    Spacer()
                }
            }
        }
    }

    private func pageField(_ value: Binding<Int>) -> some View {
        TextField("", value: value, format: .number.grouping(.never))
            .multilineTextAlignment(.center)
            .frame(width: 52)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                let total = max(doc.pageCount, 1)
                value.wrappedValue = min(max(value.wrappedValue, 1), total)
            }
    }
}

/// 自绘滑杆：轨道铺满可用宽度（Form 对系统 Slider 有固有宽度限制）
private struct OffsetSlider: View {
    let value: Double
    var range: ClosedRange<Double> = -0.35...0.35
    let onChanged: (Double) -> Void
    var onEnded: (() -> Void)? = nil

    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let knobX = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)) * w
            ZStack(alignment: .leading) {
                // 轨道
                Capsule()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 4)
                // 已选段
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, knobX), height: 4)
                // 圆点
                Circle()
                    .fill(Color.white)
                    .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: 2) }
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                    .frame(width: 18, height: 18)
                    .position(x: knobX, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { d in
                        dragging = true
                        let frac = min(max(d.location.x / w, 0), 1)
                        onChanged(range.lowerBound + Double(frac) * (range.upperBound - range.lowerBound))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEnded?()
                    }
            )
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
    }
}
