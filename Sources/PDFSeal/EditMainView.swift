import SwiftUI
import PDFKit
import AppKit

// MARK: - 编辑主界面：右侧竖向工具栏 + 每工具参数面板
//
// 实现要点：
// - 工具栏竖排贴主界面右侧（UPDF 风格），点选工具后在其左侧弹出参数面板：
//   顶部「示例」预览实时反映颜色/宽度/线型等设置，下方为参数区。
// - 批注基于 PDFAnnotation，直接挂到内存文档的页上；保存/另存为随文档写出。
// - 图片批注/图案形状/可旋转文本均为 PDFAnnotation 子类重写 draw(with:in:)，
//   保存时 PDFKit 把 draw 内容记录为外观流（WWDC22 行为），其他阅读器可见。
// - 手绘笔（.pen）在拖动过程中逐点采集页面坐标，松手后平滑并生成 Ink 批注。
// - 下划线工具内含「直线/波浪」两种样式（波浪用 Ink 正弦波，macOS 无 Squiggly）。
// - 形状工具含 矩形/椭圆/直线/箭头/双箭头 + 边框线型 + 填充图案 + 描边/填充色。
// - 橡皮擦带尺寸圈（跟随鼠标的半透明圆），拖动可连续擦除。
// - 工具激活时拦截鼠标事件（不调 super），滚动不被误触；浏览模式下交还 PDFView。

enum EditTool: Hashable {
    case highlight, underline, strikeOut
    case pen                // 手绘笔
    case shape              // 矩形/椭圆/直线/箭头/双箭头
    case textBox
    case eraser
    case redact             // 隐藏
}

/// 「形状」工具的子类型
enum ShapeVariant: Hashable, CaseIterable {
    case rect, ellipse, line, arrow, doubleArrow

    var symbol: String {
        switch self {
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .doubleArrow: return "arrow.left.and.right"
        }
    }
    var nameKey: String {
        switch self {
        case .rect: return "矩形"
        case .ellipse: return "椭圆"
        case .line: return "直线"
        case .arrow: return "箭头"
        case .doubleArrow: return "双箭头"
        }
    }
}

/// 形状边框线型（对应参数面板「边框类型」）
enum ShapeBorderStyle: Hashable, CaseIterable {
    case solid, dashed, dotted, dashDot

    var dash: [CGFloat]? {
        switch self {
        case .solid: return nil
        case .dashed: return [6, 4]
        case .dotted: return [1.2, 3]
        case .dashDot: return [6, 3, 1.2, 3]
        }
    }
    var nameKey: String {
        switch self {
        case .solid: return "实线"
        case .dashed: return "虚线"
        case .dotted: return "点线"
        case .dashDot: return "点划线"
        }
    }
}

/// 形状内部填充图案（对应参数面板「线条图案」）
enum ShapeFillPattern: Hashable, CaseIterable {
    case none, diagonal, crosshatch, dots
    var nameKey: String {
        switch self {
        case .none: return "无"
        case .diagonal: return "斜线"
        case .crosshatch: return "网格"
        case .dots: return "圆点"
        }
    }
}

// MARK: 工具参数（所有工具的设置集中在这一结构里，随面板修改实时同步到 PDFView）

struct ToolSettings {
    // 高亮
    var highlightColor: Color = Color(red: 1.0, green: 0.85, blue: 0.20)
    // 下划线（含波浪样式）
    var underlineColor: Color = Color(red: 0.95, green: 0.20, blue: 0.20)
    var underlineWavy = false
    var underlineWidth: Double = 2
    // 删除线
    var strikeColor: Color = Color(red: 0.95, green: 0.20, blue: 0.20)
    var strikeWidth: Double = 2
    // 手绘笔
    var penColor: Color = Color(red: 0.95, green: 0.20, blue: 0.20)
    var penWidth: Double = 3
    var penSmooth = true        // 笔触灵敏度：开 = 平滑笔触
    var penOpacity: Double = 1.0
    // 橡皮擦
    var eraserSize: Double = 10
    var eraserPartial = false   // false = 触及整条消失；true = 只擦除触及部分
    // 隐藏工具填充色
    var redactColor: Color = .black
    // 文本
    var textFontName = "PingFang SC"
    var textSize: Double = 25
    var textBold = false
    var textItalic = false
    var textColor: Color = Color(red: 0.95, green: 0.20, blue: 0.20)
    var textBgColor: Color? = nil
    var textRotation: Double = 0        // 度；90 的倍数
    // 形状
    var shapeVariant: ShapeVariant = .rect
    var shapeStrokeWidth: Double = 3
    var shapeBorderStyle: ShapeBorderStyle = .solid
    var shapePattern: ShapeFillPattern = .none
    var shapeOpacity: Double = 1.0
    var shapeStrokeColor: Color = Color(red: 0.95, green: 0.20, blue: 0.20)
    var shapeFillColor: Color? = nil

    var shapeDash: [CGFloat]? { shapeBorderStyle.dash }

    func textFont() -> NSFont {
        let base = NSFont(name: textFontName, size: CGFloat(textSize)) ?? .systemFont(ofSize: CGFloat(textSize))
        var f = base
        let mgr = NSFontManager.shared
        if textBold { f = mgr.convert(f, toHaveTrait: .boldFontMask) }
        if textItalic { f = mgr.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }
}

struct EditMainView: View {
    @EnvironmentObject private var doc: DocumentStore
    @State private var tool: EditTool? = nil
    @State private var settings = ToolSettings()
    @ObservedObject private var undoCenter = UndoCenter.shared   // 全局撤销/重做（批注+章+页面 三路时间线）

    static let swatches: [Color] = [
        Color(red: 1.00, green: 0.85, blue: 0.20),   // 黄
        Color(red: 0.95, green: 0.20, blue: 0.20),   // 红
        Color(red: 0.95, green: 0.50, blue: 0.10),   // 橙
        Color(red: 0.15, green: 0.70, blue: 0.35),   // 绿
        Color(red: 0.20, green: 0.40, blue: 0.90),   // 蓝
        Color(red: 0.60, green: 0.20, blue: 0.85),   // 紫
        Color(red: 0.05, green: 0.05, blue: 0.05),   // 黑
    ]
    // 背景颜色与文本颜色共用同一套色板（v2.8.0），不再单设浅色板

    static let allTools: [EditTool] = [
        .highlight, .underline, .strikeOut, .pen, .eraser, .shape, .textBox, .redact,
    ]

    static let toolIcons: [EditTool: String] = [
        .highlight: "highlighter", .underline: "underline", .strikeOut: "strikethrough",
        .pen: "pencil.tip", .textBox: "text.badge.plus",
        .shape: "square.on.circle",
        .eraser: "eraser",
        .redact: "eye.slash",
    ]
    static let toolNames: [EditTool: String] = [
        .highlight: "高亮", .underline: "下划线", .strikeOut: "删除线", .pen: "笔",
        .textBox: "文本框", .shape: "形状",
        .eraser: "橡皮擦",
        .redact: "隐藏",
    ]
    static let panelTitles: [EditTool: String] = [
        .highlight: "高亮工具", .underline: "下划线工具", .strikeOut: "删除线工具",
        .pen: "笔类工具", .textBox: "文本工具", .shape: "矩形工具",
        .eraser: "橡皮擦工具",
        .redact: "隐藏工具",
    ]

    static let fontChoices: [(String, String)] = [
        ("黑体（默认）", "PingFang SC"),
        ("宋体", "Songti SC"),
        ("楷体", "Kaiti SC"),
        ("仿宋", "STFangsong"),
        ("冬青黑体", "Hiragino Sans GB"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            editToolbar
            Divider()
            HStack(spacing: 0) {
                AnnotationPageView(tool: $tool, settings: $settings,
                                   onAdded: { undoCenter.refresh() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if tool != nil {
                    Divider()
                    toolPanel
                        .frame(width: 264)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(EditUndoKeyHandler { undoCenter.undo() })
    }

    // MARK: 顶栏（工具组居中；撤销/重做统一走应用顶栏全局按钮，此处不再重复放置）

    private var editToolbar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            ForEach(EditMainView.allTools, id: \.self) { t in
                Button {
                    tool = (tool == t) ? nil : t
                } label: {
                    HStack(spacing: 5) {
                        toolIcon(t)
                        Text(L(EditMainView.toolNames[t] ?? ""))
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(tool == t ? Color.accentColor.opacity(0.18) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(tool == t ? Color.accentColor : Color.clear, lineWidth: 1)
                )
                .help(L(EditMainView.toolNames[t] ?? ""))
                .handCursor()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// 工具图标：高亮=黄底 A；文本框=方框内 A；两者同尺寸同样式（A 字号一致）；其余用 SF Symbols
    @ViewBuilder
    private func toolIcon(_ t: EditTool) -> some View {
        switch t {
        case .highlight:
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(red: 1.0, green: 0.88, blue: 0.15))
                    .frame(width: 22, height: 18)
                Text("A")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(.black)
            }
        case .textBox:
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.primary.opacity(0.75), lineWidth: 1.3)
                    .frame(width: 22, height: 18)
                Text("A")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(.primary)
            }
        default:
            Image(systemName: EditMainView.toolIcons[t] ?? "questionmark")
                .font(.system(size: 14))
        }
    }

    // MARK: 工具参数面板（点选顶栏工具图标后显示在 PDF 区右侧）

    private var toolPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L(tool.flatMap { EditMainView.panelTitles[$0] } ?? ""))
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button {
                        tool = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("关闭"))
                }
                panelContent
                Text(hintText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var panelContent: some View {
        switch tool {
        case .highlight: highlightPanel
        case .underline: underlinePanel
        case .strikeOut: strikePanel
        case .pen: penPanel
        case .eraser: eraserPanel
        case .textBox: textPanel
        case .shape: shapePanel
        case .redact: redactPanel
        case nil: EmptyView()
        }
    }

    // MARK: 各工具面板

    private var highlightPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewBox {
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(settings.highlightColor.opacity(0.60))
                        .frame(width: 68, height: 32)
                    Text("示例")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.primary)
                }
            }
            sectionLabel("颜色")
            SwatchRow(color: $settings.highlightColor)
        }
    }

    private var underlinePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewBox {
                Text("示例")
                    .font(.system(size: 24))
                    .foregroundColor(.primary)
                    .underline(true, color: settings.underlineColor)
            }
            sectionLabel("颜色")
            SwatchRow(color: $settings.underlineColor)
            sectionLabel("样式")
            HStack(spacing: 8) {
                styleButton(selected: !settings.underlineWavy) {
                    lineStyleCanvas(wavy: false)
                } action: { settings.underlineWavy = false }
                styleButton(selected: settings.underlineWavy) {
                    lineStyleCanvas(wavy: true)
                } action: { settings.underlineWavy = true }
            }
            widthRow("线条宽度", $settings.underlineWidth, options: [1, 2, 3, 4, 6], unit: "pt")
        }
    }

    private var strikePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewBox {
                Text("示例")
                    .font(.system(size: 24))
                    .foregroundColor(.primary)
                    .strikethrough(true, color: settings.strikeColor)
            }
            sectionLabel("颜色")
            SwatchRow(color: $settings.strikeColor)
            widthRow("线条宽度", $settings.strikeWidth, options: [1, 2, 3, 4, 6], unit: "pt")
        }
    }

    private var penPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewBox {
                Canvas { ctx, size in
                    var p = Path()
                    let midY = size.height / 2
                    let amp = size.height * 0.30
                    // 平滑 S 曲线：单一正弦，1.25 个周期，无端点拐折
                    p.move(to: CGPoint(x: 10, y: midY))
                    var x: CGFloat = 10
                    while x < size.width - 10 {
                        x += 2
                        let t = (x - 10) / max(size.width - 20, 1)
                        p.addLine(to: CGPoint(x: x, y: midY - amp * sin(t * 2 * .pi * 1.25)))
                    }
                    ctx.stroke(p, with: .color(settings.penColor.opacity(settings.penOpacity)),
                               style: StrokeStyle(lineWidth: min(settings.penWidth, 9), lineCap: .round))
                }
            }
            widthRow("线条宽度", $settings.penWidth, options: [1, 2, 3, 5, 8, 12], unit: "pt")
            VStack(alignment: .leading, spacing: 4) {
                Text(L("笔触灵敏度")).font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $settings.penSmooth) {
                    Text(L("平滑")).tag(true)
                    Text(L("原始")).tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(L("平滑 = 自动圆滑抖动；原始 = 完全跟随鼠标轨迹"))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            opacityRow("不透明度", $settings.penOpacity)
            sectionLabel("颜色")
            SwatchRow(color: $settings.penColor)
        }
    }

    private var eraserPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewBox {
                // 橡皮擦实际擦除范围为圆形，预览同样用圆
                Circle()
                    .stroke(Color.secondary, lineWidth: 2)
                    .frame(width: 30, height: 30)
            }
            widthRow("大小", $settings.eraserSize, options: [5, 10, 15, 20, 30, 40], unit: "px")
            VStack(alignment: .leading, spacing: 4) {
                Text(L("擦除方式")).font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $settings.eraserPartial) {
                    Text(L("触及整条消失")).tag(false)
                    Text(L("只擦除触及部分")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewBox {
                Text("示例")
                    .font(.custom(settings.textFontName, size: min(settings.textSize, 30)))
                    .fontWeight(settings.textBold ? .bold : .regular)
                    .italic(settings.textItalic)
                    .foregroundColor(settings.textColor)
                    .rotationEffect(.degrees(Double(settings.textRotation)))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        if let bg = settings.textBgColor {
                            RoundedRectangle(cornerRadius: 3).fill(bg)
                        }
                    }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("字体")).font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $settings.textFontName) {
                    ForEach(EditMainView.fontChoices, id: \.1) { c in
                        Text(L(c.0)).tag(c.1)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 8) {
                Picker("", selection: $settings.textBold) {
                    Text(L("常规")).tag(false)
                    Text(L("粗体")).tag(true)
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Picker("", selection: $settings.textSize) {
                    ForEach([12.0, 14, 16, 18, 20, 25, 28, 36, 48], id: \.self) { s in
                        Text("\(Int(s)) pt").tag(s)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 8) {
                toggleIcon("bold", active: settings.textBold) { settings.textBold.toggle() }
                    .frame(maxWidth: .infinity)
                toggleIcon("italic", active: settings.textItalic) { settings.textItalic.toggle() }
                    .frame(maxWidth: .infinity)
            }
            sectionLabel("文本颜色")
            SwatchRow(color: $settings.textColor)
            optionalColorRow("背景颜色", $settings.textBgColor, EditMainView.swatches)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("旋转")).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button {
                        settings.textRotation = (settings.textRotation - 90).truncatingRemainder(dividingBy: 360)
                    } label: {
                        Label(L("向左"), systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        settings.textRotation = (settings.textRotation + 90).truncatingRemainder(dividingBy: 360)
                    } label: {
                        Label(L("向右"), systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shapePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewBox {
                shapePreviewCanvas
                    .frame(height: 84)
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: 6) {
                ForEach(ShapeVariant.allCases, id: \.self) { v in
                    Button {
                        settings.shapeVariant = v
                    } label: {
                        Image(systemName: v.symbol)
                            .font(.system(size: 13))
                            .frame(width: 38, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(settings.shapeVariant == v ? Color.accentColor.opacity(0.18) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(settings.shapeVariant == v ? Color.accentColor : Color.clear, lineWidth: 1))
                    .help(L(v.nameKey))
                }
            }
            widthRow("线条宽度", $settings.shapeStrokeWidth, options: [1, 2, 3, 5, 8, 12], unit: "pt")
            VStack(alignment: .leading, spacing: 4) {
                Text(L("边框类型")).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(ShapeBorderStyle.allCases, id: \.self) { s in
                        styleButton(width: 52, selected: settings.shapeBorderStyle == s) {
                            borderStyleCanvas(s)
                        } action: { settings.shapeBorderStyle = s }
                    }
                }
            }
            if settings.shapeVariant == .rect || settings.shapeVariant == .ellipse {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("填充图案")).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(ShapeFillPattern.allCases, id: \.self) { p in
                            styleButton(width: 52, selected: settings.shapePattern == p) {
                                patternCanvas(p)
                            } action: { settings.shapePattern = p }
                        }
                    }
                }
            }
            opacityRow("不透明度", $settings.shapeOpacity)
            sectionLabel("线条颜色")
            SwatchRow(color: $settings.shapeStrokeColor)
            // 直线/箭头/双箭头无内部区域，不显示填充颜色
            if settings.shapeVariant == .rect || settings.shapeVariant == .ellipse {
                optionalColorRow("填充颜色", $settings.shapeFillColor, EditMainView.swatches)
            }
        }
    }

    private var redactPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewBox {
                RoundedRectangle(cornerRadius: 2)
                    .fill(settings.redactColor)
                    .frame(width: 64, height: 28)
            }
            sectionLabel("填充颜色")
            SwatchRow(color: $settings.redactColor)
            Text(L("拖动遮盖敏感内容"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 面板通用小组件

    private func sectionLabel(_ key: String) -> some View {
        Text(L(key)).font(.caption).foregroundStyle(.secondary)
    }

    private func previewBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(height: 88)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.15), lineWidth: 1))
    }

    /// 样式/图案选择小按钮（内嵌任意预览内容；宽度可调保证一行不溢出）
    private func styleButton<Content: View>(width: CGFloat = 62, selected: Bool,
                                            @ViewBuilder content: () -> Content,
                                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content()
                .frame(width: width, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(selected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(selected ? Color.accentColor : Color.primary.opacity(0.18), lineWidth: 1))
        .handCursor()
    }

    private func toggleIcon(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(active ? Color.accentColor.opacity(0.18) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(active ? Color.accentColor : Color.primary.opacity(0.18), lineWidth: 1))
        .handCursor()
    }

    /// 滑杆 + 档位下拉（如「3 pt」）；滑杆拖动时吸附到档位，保证右侧数值始终显示
    private func widthRow(_ title: String, _ value: Binding<Double>, options: [Double], unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(title)).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Slider(value: Binding(
                    get: { value.wrappedValue },
                    set: { newValue in
                        // 吸附到最近的档位，Picker 才有对应 tag 可显示
                        value.wrappedValue = options.min(by: { abs($0 - newValue) < abs($1 - newValue) }) ?? newValue
                    }), in: options.first!...options.last!)
                Picker("", selection: value) {
                    ForEach(options, id: \.self) { o in
                        Text("\(Int(o)) \(unit)").tag(o)
                    }
                }
                .labelsHidden()
                .frame(width: 82)
            }
        }
    }

    private func opacityRow(_ title: String, _ value: Binding<Double>) -> some View {
        let options: [Double] = [0.1, 0.25, 0.5, 0.75, 1.0]
        return VStack(alignment: .leading, spacing: 4) {
            Text(L(title)).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Slider(value: Binding(
                    get: { value.wrappedValue },
                    set: { newValue in
                        value.wrappedValue = options.min(by: { abs($0 - newValue) < abs($1 - newValue) }) ?? newValue
                    }), in: options.first!...options.last!)
                Picker("", selection: value) {
                    ForEach(options, id: \.self) { o in
                        Text("\(Int(o * 100))%").tag(o)
                    }
                }
                .labelsHidden()
                .frame(width: 82)
            }
        }
    }

    /// 可空颜色行（首个按钮为「无」）
    private func optionalColorRow(_ title: String, _ value: Binding<Color?>, _ swatches: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(title)).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    value.wrappedValue = nil
                } label: {
                    Image(systemName: "slash.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(value.wrappedValue == nil ? Color.accentColor : .secondary)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .stroke(value.wrappedValue == nil ? Color.accentColor : Color.primary.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .handCursor()
                ForEach(swatches, id: \.self) { c in
                    Circle()
                        .fill(c)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                        .overlay(Circle().stroke(value.wrappedValue == c ? Color.accentColor : .clear, lineWidth: 2))
                        .onTapGesture { value.wrappedValue = c }
                        .handCursor()
                }
                // 圆形拾色器：填充当前色；非预设色生效时高亮描边
                CircleColorPicker(color: Binding(
                    get: { value.wrappedValue ?? swatches[0] },
                    set: { value.wrappedValue = $0 }),
                    active: value.wrappedValue != nil && !swatches.contains(value.wrappedValue!))
                    .frame(width: 16, height: 16)
                    .padding(.leading, 14)
                    .handCursor()
            }
        }
    }

    // MARK: 预览绘制

    private func lineStyleCanvas(wavy: Bool) -> some View {
        Canvas { ctx, size in
            var p = Path()
            let y = size.height / 2
            if wavy {
                p.move(to: CGPoint(x: 6, y: y))
                var x: CGFloat = 6
                while x < size.width - 6 {
                    x += 1.5
                    p.addLine(to: CGPoint(x: x, y: y + 2.6 * sin((x - 6) / 5.2 * .pi)))
                }
            } else {
                p.move(to: CGPoint(x: 6, y: y))
                p.addLine(to: CGPoint(x: size.width - 6, y: y))
            }
            ctx.stroke(p, with: .color(.primary), style: StrokeStyle(lineWidth: 1.4))
        }
    }

    private func borderStyleCanvas(_ style: ShapeBorderStyle) -> some View {
        Canvas { ctx, size in
            var p = Path()
            let y = size.height / 2
            p.move(to: CGPoint(x: 6, y: y))
            p.addLine(to: CGPoint(x: size.width - 6, y: y))
            ctx.stroke(p, with: .color(.primary),
                       style: StrokeStyle(lineWidth: 1.4, dash: style.dash ?? []))
        }
    }

    private func patternCanvas(_ pattern: ShapeFillPattern) -> some View {
        Canvas { ctx, size in
            switch pattern {
            case .none:
                var p = Path()
                p.move(to: CGPoint(x: 8, y: size.height - 8))
                p.addLine(to: CGPoint(x: size.width - 8, y: 8))
                ctx.stroke(p, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.2))
            case .diagonal, .crosshatch:
                for offset in stride(from: -CGFloat(size.height), to: size.width, by: 5) {
                    var p = Path()
                    p.move(to: CGPoint(x: offset, y: size.height))
                    p.addLine(to: CGPoint(x: offset + size.height, y: 0))
                    ctx.stroke(p, with: .color(.primary), style: StrokeStyle(lineWidth: 1))
                    if pattern == .crosshatch {
                        var q = Path()
                        q.move(to: CGPoint(x: offset, y: 0))
                        q.addLine(to: CGPoint(x: offset + size.height, y: size.height))
                        ctx.stroke(q, with: .color(.primary), style: StrokeStyle(lineWidth: 1))
                    }
                }
            case .dots:
                for gy in stride(from: 5.0, to: size.height, by: 6) {
                    for gx in stride(from: 5.0, to: size.width, by: 6) {
                        let r = CGRect(x: gx - 1, y: gy - 1, width: 2, height: 2)
                        ctx.fill(Path(ellipseIn: r), with: .color(.primary))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var shapePreviewCanvas: some View {
        Canvas { ctx, size in
            let rect = CGRect(x: 10, y: 10, width: size.width - 20, height: size.height - 20)
            let lineOnly = settings.shapeVariant == .line ||
                           settings.shapeVariant == .arrow ||
                           settings.shapeVariant == .doubleArrow
            var path = Path()
            switch settings.shapeVariant {
            case .rect: path.addRect(rect)
            case .ellipse: path.addEllipse(in: rect)
            case .line, .arrow, .doubleArrow:
                path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            }
            if !lineOnly {
                if let f = settings.shapeFillColor {
                    ctx.fill(path, with: .color(f.opacity(settings.shapeOpacity * 0.6)))
                }
                if settings.shapePattern != .none {
                    ctx.clip(to: path, style: FillStyle())   // 裁剪后画图案
                    drawPatternIn(ctx, rect: rect, pattern: settings.shapePattern)
                }
            }
            ctx.stroke(path, with: .color(settings.shapeStrokeColor.opacity(settings.shapeOpacity)),
                       style: StrokeStyle(lineWidth: min(settings.shapeStrokeWidth, 7), dash: settings.shapeDash ?? []))
            if settings.shapeVariant == .arrow || settings.shapeVariant == .doubleArrow {
                drawArrowHead(ctx, at: CGPoint(x: rect.maxX, y: rect.minY),
                              from: CGPoint(x: rect.minX, y: rect.maxY),
                              color: settings.shapeStrokeColor.opacity(settings.shapeOpacity),
                              width: min(settings.shapeStrokeWidth, 5))
            }
            if settings.shapeVariant == .doubleArrow {
                drawArrowHead(ctx, at: CGPoint(x: rect.minX, y: rect.maxY),
                              from: CGPoint(x: rect.maxX, y: rect.minY),
                              color: settings.shapeStrokeColor.opacity(settings.shapeOpacity),
                              width: min(settings.shapeStrokeWidth, 5))
            }
        }
    }

    private func drawPatternIn(_ ctx: GraphicsContext, rect: CGRect, pattern: ShapeFillPattern) {
        switch pattern {
        case .none: break
        case .diagonal, .crosshatch:
            for offset in stride(from: rect.minX - rect.height, to: rect.maxX, by: 7) {
                var p = Path()
                p.move(to: CGPoint(x: offset, y: rect.maxY))
                p.addLine(to: CGPoint(x: offset + rect.height, y: rect.minY))
                ctx.stroke(p, with: .color(settings.shapeStrokeColor.opacity(0.5)), style: StrokeStyle(lineWidth: 1))
                if pattern == .crosshatch {
                    var q = Path()
                    q.move(to: CGPoint(x: offset, y: rect.minY))
                    q.addLine(to: CGPoint(x: offset + rect.height, y: rect.maxY))
                    ctx.stroke(q, with: .color(settings.shapeStrokeColor.opacity(0.5)), style: StrokeStyle(lineWidth: 1))
                }
            }
        case .dots:
            for gy in stride(from: rect.minY + 4, to: rect.maxY, by: 7) {
                for gx in stride(from: rect.minX + 4, to: rect.maxX, by: 7) {
                    ctx.fill(Path(ellipseIn: CGRect(x: gx - 1.2, y: gy - 1.2, width: 2.4, height: 2.4)),
                             with: .color(settings.shapeStrokeColor.opacity(0.5)))
                }
            }
        }
    }

    private func drawArrowHead(_ ctx: GraphicsContext, at tip: CGPoint, from tail: CGPoint,
                               color: Color, width: CGFloat) {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let len: CGFloat = 9 + width * 1.2
        for da in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            var p = Path()
            p.move(to: tip)
            p.addLine(to: CGPoint(x: tip.x + len * cos(angle + da), y: tip.y + len * sin(angle + da)))
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }

    private var hintText: String {
        switch tool {
        case .pen: return L("在页面上按住拖动进行书写")
        case .highlight: return L("划选文字即可精准高亮；扫描版页面请拖动绘制")
        case .underline, .strikeOut: return L("划选文字即可沿线精准批注；扫描版页面请拖动绘制")
        case .shape: return L("选择工具后在页面上拖动绘制")
        case .eraser: return L("点击或拖过要删除的批注")
        case .textBox: return L("点击页面位置，在弹出的输入框中输入，回车放置")
        default: return L("选择工具后在页面上拖动绘制")
        }
    }
}

// MARK: 色板行（固定色 + 取色轮）

struct SwatchRow: View {
    @Binding var color: Color

    var body: some View {
        HStack(spacing: 8) {
            ForEach(EditMainView.swatches, id: \.self) { c in
                Circle()
                    .fill(c)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                    .overlay(Circle().stroke(color == c ? Color.accentColor : .clear, lineWidth: 2))
                    .onTapGesture { color = c }
                    .handCursor()
            }
            // 圆形拾色器：填充当前色；当前色不是预设时高亮描边（自定义色生效中）
            CircleColorPicker(color: $color,
                              active: !EditMainView.swatches.contains(color))
                .frame(width: 16, height: 16)
                .padding(.leading, 14)   // 拾色器与色板拉开间距
                .handCursor()
        }
    }
}

// MARK: 圆形拾色器（替代系统矩形 ColorPicker：与色板圆点同规格的彩色圆点，点击弹系统调色板）

/// 彩虹渐变圆点（同色板圆点规格）。不直接用 NSColorWell：它有 44×23 固有尺寸，
/// SwiftUI frame 压不住会被拉成椭圆；改为自绘圆点 + 接管 NSColorPanel 的 target/action。
struct CircleColorPicker: View {
    @Binding var color: Color
    /// true = 自定义颜色生效中，描边用强调色提示
    var active: Bool = false

    @State private var watcher = ColorPanelWatcher()

    var body: some View {
        Circle()
            .fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red],
                                  center: .center))
            .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
            .overlay(Circle().stroke(active ? Color.accentColor : .clear, lineWidth: 2))
            .onTapGesture {
                watcher.begin(binding: $color)
                NSColorPanel.shared.makeKeyAndOrderFront(nil)
            }
    }
}

/// NSColorPanel 颜色变化监听（KVO）：打开时把当前色带入面板，取色后回写绑定。
/// 面板是全局单例，用 current 指针保证只有最近点开的拾色器回写。
final class ColorPanelWatcher: NSObject {
    private static weak var current: ColorPanelWatcher?
    private var binding: Binding<Color>?
    private var observing = false

    func begin(binding: Binding<Color>) {
        self.binding = binding
        ColorPanelWatcher.current = self
        let panel = NSColorPanel.shared
        panel.color = NSColor(binding.wrappedValue)
        if !observing {
            panel.addObserver(self, forKeyPath: "color", options: [.new], context: nil)
            observing = true
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard ColorPanelWatcher.current === self, keyPath == "color",
              let panel = object as? NSColorPanel else { return }
        binding?.wrappedValue = Color(panel.color)
    }
}

// MARK: 批注撤销栈（按文档身份隔离；记录 add/remove 双向动作，带时间戳与重做栈）

enum AnnotationUndoAction {
    case added(PDFAnnotation)
    case removed(PDFAnnotation)
    /// 复合动作：橡皮擦「只擦除触及部分」把一条笔迹替换为若干段。
    /// 撤销 = 移除所有分段、恢复原笔迹；重做反之。单条记录，避免撤销时看到中间态。
    case replaced(original: PDFAnnotation, pieces: [PDFAnnotation])
    /// 复合新增（文字感知批注一次划选落多行）：撤销 = 一次移除全部，重做 = 一次重加
    case addedBatch([PDFAnnotation])
    /// 几何改动（选中后移动/缩放/旋转）：撤销还原 before 快照，重做套用 after 快照
    case geometry(PDFAnnotation, before: AnnotationGeomSnapshot, after: AnnotationGeomSnapshot)
}

/// 批注几何快照：bounds + 自绘类扩展状态（笔迹点列 / 形状 contentRect / 文本旋转 / 直线端点）
struct AnnotationGeomSnapshot: Equatable {
    var bounds: NSRect
    var pts: [NSPoint]? = nil
    var contentRect: NSRect? = nil
    var textRotation: CGFloat? = nil
    /// .line 批注端点（页面空间；bounds.origin + startPoint/endPoint）
    var lineStart: NSPoint? = nil
    var lineEnd: NSPoint? = nil

    static func capture(_ anno: PDFAnnotation) -> AnnotationGeomSnapshot {
        var s = AnnotationGeomSnapshot(bounds: anno.bounds,
                                       pts: (anno as? PenStrokeAnnotation)?.pts,
                                       contentRect: (anno as? PatternShapeAnnotation)?.contentRect,
                                       textRotation: (anno as? RotatableTextAnnotation)?.textRotation)
        if anno.type == "Line" {
            s.lineStart = NSPoint(x: anno.bounds.origin.x + anno.startPoint.x,
                                  y: anno.bounds.origin.y + anno.startPoint.y)
            s.lineEnd = NSPoint(x: anno.bounds.origin.x + anno.endPoint.x,
                                y: anno.bounds.origin.y + anno.endPoint.y)
        }
        return s
    }

    /// 套用快照（bounds 最后赋值以触发 PDFKit 重绘）
    func apply(to anno: PDFAnnotation) {
        if let pen = anno as? PenStrokeAnnotation, let pts { pen.pts = pts }
        if let shape = anno as? PatternShapeAnnotation, let contentRect { shape.contentRect = contentRect }
        if let text = anno as? RotatableTextAnnotation, let textRotation { text.textRotation = textRotation }
        if let ls = lineStart, let le = lineEnd {
            // .line 批注：先设 bounds 再放相对端点，保证两端随快照还原
            anno.bounds = bounds
            anno.startPoint = NSPoint(x: ls.x - bounds.origin.x, y: ls.y - bounds.origin.y)
            anno.endPoint = NSPoint(x: le.x - bounds.origin.x, y: le.y - bounds.origin.y)
        } else {
            anno.bounds = bounds
        }
    }

    /// 平移 delta（页面空间）：bounds 及自绘扩展状态一起平移
    func translated(by delta: NSPoint) -> AnnotationGeomSnapshot {
        var s = self
        s.bounds.origin.x += delta.x
        s.bounds.origin.y += delta.y
        if pts != nil { s.pts = pts!.map { NSPoint(x: $0.x + delta.x, y: $0.y + delta.y) } }
        if contentRect != nil {
            s.contentRect!.origin.x += delta.x
            s.contentRect!.origin.y += delta.y
        }
        if lineStart != nil {
            s.lineStart!.x += delta.x; s.lineStart!.y += delta.y
            s.lineEnd!.x += delta.x; s.lineEnd!.y += delta.y
        }
        return s
    }
}

@MainActor
final class AnnotationUndoStack {
    static let shared = AnnotationUndoStack()

    struct Entry {
        let pageIndex: Int
        let action: AnnotationUndoAction
        let time: Date
    }

    private var undoStack: [ObjectIdentifier: [Entry]] = [:]
    private var redoStack: [ObjectIdentifier: [Entry]] = [:]

    /// 新动作入撤销栈，并清空该文档的重做线
    func push(document: PDFDocument, pageIndex: Int, action: AnnotationUndoAction) {
        let key = ObjectIdentifier(document)
        undoStack[key, default: []].append(Entry(pageIndex: pageIndex, action: action, time: Date()))
        redoStack[key] = nil
        UndoCenter.shared.refresh()
    }

    /// 撤销：取栈顶转入重做栈（由调用方施加逆动作）
    @discardableResult
    func pop(document: PDFDocument) -> Entry? {
        let key = ObjectIdentifier(document)
        guard var entries = undoStack[key], !entries.isEmpty else { return nil }
        let last = entries.removeLast()
        undoStack[key] = entries
        redoStack[key, default: []].append(last)
        UndoCenter.shared.refresh()
        return last
    }

    /// 重做：取重做栈顶转回撤销栈（由调用方重新施加原动作）
    @discardableResult
    func popRedo(document: PDFDocument) -> Entry? {
        let key = ObjectIdentifier(document)
        guard var entries = redoStack[key], !entries.isEmpty else { return nil }
        let last = entries.removeLast()
        redoStack[key] = entries
        undoStack[key, default: []].append(Entry(pageIndex: last.pageIndex, action: last.action, time: Date()))
        UndoCenter.shared.refresh()
        return last
    }

    /// 取全部撤销记录（栈序），整体转入重做栈并清空（「撤销全部」仍可逐条重做）
    func popAll(document: PDFDocument) -> [Entry] {
        let key = ObjectIdentifier(document)
        let entries = undoStack.removeValue(forKey: key) ?? []
        redoStack[key, default: []].append(contentsOf: entries.reversed())
        UndoCenter.shared.refresh()
        return entries
    }

    func hasEntries(document: PDFDocument) -> Bool {
        !(undoStack[ObjectIdentifier(document)]?.isEmpty ?? true)
    }

    func hasRedoEntries(document: PDFDocument) -> Bool {
        !(redoStack[ObjectIdentifier(document)]?.isEmpty ?? true)
    }

    func lastUndoTime(document: PDFDocument) -> Date? {
        undoStack[ObjectIdentifier(document)]?.last?.time
    }

    func lastRedoTime(document: PDFDocument) -> Date? {
        redoStack[ObjectIdentifier(document)]?.last?.time
    }
}

// MARK: - ⌘Z 全局撤销（编辑界面挂载期间拦截；文本编辑焦点时放行原生撤销）

struct EditUndoKeyHandler: NSViewRepresentable {
    let onUndo: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = KeyView()
        v.onUndo = onUndo
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        (v as? KeyView)?.onUndo = onUndo
    }

    final class KeyView: NSView {
        var onUndo: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.modifierFlags.contains(.command),
                      event.charactersIgnoringModifiers == "z",
                      !event.modifierFlags.contains(.shift) else {
                    return event
                }
                // 文本输入焦点时放行，让输入框走原生撤销
                let fr = NSApp.keyWindow?.firstResponder
                if fr is NSText || fr is NSTextField || (fr as? NSView)?.ancestorOrSelf(ofType: NSTextField.self) != nil {
                    return event
                }
                self.onUndo?()
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

extension NSView {
    @discardableResult
    func ancestorOrSelf<T: NSView>(ofType type: T.Type) -> T? {
        var v: NSView? = self
        while let cur = v {
            if let t = cur as? T { return t }
            v = cur.superview
        }
        return nil
    }
}

// MARK: - Ghost 文字编辑器（所见即所得）
//
// 真实文字由页面上的 ghost 草稿批注渲染（与最终落纸同一条 draw 路径）；
// 本编辑器只负责收键盘、显示光标和输入法组字串：已上屏部分透明，组字部分正常显示。

/// 临时 UITEST 开关：环境变量 MPDF_UITEST 或命令行参数 --uitest 均可触发
let uitestEnabled: Bool = {
    ProcessInfo.processInfo.environment["MPDF_UITEST"] != nil
        || ProcessInfo.processInfo.arguments.contains("--uitest")
}()

/// 临时 UITEST：直接写文件日志（open 启动时 stderr/统一日志都拿不到）
func uitestLog(_ fmt: String, _ args: CVarArg...) {
    guard uitestEnabled else { return }
    let msg = String(format: fmt, arguments: args)
    let line = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium) + " " + msg + "\n"
    if let fh = FileHandle(forWritingAtPath: "/tmp/mpdf_uitest.log") {
        fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); fh.closeFile()
    } else {
        try? line.write(toFile: "/tmp/mpdf_uitest.log", atomically: true, encoding: .utf8)
    }
}

final class GhostTextEditor: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    /// 文字变化回调（每次键入/组字变化都会触发）
    var onTextChanged: (() -> Void)?
    /// 已上屏文字透明；组字串用这个颜色显示（与最终文字同色）
    var inkColor: NSColor = .black {
        didSet { refreshAttributes() }
    }

    /// 工厂构造：macOS 27 新文本栈下，子类自定义 init 调 super.init(frame:) 会崩溃、
    /// super.init(frame:textContainer: nil) 会让内容存储脱钩（打字全丢），
    /// 唯一可用路径＝继承的 init(frame:) + 构造后逐项配置
    static func make() -> GhostTextEditor {
        let e = GhostTextEditor(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        e.drawsBackground = false
        e.isRichText = true
        e.allowsUndo = true
        e.isAutomaticQuoteSubstitutionEnabled = false
        e.isAutomaticDashSubstitutionEnabled = false
        e.isAutomaticTextReplacementEnabled = false
        e.isAutomaticLinkDetectionEnabled = false
        e.insertionPointColor = .controlAccentColor
        // 内边距与 ghost 绘制的 3pt 一致，光标位置尽量贴近纸上文字
        e.textContainerInset = NSSize(width: 3, height: 3)
        // ghost 用 NSStringDrawing（无行首内边距）：归零对齐，否则光标恒比字形右偏 5pt
        e.textContainer?.lineFragmentPadding = 0
        return e
    }

    /// 已上屏文字（剔除输入法预编辑串）
    var committedText: String {
        let ns = string as NSString
        let mr = markedRange()
        guard mr.length > 0, NSIntersectionRange(NSRange(location: 0, length: ns.length), mr).length == mr.length else {
            return string
        }
        return ns.replacingCharacters(in: mr, with: "")
    }

    private var markedString: String? {
        let mr = markedRange()
        guard mr.length > 0 else { return nil }
        return (string as NSString).substring(with: mr)
    }

    /// 浮层文字全部透明（含组字串）——渲染完全交给 ghost，浮层只留光标；
    /// 字体全段统一（影响光标高度与布局）
    func refreshAttributes() {
        let f = font ?? .systemFont(ofSize: 14)
        let ns = string as NSString
        typingAttributes = [.font: f, .foregroundColor: NSColor.clear]
        guard ns.length > 0 else { return }
        textStorage?.beginEditing()
        textStorage?.addAttributes([.font: f, .foregroundColor: NSColor.clear],
                                   range: NSRange(location: 0, length: ns.length))
        textStorage?.endEditing()
    }

    override func didChangeText() {
        super.didChangeText()
        if uitestEnabled {
            uitestLog("[UITEST] editor didChangeText string=%@ marked=%d", string, markedRange().length)
        }
        refreshAttributes()
        onTextChanged?()
    }

    // 单行输入：回车提交，不换行
    override func insertNewline(_ sender: Any?) {
        if uitestEnabled {
            uitestLog("[UITEST] editor insertNewline (commit)")
        }
        onCommit?()
    }

    // Esc 取消（key binding 的 cancelOperation: 最终落到这里）
    override func cancelOperation(_ sender: Any?) {
        if uitestEnabled {
            uitestLog("[UITEST] editor cancelOperation")
        }
        onCancel?()
    }

    // 点击别处失焦 = 提交
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if uitestEnabled {
            uitestLog("[UITEST] editor resignFirstResponder ok=%d", ok ? 1 : 0)
        }
        if ok { onCommit?() }
        return ok
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if uitestEnabled {
            uitestLog("[UITEST] editor becomeFirstResponder ok=%d inWindow=%d", ok ? 1 : 0, window != nil ? 1 : 0)
        }
        return ok
    }
}

// MARK: - 图案形状批注（矩形/椭圆；自绘描边+填充+内部图案，保存为外观流）

final class PatternShapeAnnotation: PDFAnnotation {
    var isEllipse = false
    var pattern: ShapeFillPattern = .none
    var fillCol: NSColor? = nil
    var strokeCol: NSColor = .red
    var strokeW: CGFloat = 3
    var dash: [CGFloat]? = nil
    /// 实际要画的矩形（页面空间）；bounds 已按线宽外扩，避免粗描边被截断
    var contentRect: NSRect = .zero

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        // PDFKit 自绘外观流使用页面坐标（探针证实），contentRect 即页面空间矩形
        let drawRect = contentRect.isNull ? bounds : contentRect
        let path = isEllipse ? NSBezierPath(ovalIn: drawRect) : NSBezierPath(rect: drawRect)
        context.saveGState()
        let g = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        if let f = fillCol {
            f.setFill()
            path.fill()
        }
        if pattern != .none {
            path.addClip()
            drawPattern(in: drawRect)
        }
        strokeCol.setStroke()
        path.lineWidth = max(strokeW, 0.5)
        if let dash = dash, !dash.isEmpty {
            path.setLineDash(dash, count: dash.count, phase: 0)
        }
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    private func drawPattern(in area: NSRect) {
        strokeCol.withAlphaComponent(0.55).setFill()
        strokeCol.withAlphaComponent(0.55).setStroke()
        switch pattern {
        case .none:
            break
        case .diagonal, .crosshatch:
            let step: CGFloat = 7
            var x = area.minX - area.height
            while x < area.maxX {
                let p = NSBezierPath()
                p.move(to: NSPoint(x: x, y: area.minY))
                p.line(to: NSPoint(x: x + area.height, y: area.maxY))
                p.lineWidth = 1
                p.stroke()
                if pattern == .crosshatch {
                    let q = NSBezierPath()
                    q.move(to: NSPoint(x: x, y: area.maxY))
                    q.line(to: NSPoint(x: x + area.height, y: area.minY))
                    q.lineWidth = 1
                    q.stroke()
                }
                x += step
            }
        case .dots:
            var y = area.minY + 4
            while y < area.maxY {
                var x = area.minX + 4
                while x < area.maxX {
                    NSBezierPath(ovalIn: NSRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4)).fill()
                    x += 7
                }
                y += 7
            }
        }
    }
}

// MARK: - 可旋转文本批注（自绘文本；支持字体/粗斜体/背景色/90°倍数旋转）

final class RotatableTextAnnotation: PDFAnnotation {
    var bgColor: NSColor? = nil
    var textRotation: CGFloat = 0    // 度，90 的倍数

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let text = contents ?? ""
        guard !text.isEmpty else { return }   // ghost 草稿空文本不画任何东西
        let swap = Int(abs(textRotation)) % 180 == 90
        // 文本块尺寸：90/270 旋转时与 bounds 宽高互换（bounds 已按旋转后的占地创建，避免 BBox 裁剪）
        let w = swap ? bounds.height : bounds.width
        let h = swap ? bounds.width : bounds.height
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        if textRotation.truncatingRemainder(dividingBy: 360) != 0 {
            context.rotate(by: -textRotation * .pi / 180)
        }
        if let bg = bgColor {
            // 必须用 CGContext API 设色：NSColor.setFill() 只作用于 NSGraphicsContext，
            // 对 context.fill() 无效会落到默认黑色（背景恒黑根因）
            context.setFillColor(bg.cgColor)
            context.fill(NSRect(x: -w / 2, y: -h / 2, width: w, height: h))
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.lineBreakMode = .byWordWrapping
        let str = NSAttributedString(string: text, attributes: [
            .font: font ?? .systemFont(ofSize: 14),
            .foregroundColor: fontColor ?? .black,
            .paragraphStyle: para,
        ])
        let g = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        str.draw(in: NSRect(x: -w / 2 + 3, y: -h / 2 + 3, width: max(w - 6, 1), height: max(h - 6, 1)))
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}

// MARK: - 手绘笔/波浪线批注（自绘描边，线宽/颜色/不透明度完全由绘制保证）

final class PenStrokeAnnotation: PDFAnnotation {
    /// 页面坐标点列
    var pts: [NSPoint] = []
    var strokeColor: NSColor = .black
    var strokeWidth: CGFloat = 3
    /// 归属工具（"pen"/"underline"/"strikeOut"）——同工具下选同类批注用
    var role: String = "pen"

    init(pts: [NSPoint], color: NSColor, width: CGFloat) {
        self.pts = pts
        self.strokeColor = color
        self.strokeWidth = width
        var minX = pts[0].x, maxX = pts[0].x, minY = pts[0].y, maxY = pts[0].y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let pad = width / 2 + 2
        let bounds = NSRect(x: minX - pad, y: minY - pad,
                            width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        self.color = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard pts.count > 1 else { return }
        // 页面坐标绘制（探针证实自绘外观流为页面空间）
        let path = NSBezierPath()
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.line(to: p) }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        context.saveGState()
        let g = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        strokeColor.setStroke()
        path.lineWidth = max(strokeWidth, 0.5)
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    /// 橡皮擦「只擦除触及部分」：按圆心/半径切分点列，返回存活分段；未触及返回 nil
    func split(around center: NSPoint, radius: CGFloat) -> [PenStrokeAnnotation]? {
        let r = radius + strokeWidth / 2
        var runs: [[NSPoint]] = []
        var current: [NSPoint] = []
        var touched = false
        for p in pts {
            if hypot(p.x - center.x, p.y - center.y) <= r {
                touched = true
                if current.count > 1 { runs.append(current) }
                current = []
            } else {
                current.append(p)
            }
        }
        if current.count > 1 { runs.append(current) }
        guard touched else { return nil }
        return runs.map {
            let p = PenStrokeAnnotation(pts: $0, color: strokeColor, width: strokeWidth)
            p.role = role
            return p
        }
    }
}

// MARK: - 拖动橡皮筋辅助层（虚线框/提示线/笔迹/橡皮圈 + 尺寸角标；不拦截鼠标事件）

final class DragOverlay: NSView {
    var previewRect: NSRect? = nil       // 视图空间虚线框
    var previewLine: (NSPoint, NSPoint)? = nil   // 视图空间提示线（直线/线类工具）
    var previewPath: NSBezierPath? = nil         // 视图空间手绘笔迹预览
    var cursorCircle: (NSPoint, CGFloat)? = nil  // 橡皮擦光标圈（圆心+半径）
    var ellipse = false                  // 椭圆工具画虚线椭圆
    var guideColor: NSColor = .controlAccentColor
    var fillAlpha: CGFloat = 0
    var pathWidth: CGFloat = 1.5         // 描边宽度（形状工具跟随设定）
    var dashed = true                    // 实线/虚线
    // 选中态（浏览模式点选批注）：视图空间
    var selectionRect: NSRect? = nil
    var selectionHandles: [NSRect] = []  // 8 个缩放手柄（四角+四边中点；矩形类）
    var endpointKnobs: [NSPoint] = []    // 直线类选中：两端圆形手柄
    var rotationKnob: NSPoint? = nil     // 旋转手柄（文本批注）
    var deleteKnob: NSPoint? = nil       // 删除按钮

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // 纯展示层

    override func draw(_ dirtyRect: NSRect) {
        // 橡皮擦光标圈：黑色描边（白色背景下可见）+ 白色衬边（深色背景下可见）
        if let (c, r) = cursorCircle {
            let circle = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            let halo = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            halo.lineWidth = 3.2
            NSColor.white.withAlphaComponent(0.85).setStroke()
            halo.stroke()
            circle.lineWidth = 1.4
            NSColor.black.setStroke()
            circle.stroke()
            return
        }
        // 批注选中框：虚线边框 + 8 个方形手柄（矩形类）/ 两端圆点（直线类）+ 旋转钮 + 删除钮
        if let sel = selectionRect {
            let accent = NSColor.controlAccentColor
            let border = NSBezierPath(rect: sel)
            border.lineWidth = 1.2
            accent.withAlphaComponent(0.9).setStroke()
            border.setLineDash([4, 3], count: 2, phase: 0)
            border.stroke()
            for h in selectionHandles {
                let p = NSBezierPath(roundedRect: h, xRadius: 2.5, yRadius: 2.5)
                NSColor.white.setFill()
                p.fill()
                accent.setStroke()
                p.lineWidth = 1.3
                p.stroke()
            }
            for k in endpointKnobs {
                drawKnob(at: k, radius: 5.5, fill: .white, symbol: .hollow)
            }
            if let knob = rotationKnob {
                let anchor = NSPoint(x: sel.midX, y: sel.maxY)
                let stem = NSBezierPath()
                stem.move(to: anchor)
                stem.line(to: knob)
                accent.withAlphaComponent(0.7).setStroke()
                stem.lineWidth = 1.1
                stem.stroke()
                drawKnob(at: knob, radius: 6, fill: accent, symbol: .rotate)
            }
            if let del = deleteKnob {
                drawKnob(at: del, radius: 7, fill: NSColor.systemRed, symbol: .xmark)
            }
            return
        }
        guard let r = previewRect else {
            if let path = previewPath {
                guideColor.withAlphaComponent(0.9).setStroke()
                path.lineWidth = pathWidth
                path.lineCapStyle = .round
                path.stroke()
            } else if let (p1, p2) = previewLine {
                drawPath(NSBezierPath()) { path in
                    path.move(to: p1)
                    path.line(to: p2)
                }
                // 端点圆点：标出起点/终点
                for p in [p1, p2] {
                    let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
                    guideColor.setFill()
                    dot.fill()
                }
            }
            return
        }
        let shape = ellipse ? NSBezierPath(ovalIn: r) : NSBezierPath(rect: r)
        if fillAlpha > 0 {
            guideColor.withAlphaComponent(fillAlpha).setFill()
            shape.fill()
        }
        drawPath(shape)
        // 尺寸角标（跟随框右上角，超出视图上边界时移到框内）
        let label = "\(Int(r.width)) × \(Int(r.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: guideColor,
        ]
        let size = label.size(withAttributes: attrs)
        var origin = NSPoint(x: min(r.maxX - size.width - 2, bounds.maxX - size.width - 2),
                             y: r.maxY + 3)
        if origin.y + size.height > bounds.maxY {
            origin.y = r.maxY - size.height - 3
        }
        label.draw(at: origin, withAttributes: attrs)
    }

    private func drawPath(_ path: NSBezierPath, _ build: ((NSBezierPath) -> Void)? = nil) {
        build?(path)
        guideColor.setStroke()
        path.lineWidth = pathWidth
        if dashed {
            path.setLineDash([5, 4], count: 2, phase: 0)
        }
        path.stroke()
    }

    private enum KnobSymbol { case rotate, xmark, hollow }

    private func drawKnob(at center: NSPoint, radius: CGFloat, fill: NSColor, symbol: KnobSymbol) {
        if symbol == .hollow {
            // 直线端点圆点：白底 + 描边色圆环
            let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                     width: radius * 2, height: radius * 2))
            let halo = NSBezierPath(ovalIn: NSRect(x: center.x - radius - 1.5, y: center.y - radius - 1.5,
                                                   width: radius * 2 + 3, height: radius * 2 + 3))
            NSColor.white.withAlphaComponent(0.9).setStroke()
            halo.lineWidth = 2
            halo.stroke()
            fill.setFill()
            circle.fill()
            guideColor.setStroke()
            circle.lineWidth = 1.6
            circle.stroke()
            return
        }
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                 width: radius * 2, height: radius * 2))
        let halo = NSBezierPath(ovalIn: NSRect(x: center.x - radius - 1.5, y: center.y - radius - 1.5,
                                               width: radius * 2 + 3, height: radius * 2 + 3))
        NSColor.white.withAlphaComponent(0.9).setStroke()
        halo.lineWidth = 2
        halo.stroke()
        fill.setFill()
        circle.fill()
        NSColor.white.setStroke()
        let s = symbol == .rotate ? radius * 0.52 : radius * 0.42
        let glyph = NSBezierPath()
        switch symbol {
        case .xmark:
            glyph.move(to: NSPoint(x: center.x - s, y: center.y - s))
            glyph.line(to: NSPoint(x: center.x + s, y: center.y + s))
            glyph.move(to: NSPoint(x: center.x - s, y: center.y + s))
            glyph.line(to: NSPoint(x: center.x + s, y: center.y - s))
        case .rotate:
            glyph.appendArc(withCenter: center, radius: s, startAngle: -30, endAngle: 210)
        case .hollow:
            break
        }
        glyph.lineWidth = 1.6
        glyph.lineCapStyle = .round
        glyph.stroke()
    }
}

// MARK: - 批注 PDFView 包装

struct AnnotationPageView: NSViewRepresentable {
    @Binding var tool: EditTool?
    @Binding var settings: ToolSettings
    let onAdded: () -> Void

    @EnvironmentObject private var doc: DocumentStore

    func makeNSView(context: Context) -> AnnotationPDFView {
        let v = AnnotationPDFView()
        v.displayMode = .singlePageContinuous
        v.autoScales = true
        v.document = doc.document
        v.readSettings = { [binding = $settings] in binding.wrappedValue }
        v.onAddAnnotation = { pageIdx, anno in
            AnnotationUndoStack.shared.push(document: doc.document!, pageIndex: pageIdx, action: .added(anno))
            doc.isDirty = true
            doc.hasAnnotationEdits = true
            onAdded()
        }
        v.onRemoveAnnotation = { pageIdx, anno in
            AnnotationUndoStack.shared.push(document: doc.document!, pageIndex: pageIdx, action: .removed(anno))
            doc.isDirty = true
            doc.hasAnnotationEdits = true
            onAdded()
        }
        v.onCompositeErase = { pageIdx, original, pieces in
            AnnotationUndoStack.shared.push(document: doc.document!, pageIndex: pageIdx,
                                            action: .replaced(original: original, pieces: pieces))
            doc.isDirty = true
            doc.hasAnnotationEdits = true
            onAdded()
        }
        v.onAddBatch = { pageIdx, annos in
            // 一次划选落多行 = 单条撤销记录（⌘Z 一次全撤）
            AnnotationUndoStack.shared.push(document: doc.document!, pageIndex: pageIdx, action: .addedBatch(annos))
            doc.isDirty = true
            doc.hasAnnotationEdits = true
            onAdded()
        }
        v.onGeometryEdited = {
            doc.isDirty = true
            doc.hasAnnotationEdits = true
            onAdded()
        }
        context.coordinator.syncState(v, tool: tool, settings: settings)
        return v
    }

    func updateNSView(_ v: AnnotationPDFView, context: Context) {
        v.readSettings = { [binding = $settings] in binding.wrappedValue }
        context.coordinator.syncState(v, tool: tool, settings: settings)
        if v.document !== doc.document {
            v.document = doc.document
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        func syncState(_ v: AnnotationPDFView, tool: EditTool?, settings: ToolSettings) {
            if v.activeTool != tool {
                v.activeTool = tool
                v.clearOverlay()   // 切工具时清掉橡皮圈等残留
            }
            v.cachedSettings = settings
            v.refreshTextPopupIfOpen(settings: settings)
        }
    }
}

/// 支持批注绘制的 PDFView：工具激活时接管鼠标，拖出页面空间矩形/线段/笔迹
final class AnnotationPDFView: PDFView {
    var activeTool: EditTool? = nil
    /// 实时读取 SwiftUI @State（鼠标事件时无需等 updateNSView 刷新）
    var readSettings: (() -> ToolSettings?)? = nil
    var cachedSettings = ToolSettings()
    var settings: ToolSettings {
        get { readSettings?() ?? cachedSettings }
        set { cachedSettings = newValue }
    }
    var onAddAnnotation: ((Int, PDFAnnotation) -> Void)? = nil
    var onRemoveAnnotation: ((Int, PDFAnnotation) -> Void)? = nil
    /// 复合擦除（部分擦除切分笔迹）：单条撤销记录，避免撤销时看到中间态
    var onCompositeErase: ((Int, PDFAnnotation, [PDFAnnotation]) -> Void)? = nil
    /// 复合新增（文字感知批注一次划选落多行）：单条撤销记录
    var onAddBatch: ((Int, [PDFAnnotation]) -> Void)? = nil
    /// 选中态几何改动（移动/缩放/旋转）完成：仅刷脏标记，撤销记录由交互结束处统一入栈
    var onGeometryEdited: (() -> Void)? = nil

    /// 橡皮擦可删除的批注类型（PDFAnnotation.type 字符串）
    private static let erasableTypes: Set<String> = [
        "Highlight", "Underline", "StrikeOut", "FreeText",
        "Square", "Circle", "Line", "Stamp", "Link", "Ink",
    ]

    private var drawPage: PDFPage?
    private var startPt: NSPoint?
    private var currentPt: NSPoint?
    private var penPoints: [NSPoint] = []       // 手绘笔采集的页面坐标点列
    /// 文字感知批注进行中：拖动交给 PDFView 原生选字，mouseUp 收割选中行落批注
    private var textSelecting = false
    /// 页面文字层探测缓存（page.string 全页取词有成本，mouseMoved 高频调用需要）
    private weak var textProbePage: PDFPage?
    private var textProbeResult = false

    // MARK: 批注选中状态（浏览模式全选；工具激活时仅本工具画的同类批注可选）
    private enum SelectionMode { case none, moving, resizing, resizingLine, rotating }
    private var selectedAnno: PDFAnnotation? = nil
    private var selectedPage: PDFPage? = nil
    private var selMode: SelectionMode = .none
    private var selDragHandle: Int = 0          // 缩放起始手柄下标（0-3 = 左下/右下/左上/右上）
    private var selStartPagePt: NSPoint = .zero
    private var selOrigGeom: AnnotationGeomSnapshot? = nil
    private var selLastGeom: AnnotationGeomSnapshot? = nil

    // MARK: 拖动橡皮筋辅助层

    /// 拖动预览：虚线框/提示线画在 PDFView 最上层的透明视图（不拦截鼠标）
    private lazy var overlayView: DragOverlay = {
        let v = DragOverlay()
        v.isHidden = true
        addSubview(v, positioned: .above, relativeTo: nil)
        return v
    }()

    /// 临时 UITEST：独立窗口 harness（定位打字问题用，绕开 SwiftUI 标签页）
    static func runUITestHarness() {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: "/tmp/mpdf_test.pdf")) else {
            uitestLog("[UITEST] harness: cannot load test pdf"); return
        }
        let v = AnnotationPDFView()
        v.document = doc
        let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 700),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.contentView = v
        w.title = "UITEST"
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        v.activeTool = .textBox
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let page = doc.page(at: 0)!
            let b = page.bounds(for: .mediaBox)
            uitestLog("[UITEST] harness: calling showTextInput")
            v.showTextInput(page: page, point: NSPoint(x: b.midX, y: b.midY - 80))
            // 再延迟 1.2s：程序化打字 + 提交全链路验证
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard let ed = v.textPopup else {
                    uitestLog("[UITEST] typing: editor gone"); return
                }
                ed.string = "abc"
                ed.insertText("X", replacementRange: NSRange(location: (ed.string as NSString).length, length: 0))
                uitestLog("[UITEST] typed: string=%@", ed.string)
                // 2s 后提交并落盘检查
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    v.commitTextInput()
                    let out = PDFDocument()
                    if let d2 = v.document, let p = d2.page(at: 0) { out.insert(p, at: 0) }
                    let url = URL(fileURLWithPath: "/tmp/mpdf_uitest_out.pdf")
                    out.write(to: url)
                    uitestLog("[UITEST] harness: committed and wrote output")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
                }
            }
        }
    }

    override func layout() {
        super.layout()
        overlayView.frame = bounds
        attachScrollObserver()
    }

    // MARK: 滚动跟随（选中框 / ghost 编辑器与页面同步）

    private var scrollObserver: NSObjectProtocol?

    /// 滚动视图 bounds 变化（滚动/缩放）→ 重算选中框与编辑器位置。
    /// 不监听的话 overlay 画在视图空间的旧位置上，页面一动定位框就与图形分离。
    private func attachScrollObserver() {
        if scrollObserver != nil { return }
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            self?.canvasDidScroll()
        }
    }

    deinit {
        if let obs = scrollObserver { NotificationCenter.default.removeObserver(obs) }
    }

    private func canvasDidScroll() {
        if selectedAnno != nil { updateSelectionOverlay() }
        if textPopup != nil { syncGhostFromEditor() }
    }

    func clearOverlay() {
        overlayView.isHidden = true
        overlayView.previewRect = nil
        overlayView.previewLine = nil
        overlayView.previewPath = nil
        overlayView.cursorCircle = nil
        overlayView.ellipse = false
        deselectAnnotation()
        overlayView.needsDisplay = true
    }

    /// 按当前工具配置辅助层样式
    private func configureOverlay() {
        overlayView.ellipse = false
        overlayView.dashed = true
        overlayView.pathWidth = 1.5
        overlayView.fillAlpha = 0.10
        // 页面空间 pt → 视图像素：预览线宽按当前缩放系数换算，保证与最终批注粗细一致
        let scale = max(scaleFactor, 0.05)
        switch activeTool {
        case .redact:
            overlayView.guideColor = .black
            overlayView.fillAlpha = 0.55
        case .highlight:
            overlayView.guideColor = NSColor(settings.highlightColor)
            overlayView.fillAlpha = 0.25
        case .pen:
            overlayView.guideColor = NSColor(settings.penColor)
            overlayView.pathWidth = max(CGFloat(settings.penWidth) * scale, 1.0)
            overlayView.dashed = false
            overlayView.fillAlpha = 0
        case .underline:
            // 预览线颜色/粗细与最终批注一致
            overlayView.guideColor = NSColor(settings.underlineColor)
            overlayView.pathWidth = max(CGFloat(settings.underlineWidth) * scale, 1.0)
            overlayView.dashed = false
            overlayView.fillAlpha = 0
        case .strikeOut:
            overlayView.guideColor = NSColor(settings.strikeColor)
            overlayView.pathWidth = max(CGFloat(settings.strikeWidth) * scale, 1.0)
            overlayView.dashed = false
            overlayView.fillAlpha = 0
        case .shape:
            overlayView.guideColor = NSColor(settings.shapeStrokeColor).withAlphaComponent(CGFloat(settings.shapeOpacity))
            overlayView.fillAlpha = 0.08
            overlayView.pathWidth = max(CGFloat(settings.shapeStrokeWidth) * scale, 1.0)
            overlayView.dashed = settings.shapeBorderStyle != .solid
            overlayView.ellipse = settings.shapeVariant == .ellipse
        default:
            overlayView.guideColor = .controlAccentColor
            overlayView.fillAlpha = 0.10
        }
    }

    /// 把页面空间两点换算成视图空间并更新橡皮筋
    private func updateOverlay() {
        guard let page = drawPage else { return }
        switch activeTool {
        case .pen:
            guard !penPoints.isEmpty else { return }
            let p = NSBezierPath()
            for (i, pt) in penPoints.enumerated() {
                let v = convert(pt, from: page)
                if i == 0 { p.move(to: v) } else { p.line(to: v) }
            }
            overlayView.previewRect = nil
            overlayView.previewLine = nil
            overlayView.previewPath = p
        case .shape where settings.shapeVariant == .line ||
                          settings.shapeVariant == .arrow ||
                          settings.shapeVariant == .doubleArrow,
             .underline, .strikeOut:
            // 线类工具：端点提示线（起点/终点圆点）
            guard let a = startPt, let b = currentPt else { return }
            overlayView.previewRect = nil
            overlayView.previewPath = nil
            overlayView.previewLine = (convert(a, from: page), convert(b, from: page))
        default:
            guard let a = startPt, let b = currentPt else { return }
            let r = normalizedRect(convert(a, from: page), convert(b, from: page))
            overlayView.previewRect = r
            overlayView.previewLine = nil
            overlayView.previewPath = nil
        }
        overlayView.needsDisplay = true
    }

    // MARK: 光标反馈（工具激活 = 十字准星；文本 = I 形；批注本体 = 小手；控制点 = 缩放箭头）

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas where ta.owner === self {
            removeTrackingArea(ta)
        }
        // ⚠️ 不能用 .infinite（覆盖整个窗口，顶栏/按钮光标被强制覆盖）；
        // 也不能用固定 rect: bounds —— PDF 在滚动视图内滚动时 bounds 原点移动，
        // 固定矩形会整体错出可视区，鼠标挪回画布后 mouseMoved 断供 → 光标卡死、悬停小手/控制点箭头全失效。
        // .inVisibleRect 由系统动态跟随可视区（自动裁剪到画布，不外溢到顶栏/面板），两难全解。
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.inVisibleRect, .cursorUpdate, .mouseMoved, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
        // NSWindow 默认不派发 mouseMoved；不开则 mouseMoved 内的光标切换完全失效
        window?.acceptsMouseMovedEvents = true
    }

    /// 光标状态切换的实时性关键：cursorUpdate 只在进入/离开跟踪区（或窗口激活变化）时派发，
    /// 同一视图内部移动不会触发 → 必须在 mouseMoved 里主动 set 光标，否则小手/十字卡在旧状态，
    /// 要等移出画布或切窗回来才刷新（用户实测的两处失效均由此而来）。
    override func mouseMoved(with event: NSEvent) {
        // 只处理画布范围内的事件（跟踪区已限 bounds，双保险；拖拽中例外）
        let vp = convert(event.locationInWindow, from: nil)
        guard bounds.contains(vp) || selMode != .none else {
            super.mouseMoved(with: event)
            return
        }
        // 橡皮擦：光标圈跟随（悬浮即跟随，不只按下时）
        if activeTool == .eraser {
            updateEraserCursor(atView: vp)
        }
        updateCursor(at: event)
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        // 边界守卫：光标在画布外（顶栏/面板）时交给其他视图/按钮的光标逻辑
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else {
            super.cursorUpdate(with: event)
            return
        }
        updateCursor(at: event)
    }

    /// 按当前位置统一计算光标（cursorUpdate / mouseMoved / mouseUp 共用）
    private func updateCursor(at event: NSEvent) {
        // 选中批注可能已被撤销/橡皮擦删除（不经过本视图）：发现即收起选中框
        if let anno = selectedAnno, let page = selectedPage, !page.annotations.contains(anno) {
            deselectAnnotation()
        }
        // 选中态：光标悬停缩放控制点 → 对应方向的缩放双箭头（四角斜 45°、边中点垂直于边）
        if let h = hoverHandleIndex(atView: convert(event.locationInWindow, from: nil)) {
            switch h {
            case 0, 3: Self.diagNECursor.set()      // 左下/右上：↗↙
            case 1, 2: Self.diagNWCursor.set()      // 右下/左上：↖↘
            case 4, 6: NSCursor.resizeUpDown.set()  // 下中/上中：垂直双箭头
            default: NSCursor.resizeLeftRight.set() // 右中/左中：水平双箭头
            }
            return
        }
        switch activeTool {
        case .eraser:
            NSCursor.crosshair.set()
        case .some(let t):
            // 工具激活：光标落在本工具画的同类批注上切为小手（可点选编辑），否则绘制光标
            if let page = hitPage(event) {
                let vp = convert(event.locationInWindow, from: nil)
                let hit = annotationAt(convert(vp, to: page), page: page) { [weak self] anno in
                    guard let self else { return false }
                    return self.annotationMatchesTool(anno, t)
                }
                if hit != nil {
                    NSCursor.pointingHand.set()
                    return
                }
            }
            if t == .textBox {
                NSCursor.iBeam.set()    // 文本工具空白处 = 可输入
            } else if toolSupportsTextMarkup, let page = hitPage(event), pageHasText(page) {
                NSCursor.iBeam.set()    // 高亮/下划线/删除线在文字层页面 = 可划选文字
            } else {
                NSCursor.crosshair.set()
            }
        case .none:
            // 浏览模式：光标落在批注上时切为小手（提示此处已做过修改、可点选）
            if let page = hitPage(event),
               annotationAt(convert(convert(event.locationInWindow, from: nil), to: page), page: page) != nil {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    /// 光标当前悬停的缩放控制点下标（复用拖拽命中的同一套矩形，未显示控制点时返回 nil）
    private func hoverHandleIndex(atView vp: NSPoint) -> Int? {
        guard selectedAnno != nil, !overlayView.isHidden else { return nil }
        for (i, h) in overlayView.selectionHandles.enumerated()
        where h.insetBy(dx: -2, dy: -2).contains(vp) { return i }
        return nil
    }

    /// 自绘斜 45° 双箭头缩放光标（AppKit 无系统斜向缩放光标）；白色衬边保证深浅背景下可见
    private static func makeDiagCursor(nesw: Bool) -> NSCursor {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let p = NSBezierPath()
            if nesw {
                p.move(to: NSPoint(x: 4, y: 4)); p.line(to: NSPoint(x: 14, y: 14))
                p.move(to: NSPoint(x: 4, y: 4)); p.line(to: NSPoint(x: 7.5, y: 4))
                p.move(to: NSPoint(x: 4, y: 4)); p.line(to: NSPoint(x: 4, y: 7.5))
                p.move(to: NSPoint(x: 14, y: 14)); p.line(to: NSPoint(x: 10.5, y: 14))
                p.move(to: NSPoint(x: 14, y: 14)); p.line(to: NSPoint(x: 14, y: 10.5))
            } else {
                p.move(to: NSPoint(x: 4, y: 14)); p.line(to: NSPoint(x: 14, y: 4))
                p.move(to: NSPoint(x: 4, y: 14)); p.line(to: NSPoint(x: 7.5, y: 14))
                p.move(to: NSPoint(x: 4, y: 14)); p.line(to: NSPoint(x: 4, y: 10.5))
                p.move(to: NSPoint(x: 14, y: 4)); p.line(to: NSPoint(x: 10.5, y: 4))
                p.move(to: NSPoint(x: 14, y: 4)); p.line(to: NSPoint(x: 14, y: 7.5))
            }
            let halo = p.copy() as! NSBezierPath
            halo.lineWidth = 3.4
            NSColor.white.withAlphaComponent(0.9).setStroke()
            halo.stroke()
            p.lineWidth = 1.6
            NSColor.black.setStroke()
            p.stroke()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 9, y: 9))
    }

    private static let diagNECursor = makeDiagCursor(nesw: true)
    private static let diagNWCursor = makeDiagCursor(nesw: false)

    /// 橡皮擦模式：跟随鼠标显示尺寸圈（按下/拖动同样跟随；局部重绘保证流畅）
    private func updateEraserCursor(atView vp: NSPoint) {
        let r = max(CGFloat(settings.eraserSize), 8)
        let old = overlayView.cursorCircle.map {
            NSRect(x: $0.0.x - $0.1 - 4, y: $0.0.y - $0.1 - 4, width: $0.1 * 2 + 8, height: $0.1 * 2 + 8)
        }
        overlayView.isHidden = false
        overlayView.previewRect = nil
        overlayView.previewLine = nil
        overlayView.previewPath = nil
        overlayView.cursorCircle = (vp, r)
        let fresh = NSRect(x: vp.x - r - 4, y: vp.y - r - 4, width: r * 2 + 8, height: r * 2 + 8)
        overlayView.setNeedsDisplay(old.map { $0.union(fresh) } ?? fresh)
    }

    override func mouseExited(with event: NSEvent) {
        if activeTool == .eraser { clearOverlay() }
        // 离开画布：主动还箭头（避免残留十字/小手）；进入按钮时其 onHover 会再设小手
        if selMode == .none {
            NSCursor.arrow.set()
        }
    }

    // MARK: 鼠标拦截（工具激活时不滚动）

    override func mouseDown(with event: NSEvent) {
        // 浏览模式：全部批注可选中交互；空白处交给 PDFView
        if activeTool == nil {
            selectionMouseDown(event, fallbackToSuper: true)
            return
        }
        guard let page = hitPage(event) else {
            super.mouseDown(with: event)
            return
        }
        let pt = convert(convert(event.locationInWindow, from: nil), to: page)
        // 橡皮擦：按下即删，拖动连续删；光标圈全程跟随
        if activeTool == .eraser {
            drawPage = page
            updateEraserCursor(atView: convert(event.locationInWindow, from: nil))
            eraseAnnotation(at: pt, page: page)
            return
        }
        // 文本工具：点击已有文本批注先选中/拖动；空白处弹出输入框
        if activeTool == .textBox {
            if selectionMouseDown(event, allowed: { [weak self] anno in
                guard let self else { return false }
                return self.annotationMatchesTool(anno, .textBox)
            }, fallbackToSuper: false) {
                return
            }
            showTextInput(page: page, point: pt)
            return
        }
        // 工具激活时：先尝试选中本工具画的同类批注（命中控制点/本体即进入编辑）
        if selectionMouseDown(event, allowed: { [weak self] anno in
            guard let self else { return false }
            return self.annotationMatchesTool(anno, self.activeTool)
        }, fallbackToSuper: false) {
            return
        }
        // 文字感知批注：高亮/下划线/删除线在文字层页面上改走 PDFView 原生划选，
        // mouseUp 按选中行逐行精准落批注（严格贴合字形和行）；扫描版（无文字层）仍走自绘
        if toolSupportsTextMarkup, pageHasText(page) {
            textSelecting = true
            super.mouseDown(with: event)
            return
        }
        // 空白处：取消选中并开始绘制新批注
        drawPage = page
        startPt = pt
        currentPt = startPt
        penPoints = activeTool == .pen ? [pt] : []
        configureOverlay()
        overlayView.frame = bounds
        overlayView.isHidden = false
        updateOverlay()
    }

    override func mouseDragged(with event: NSEvent) {
        if selMode != .none {
            selectionDragged(event)
            return
        }
        if textSelecting {
            super.mouseDragged(with: event)   // PDFView 原生文字选择
            return
        }
        guard activeTool != nil, let page = drawPage else {
            super.mouseDragged(with: event)
            return
        }
        let pt = convert(convert(event.locationInWindow, from: nil), to: page)
        if activeTool == .eraser {
            updateEraserCursor(atView: convert(event.locationInWindow, from: nil))   // 拖动时圈跟随光标（原只跟随 mouseMoved，拖动中卡在初始位置）
            eraseAnnotation(at: pt, page: page)
            return
        }
        guard startPt != nil else { return }
        currentPt = pt
        if activeTool == .pen, let last = penPoints.last,
           hypot(pt.x - last.x, pt.y - last.y) > 1.2 {
            penPoints.append(pt)
        }
        updateOverlay()
    }

    override func mouseUp(with event: NSEvent) {
        if textSelecting {
            textSelecting = false
            super.mouseUp(with: event)
            harvestTextSelection()
            return
        }
        if selMode != .none || (activeTool == nil && selectedAnno != nil) {
            selectionMouseUp()
            super.mouseUp(with: event)
            return
        }
        guard activeTool != nil, activeTool != .eraser, let page = drawPage, let a = startPt, let b = currentPt else {
            super.mouseUp(with: event)
            drawPage = nil
            startPt = nil
            currentPt = nil
            penPoints = []
            clearOverlay()
            return
        }
        defer {
            drawPage = nil
            startPt = nil
            currentPt = nil
            penPoints = []
        }
        let idx = document.map { $0.index(for: page) } ?? -1
        guard idx >= 0 else { clearOverlay(); return }
        guard let anno = makeAnnotation(tool: activeTool, page: page, a: a, b: b) else { clearOverlay(); return }
        page.addAnnotation(anno)
        onAddAnnotation?(idx, anno)
        // 画完形状默认显示控制点（选中态）；其余工具收起辅助层
        if activeTool == .shape {
            selectedAnno = anno
            selectedPage = page
            updateSelectionOverlay()
        } else {
            clearOverlay()
        }
        // 松开即按新状态刷新光标（批注已落在光标下方 → 立即切小手/控制点箭头，不等下次移动）
        updateCursor(at: event)
    }

    // MARK: 橡皮擦（整条消失 = 删除触及的最上层批注；只擦触及部分 = 切分自绘笔迹）

    private func eraseAnnotation(at pt: NSPoint, page: PDFPage) {
        let r = max(CGFloat(settings.eraserSize), 6) / 2 + 3
        let hitRect = NSRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
        let idx = document.map { $0.index(for: page) } ?? -1
        guard idx >= 0 else { return }

        // 自上而下找触及的批注
        for hit in page.annotations.reversed() {
            guard let t = hit.type, Self.erasableTypes.contains(t) else { continue }
            guard hit.bounds.insetBy(dx: -2, dy: -2).intersects(hitRect) else { continue }

            // 部分擦除：仅适用于自绘笔迹（切分 = 单条复合撤销动作）。
            // 先加分段、后删原笔迹，并在 CATransaction 中禁用隐式动画：
            // 若先删后加，PDFKit 重绘存在一帧「笔迹消失」的空档，视觉上闪现
            if settings.eraserPartial, let stroke = hit as? PenStrokeAnnotation {
                guard let pieces = stroke.split(around: pt, radius: r) else { continue }   // 未触及笔迹本体，看下一条
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for piece in pieces { page.addAnnotation(piece) }
                page.removeAnnotation(hit)
                CATransaction.commit()
                onCompositeErase?(idx, hit, pieces)
                return
            }
            // 整条消失（或不可切分类型）
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            page.removeAnnotation(hit)
            CATransaction.commit()
            onRemoveAnnotation?(idx, hit)
            return
        }
    }

    // MARK: 批注选中：命中测试 / 移动 / 缩放 / 旋转 / 删除
    //
    // 选中规则（对标 UPDF）：无工具（浏览）时全部批注可选；工具激活时仅「本工具画的同类批注」可选
    //（如形状工具下矩形/椭圆/直线/箭头/双箭头都可选），光标落在其上切为选择光标。
    // 矩形类选中 = 虚线框 + 8 个控制点（四角+四边中点）；直线类 = 两端圆形端点手柄。

    /// 批注是否属于当前工具（可选/可选中的范围）
    private func annotationMatchesTool(_ anno: PDFAnnotation, _ tool: EditTool?) -> Bool {
        guard let tool else { return true }   // 浏览模式：全部可选
        switch tool {
        case .highlight: return anno.type == "Highlight"
        case .underline: return (anno as? PenStrokeAnnotation)?.role == "underline"
        case .strikeOut: return (anno as? PenStrokeAnnotation)?.role == "strikeOut"
        case .pen: return (anno as? PenStrokeAnnotation)?.role == "pen"
        case .shape: return anno is PatternShapeAnnotation || anno.type == "Line"
        case .textBox: return anno is RotatableTextAnnotation
        case .redact: return anno.userName == DocumentStore.redactMarker
        case .eraser: return false
        }
    }

    /// 命中测试（自上而下，带类型过滤）
    private func annotationAt(_ pt: NSPoint, page: PDFPage,
                              allowed: ((PDFAnnotation) -> Bool)? = nil) -> PDFAnnotation? {
        for hit in page.annotations.reversed() {
            guard let t = hit.type, Self.erasableTypes.contains(t) else { continue }
            if let allowed, !allowed(hit) { continue }
            if hit.bounds.insetBy(dx: -3, dy: -3).contains(pt) { return hit }
        }
        return nil
    }

    /// 直线类选中（.line 批注，形状工具的直线/箭头/双箭头）
    private var selectionIsLine: Bool { selectedAnno?.type == "Line" }

    /// 缩放支持：矩形类批注（高亮/遮盖/形状矩形椭圆/未旋转文本）；笔迹与线类只可移动
    private var selectionResizable: Bool {
        guard let a = selectedAnno else { return false }
        if selectionIsLine { return false }
        if a is PenStrokeAnnotation { return false }
        if a is PatternShapeAnnotation { return true }
        if let t = a as? RotatableTextAnnotation { return Int(abs(t.textRotation)) % 180 == 0 }
        if let t = a.type { return ["Highlight", "Square", "Circle"].contains(t) }
        return false
    }

    private var selectionRotatable: Bool { selectedAnno is RotatableTextAnnotation }

    private func deselectAnnotation() {
        selectedAnno = nil
        selectedPage = nil
        selMode = .none
        selOrigGeom = nil
        selLastGeom = nil
        overlayView.selectionRect = nil
        overlayView.selectionHandles = []
        overlayView.endpointKnobs = []
        overlayView.rotationKnob = nil
        overlayView.deleteKnob = nil
        if activeTool == nil, overlayView.cursorCircle == nil { overlayView.isHidden = true }
        overlayView.needsDisplay = true
    }

    private static let handleSize: CGFloat = 9

    /// 8 个缩放手柄（视图空间矩形）；顺序 0=左下 1=右下 2=左上 3=右上 4=下中 5=右中 6=上中 7=左中
    private func selectionHandleRects(_ selRect: NSRect) -> [NSRect] {
        let s = Self.handleSize
        let pts = [NSPoint(x: selRect.minX, y: selRect.minY),
                   NSPoint(x: selRect.maxX, y: selRect.minY),
                   NSPoint(x: selRect.minX, y: selRect.maxY),
                   NSPoint(x: selRect.maxX, y: selRect.maxY),
                   NSPoint(x: selRect.midX, y: selRect.minY),
                   NSPoint(x: selRect.maxX, y: selRect.midY),
                   NSPoint(x: selRect.midX, y: selRect.maxY),
                   NSPoint(x: selRect.minX, y: selRect.midY)]
        return pts.map { NSRect(x: $0.x - s / 2, y: $0.y - s / 2, width: s, height: s) }
    }

    private func updateSelectionOverlay() {
        // 批注可能已被其他路径删除（撤销/重做/橡皮擦）：页面里已不存在 → 立即收起选中框
        guard let anno = selectedAnno, let page = selectedPage, page.annotations.contains(anno) else {
            deselectAnnotation()
            return
        }
        let r = convert(anno.bounds, from: page)
        overlayView.isHidden = false
        overlayView.previewRect = nil
        overlayView.previewLine = nil
        overlayView.previewPath = nil
        overlayView.cursorCircle = nil
        overlayView.selectionRect = r
        if selectionIsLine {
            // 直线类：两端圆形手柄（直接读批注实时端点，与拖动同步）
            overlayView.selectionHandles = []
            let ls = NSPoint(x: anno.bounds.origin.x + anno.startPoint.x,
                             y: anno.bounds.origin.y + anno.startPoint.y)
            let le = NSPoint(x: anno.bounds.origin.x + anno.endPoint.x,
                             y: anno.bounds.origin.y + anno.endPoint.y)
            overlayView.endpointKnobs = [convert(ls, from: page), convert(le, from: page)]
        } else {
            overlayView.selectionHandles = selectionResizable ? selectionHandleRects(r) : []
            overlayView.endpointKnobs = []
        }
        overlayView.rotationKnob = selectionRotatable ? NSPoint(x: r.midX, y: r.maxY + 20) : nil
        overlayView.deleteKnob = NSPoint(x: r.maxX + 12, y: r.maxY + 12)
        overlayView.needsDisplay = true
    }

    /// 删除按钮 / 旋转钮的命中区域（视图空间圆）
    private func knobHit(_ knob: NSPoint?, radius: CGFloat, vp: NSPoint) -> Bool {
        guard let k = knob else { return false }
        return hypot(vp.x - k.x, vp.y - k.y) <= radius + 3
    }

    /// 选中交互入口。allowed = 命中过滤（nil = 全部）；fallbackToSuper = 空白处交给 PDFView。
    /// 返回 true 表示事件已被选中交互消费；false = 未命中（工具模式下接着开始绘制）。
    @discardableResult
    private func selectionMouseDown(_ event: NSEvent,
                                    allowed: ((PDFAnnotation) -> Bool)? = nil,
                                    fallbackToSuper: Bool) -> Bool {
        let vp = convert(event.locationInWindow, from: nil)
        guard let page = page(for: vp, nearest: true) else {
            if fallbackToSuper { deselectAnnotation(); super.mouseDown(with: event) }
            return false
        }
        let pt = convert(vp, to: page)

        // 已有选中：优先命中 删除钮 / 控制点 / 端点 / 旋转钮 / 选中本体
        if selectedAnno != nil, selectedPage === page {
            if knobHit(overlayView.deleteKnob, radius: 8, vp: vp) {
                deleteSelected()
                return true
            }
            if let selRect = overlayView.selectionRect {
                for (i, h) in selectionHandleRects(selRect).enumerated()
                where h.insetBy(dx: -3, dy: -3).contains(vp) {
                    beginSelectionInteraction(mode: .resizing, handle: i, page: page, pt: pt)
                    return true
                }
            }
            for (i, k) in overlayView.endpointKnobs.enumerated()
            where knobHit(k, radius: 7, vp: vp) {
                beginSelectionInteraction(mode: .resizingLine, handle: i, page: page, pt: pt)
                return true
            }
            if knobHit(overlayView.rotationKnob, radius: 7, vp: vp) {
                beginSelectionInteraction(mode: .rotating, handle: 0, page: page, pt: pt)
                return true
            }
            if let anno = selectedAnno, anno.bounds.insetBy(dx: -3, dy: -3).contains(pt) {
                beginSelectionInteraction(mode: .moving, handle: 0, page: page, pt: pt)
                return true
            }
        }

        // 点选批注（选中并立即进入可拖动状态）
        if let anno = annotationAt(pt, page: page, allowed: allowed) {
            selectedAnno = anno
            selectedPage = page
            updateSelectionOverlay()
            beginSelectionInteraction(mode: .moving, handle: 0, page: page, pt: pt)
            return true
        }

        // 空白处：取消选中
        deselectAnnotation()
        if fallbackToSuper { super.mouseDown(with: event) }
        return false
    }

    private func beginSelectionInteraction(mode: SelectionMode, handle: Int, page: PDFPage, pt: NSPoint) {
        selMode = mode
        selDragHandle = handle
        selStartPagePt = pt
        selOrigGeom = AnnotationGeomSnapshot.capture(selectedAnno!)
        selLastGeom = selOrigGeom
        updateSelectionOverlay()
    }

    private func selectionDragged(_ event: NSEvent) {
        guard let anno = selectedAnno, let page = selectedPage,
              let orig = selOrigGeom, var geom = selLastGeom else { return }
        let vp = convert(event.locationInWindow, from: nil)
        let pt = convert(vp, to: page)

        switch selMode {
        case .none:
            return
        case .moving:
            geom = orig.translated(by: NSPoint(x: pt.x - selStartPagePt.x, y: pt.y - selStartPagePt.y))
        case .resizing:
            geom = Self.resized(orig, handle: selDragHandle, to: pt)
        case .resizingLine:
            geom = Self.lineEndpointResized(orig, handle: selDragHandle, to: pt)
        case .rotating:
            let center = NSPoint(x: orig.bounds.midX, y: orig.bounds.midY)
            let angleDeg = atan2(vp.y - convert(center, from: page).y,
                                 vp.x - convert(center, from: page).x) * 180 / .pi
            // 旋转钮在正上方（90°）时 rotation = 0；吸附到 90° 倍数
            var rot = (round((angleDeg - 90) / 90) * 90).truncatingRemainder(dividingBy: 360)
            if rot > 180 { rot -= 360 }
            if rot < -180 { rot += 360 }
            let oldRot = orig.textRotation ?? 0
            geom.textRotation = rot
            // 90/270 与 0/180 占地宽高互换（绕中心）
            let swapOld = Int(abs(oldRot)) % 180 == 90
            let swapNew = Int(abs(rot)) % 180 == 90
            if swapOld != swapNew {
                var b = orig.bounds
                let cx = b.midX, cy = b.midY
                b = NSRect(x: cx - b.height / 2, y: cy - b.width / 2,
                           width: b.height, height: b.width)
                geom.bounds = b
            } else {
                geom.bounds = orig.bounds
            }
        }
        geom.apply(to: anno)
        selLastGeom = geom
        updateSelectionOverlay()
    }

    /// 按控制点拖拽缩放矩形快照（页面空间；最小 6pt）
    /// handle: 0=左下 1=右下 2=左上 3=右上 4=下中 5=右中 6=上中 7=左中
    /// 对角/对边固定：先在原始 bounds 上锁定不动的边，再由拖动点重算活动边
    private static func resized(_ orig: AnnotationGeomSnapshot, handle: Int, to pt: NSPoint) -> AnnotationGeomSnapshot {
        let ob = orig.bounds
        var minX = ob.minX, minY = ob.minY, maxX = ob.maxX, maxY = ob.maxY
        if [0, 2, 7].contains(handle) { minX = min(pt.x, maxX - 6) }        // 左边随动，右边固定
        if [1, 3, 5].contains(handle) { maxX = max(pt.x, minX + 6) }        // 右边随动，左边固定
        if [0, 1, 4].contains(handle) { minY = min(pt.y, maxY - 6) }        // 下边随动，上边固定
        if [2, 3, 6].contains(handle) { maxY = max(pt.y, minY + 6) }        // 上边随动，下边固定
        var geom = orig
        geom.bounds = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if orig.contentRect != nil {
            // 图案形状：contentRect 与 bounds 的内边距保持不变
            let padX = (orig.bounds.width - orig.contentRect!.width) / 2
            let padY = (orig.bounds.height - orig.contentRect!.height) / 2
            geom.contentRect = geom.bounds.insetBy(dx: padX, dy: padY)
        }
        return geom
    }

    /// 直线端点拖拽：移动 start/end 一端，bounds 按两端点重算（外扩内边距保持）
    private static func lineEndpointResized(_ orig: AnnotationGeomSnapshot, handle: Int, to pt: NSPoint) -> AnnotationGeomSnapshot {
        var s = orig.lineStart ?? .zero
        var e = orig.lineEnd ?? .zero
        if handle == 0 { s = pt } else { e = pt }
        let dx = abs(orig.lineEnd!.x - orig.lineStart!.x)
        let dy = abs(orig.lineEnd!.y - orig.lineStart!.y)
        let padX = max((orig.bounds.width - dx) / 2, 2)
        let padY = max((orig.bounds.height - dy) / 2, 2)
        var geom = orig
        geom.lineStart = s
        geom.lineEnd = e
        geom.bounds = normalizedRectStatic(s, e).insetBy(dx: -padX, dy: -padY)
        return geom
    }

    private static func normalizedRectStatic(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func selectionMouseUp() {
        guard selMode != .none, let anno = selectedAnno, let page = selectedPage,
              let orig = selOrigGeom, let last = selLastGeom else {
            selMode = .none
            return
        }
        selMode = .none
        guard orig != last, let document else { return }
        let idx = document.index(for: page)
        AnnotationUndoStack.shared.push(document: document, pageIndex: idx,
                                        action: .geometry(anno, before: orig, after: last))
        onGeometryEdited?()
        updateSelectionOverlay()
    }

    private func deleteSelected() {
        guard let anno = selectedAnno, let page = selectedPage, let document else { return }
        let idx = document.index(for: page)
        page.removeAnnotation(anno)
        onRemoveAnnotation?(idx, anno)
        deselectAnnotation()
    }

    /// Esc 取消选中；Delete/退格删除选中批注
    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        if selectedAnno != nil {
            if chars == "\u{7F}" || chars == "\u{8}" { deleteSelected(); return }
            if chars == "\u{1B}" { deselectAnnotation(); return }
        } else if chars == "\u{1B}" {
            deselectAnnotation()
        }
        super.keyDown(with: event)
    }

    // MARK: 文本输入弹框（点击页面位置弹出，回车放置；弹框即最终效果实时预览）

    private var textPopup: GhostTextEditor?
    private var textPopupPage: PDFPage?
    private var textPopupRect: NSRect?    // 页面空间放置矩形（随文字宽度/旋转实时更新）
    private var textPopupAnchor: NSPoint? // 页面空间点击锚点
    /// ghost 草稿批注：输入期间挂在页面上，用最终 draw 路径实时渲染（所见即所得）
    private var ghostAnno: RotatableTextAnnotation?
    /// ghost 已提交（进撤销栈）；false 时 endTextInput 会把草稿从页面移除
    private var ghostCommitted = false

    /// 按当前文字/字体/旋转计算弹框与最终放置矩形。
    /// 宽度随文字自适应（上限页宽 92%，超出换行）；90/270° 时放置矩形为旋转后占地。
    private func textGeometry(text: String, page: PDFPage, anchor: NSPoint)
        -> (pageRect: NSRect, viewFrame: NSRect) {
        let font = settings.textFont()
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let str = NSAttributedString(string: text.isEmpty ? "字" : text,
                                     attributes: [.font: font, .paragraphStyle: para])
        let maxW = page.bounds(for: .mediaBox).width * 0.92
        let ts = str.boundingRect(with: NSSize(width: maxW, height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin]).size
        let w = min(max(ceil(ts.width) + 10, 60), ceil(maxW))
        let h = max(ceil(ts.height) + 6, ceil(font.pointSize * 1.5))
        let swap = Int(abs(settings.textRotation)) % 180 == 90
        let pageRect: NSRect = swap
            ? NSRect(x: anchor.x - h / 2, y: anchor.y - w / 2, width: h, height: w)
            : NSRect(x: anchor.x, y: anchor.y - h, width: w, height: h)
        let foot = convert(pageRect, from: page)   // 视图空间旋转后占地
        // 未旋转时弹框即占地；旋转时弹框用未旋转尺寸、绕中心旋转到占地位置
        let viewFrame = swap
            ? NSRect(x: foot.midX - w / 2, y: foot.midY - h / 2, width: w, height: h)
            : foot
        return (pageRect, viewFrame)
    }

    /// 光标与 ghost 字形对齐的关键：ghost 按页面空间渲染后再被 PDFView 缩放显示，
    /// 浮层在视图空间排版——字号/内边距必须乘「页面→视图」缩放比，否则缩放≠100% 时
    /// 每个字符的推进宽度与字形不一致（光标不跟字符走）。
    private func scaleEditorFont(_ editor: GhostTextEditor, scale: CGFloat) {
        let f = settings.textFont()
        guard scale > 0.01, scale.isFinite else { return }
        editor.font = NSFont(descriptor: f.fontDescriptor, size: f.pointSize * scale) ?? f
        editor.textContainerInset = NSSize(width: 3 * scale, height: 3 * scale)
        editor.refreshAttributes()
    }

    /// 编辑器文字 → ghost 批注 + 浮层定位（每次键入/组字/参数变化都会调用）。
    /// ghost 渲染**全量文字（含组字串）**——唯一渲染通道，真·所见即所得；
    /// 浮层彻底隐形（文字全透明），只负责光标和收键盘。
    private func syncGhostFromEditor() {
        guard let editor = textPopup, let page = textPopupPage, let ghost = ghostAnno, let anchor = textPopupAnchor else { return }
        let display = editor.string

        // ghost：最终渲染路径（字体/颜色/背景/旋转与提交后的正式批注完全一致）
        ghost.contents = display
        ghost.font = settings.textFont()
        ghost.fontColor = NSColor(settings.textColor)
        ghost.bgColor = settings.textBgColor.map { NSColor($0) }
        ghost.textRotation = CGFloat(settings.textRotation)
        let geo = textGeometry(text: display, page: page, anchor: anchor)
        // 先给一个微差值再赋真值：bounds 值不变时 PDFKit 不失效，"a"→"b" 等宽替换就不会重绘
        ghost.bounds = geo.pageRect.insetBy(dx: -0.01, dy: -0.01)
        ghost.bounds = geo.pageRect

        // 浮层：同一几何定位；容器加宽防组字串换行（文字透明，宽了无副作用）
        textPopupRect = geo.pageRect
        editor.frame = geo.viewFrame
        editor.textContainer?.containerSize = NSSize(width: geo.viewFrame.width + 200,
                                                     height: .greatestFiniteMagnitude)
        scaleEditorFont(editor, scale: geo.viewFrame.width / max(geo.pageRect.width, 1))
        let swap = Int(abs(settings.textRotation)) % 180 == 90
        editor.frameCenterRotation = swap ? CGFloat(settings.textRotation) : 0
    }

    private func showTextInput(page: PDFPage, point: NSPoint, prefilled: String = "", existingRect: NSRect? = nil) {
        commitTextInput()   // 已开着先提交
        textPopupAnchor = point
        let editor = GhostTextEditor.make()
        editor.font = settings.textFont()
        editor.inkColor = NSColor(settings.textColor)
        editor.string = prefilled
        editor.onCommit = { [weak self] in self?.commitTextInput() }
        editor.onCancel = { [weak self] in self?.cancelTextInput() }
        editor.onTextChanged = { [weak self] in self?.syncGhostFromEditor() }
        addSubview(editor)
        textPopup = editor
        textPopupPage = page

        // ghost 草稿：立即挂到页面（空文本不画），之后每次键入实时刷新
        let startRect = existingRect ?? textGeometry(text: prefilled, page: page, anchor: point).pageRect
        let ghost = RotatableTextAnnotation(bounds: startRect, forType: .stamp, withProperties: nil)
        ghost.contents = prefilled
        ghost.font = settings.textFont()
        ghost.fontColor = NSColor(settings.textColor)
        ghost.color = .clear
        ghost.bgColor = settings.textBgColor.map { NSColor($0) }
        ghost.textRotation = CGFloat(settings.textRotation)
        page.addAnnotation(ghost)
        ghostAnno = ghost
        ghostCommitted = false

        if let existing = existingRect {
            // 编辑已有文本框：保持原占地
            textPopupRect = existing
            let foot = convert(existing, from: page)
            let swap = Int(abs(settings.textRotation)) % 180 == 90
            editor.frame = swap
                ? NSRect(x: foot.midX - foot.height / 2, y: foot.midY - foot.width / 2,
                         width: foot.height, height: foot.width)
                : foot
            editor.frameCenterRotation = swap ? CGFloat(settings.textRotation) : 0
            let baseW = swap ? existing.height : existing.width
            scaleEditorFont(editor, scale: foot.width / max(baseW, 1))
        } else {
            syncGhostFromEditor()
        }
        let frOK = window?.makeFirstResponder(editor) ?? false
        let first = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        if uitestEnabled {
            uitestLog("[UITEST] showTextInput: editor.frame=%@ makeFirstResponder=%@ firstResponder=%@",
                  NSStringFromRect(editor.frame), frOK ? "OK" : "FAIL", first)
        }
        // 临时 UITEST 钩子：状态 dump（定位打字问题用）
        if uitestEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let ed = self.textPopup {
                    uitestLog("[UITEST] dump: isEditable=%d isSelectable=%d hasWindow=%d isFR=%d font=%@",
                              ed.isEditable ? 1 : 0, ed.isSelectable ? 1 : 0,
                              ed.window != nil ? 1 : 0,
                              ed.window?.firstResponder === ed ? 1 : 0,
                              ed.font.map { String(describing: $0) } ?? "nil")
                    uitestLog("[UITEST] dump: initial string=%@ len=%d", ed.string, (ed.string as NSString).length)
                }
            }
        }
    }

    /// 提交：ghost 转正（已在页面上且已是最终状态），进撤销栈；空文本丢弃草稿
    @objc private func commitTextInput() {
        guard let ghost = ghostAnno, let page = textPopupPage, !ghostCommitted else { return }
        let anchor = textPopupAnchor
        // 组字中途失焦提交：只取已上屏部分，组字串（拼音）不落纸
        let text = (textPopup?.committedText ?? (ghost.contents ?? ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ghostCommitted = true
        endTextInput()
        guard !text.isEmpty else {
            page.removeAnnotation(ghost)   // 空文本：草稿不入撤销栈
            return
        }
        ghost.contents = text
        // ghost 边界是按含组字串的全量文字算的：提交前按最终文字重算一次
        if let anchor {
            let geo = textGeometry(text: text, page: page, anchor: anchor)
            ghost.bounds = geo.pageRect
        }
        if let idx = document.map({ $0.index(for: page) }) {
            onAddAnnotation?(idx, ghost)
        }
    }

    private func cancelTextInput() {
        endTextInput()
    }

    private func endTextInput() {
        textPopup?.removeFromSuperview()
        textPopup = nil
        if let ghost = ghostAnno, !ghostCommitted, let page = textPopupPage {
            page.removeAnnotation(ghost)   // 取消/中断：草稿不入撤销栈
        }
        ghostAnno = nil
        textPopupPage = nil
        textPopupRect = nil
        textPopupAnchor = nil
        window?.makeFirstResponder(self)
    }

    /// 输入开着时参数（字体/字号/颜色/背景/旋转）变化 → ghost 即时重绘（真正的实时预览）
    func refreshTextPopupIfOpen(settings: ToolSettings) {
        guard let editor = textPopup else { return }
        editor.font = settings.textFont()
        editor.inkColor = NSColor(settings.textColor)   // 触发 refreshAttributes
        syncGhostFromEditor()
        editor.needsDisplay = true
    }

    // MARK: 文字感知批注（非扫描版：划选文字 → 逐行精准落批注）

    /// 当前工具是否支持文字感知模式（划选文字精准批注）
    private var toolSupportsTextMarkup: Bool {
        switch activeTool {
        case .highlight, .underline, .strikeOut: return true
        default: return false
        }
    }

    /// 页面是否有可用文字层（扫描版 page.string 为空）
    private func pageHasText(_ page: PDFPage) -> Bool {
        if textProbePage === page { return textProbeResult }
        let s = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        textProbePage = page
        textProbeResult = !s.isEmpty
        return textProbeResult
    }

    /// 收割当前文字选区：按行（selectionsByLine）生成批注；按页分组入撤销栈（跨页划选每页一条记录）
    private func harvestTextSelection() {
        guard let tool = activeTool, toolSupportsTextMarkup, let sel = currentSelection else { return }
        setCurrentSelection(nil, animate: false)   // 先清选区，避免蓝色高亮残留干扰视觉
        var byPage: [Int: (page: PDFPage, annos: [PDFAnnotation])] = [:]
        for line in sel.selectionsByLine() {
            guard let page = line.pages.first else { continue }
            let idx = document.map { $0.index(for: page) } ?? -1
            guard idx >= 0 else { continue }
            let b = line.bounds(for: page)
            guard b.width > 1, b.height > 1 else { continue }
            let annos = markupAnnotations(tool: tool, lineText: line.string ?? "", lineBounds: b)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for a in annos {
                page.addAnnotation(a)
                byPage[idx, default: (page, [])].annos.append(a)
            }
            CATransaction.commit()
        }
        for (idx, group) in byPage where !group.annos.isEmpty {
            onAddBatch?(idx, group.annos)
        }
        if let e = NSApp.currentEvent { updateCursor(at: e) }
    }

    /// 按选中行的文字框生成批注：
    /// 高亮 = 原生 Highlight 整行框（PDFKit 自动衬在字形后）；
    /// 下划线/删除线 = 沿行框底/中的自绘笔迹（沿用线条宽度/波浪/颜色设置与橡皮擦机制，原生类型不读宽度）
    private func markupAnnotations(tool: EditTool, lineText: String, lineBounds b: NSRect) -> [PDFAnnotation] {
        switch tool {
        case .highlight:
            let anno = PDFAnnotation(bounds: b, forType: .highlight, withProperties: nil)
            anno.color = NSColor(settings.highlightColor).withAlphaComponent(0.40)
            return [anno]
        case .underline:
            let color = NSColor(settings.underlineColor)
            let width = CGFloat(settings.underlineWidth)
            // CJK 字形几乎占满行框（16% 处已穿字），贴行底 3%；西文行框含下伸部空间，16% 落在字形下
            let y = b.minY + b.height * (Self.lineTextHasCJK(lineText) ? 0.03 : 0.16)
            if settings.underlineWavy,
               let w = wavyInk(a: NSPoint(x: b.minX, y: y), b: NSPoint(x: b.maxX, y: y),
                               color: color, width: width) {
                w.role = "underline"
                return [w]
            }
            let s = PenStrokeAnnotation(pts: Self.densifiedLine(a: NSPoint(x: b.minX, y: y),
                                                                 b: NSPoint(x: b.maxX, y: y)),
                                        color: color, width: width)
            s.role = "underline"
            return [s]
        case .strikeOut:
            let y = b.midY
            let s = PenStrokeAnnotation(pts: Self.densifiedLine(a: NSPoint(x: b.minX, y: y),
                                                                 b: NSPoint(x: b.maxX, y: y)),
                                        color: NSColor(settings.strikeColor),
                                        width: CGFloat(settings.strikeWidth))
            s.role = "strikeOut"
            return [s]
        default:
            return []
        }
    }

    /// 行文字是否含 CJK 字符（汉字/假名/谚文/全形符号）——决定下划线落位高度
    static func lineTextHasCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            ($0.value >= 0x2E80 && $0.value <= 0x9FFF)   // 部首扩展~CJK统一表意/假名/谚文
                || ($0.value >= 0xF900 && $0.value <= 0xFAFF) // CJK兼容表意
                || ($0.value >= 0xFF00 && $0.value <= 0xFFEF) // 全形符号
        }
    }

    // MARK: 生成批注

    private func makeAnnotation(tool: EditTool?, page: PDFPage, a: NSPoint, b: NSPoint) -> PDFAnnotation? {
        switch tool {
        case .highlight:
            let rect = normalizedRect(a, b)
            guard rect.width > 2, rect.height > 2 else { return nil }
            let anno = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
            anno.color = NSColor(settings.highlightColor).withAlphaComponent(0.40)
            return anno

        case .underline:
            guard abs(b.x - a.x) > 2 else { return nil }
            let color = NSColor(settings.underlineColor)
            let width = CGFloat(settings.underlineWidth)
            if settings.underlineWavy {
                let w = wavyInk(a: a, b: b, color: color, width: width)
                w?.role = "underline"
                return w
            }
            // 直线也走自绘笔迹：原生 .underline 类型不读 PDFBorder.lineWidth（宽度不生效根因），
            // 与形状直线同机制，最终宽度/颜色与预览一致。
            // 直线加密成多点笔迹（每 3pt 一点）：两点直线被橡皮擦切分后存活段不足 2 点会整条丢弃，
            // 导致「只擦除触及部分」无法部分擦除直线
            let straight = PenStrokeAnnotation(pts: Self.densifiedLine(a: a, b: b), color: color, width: width)
            straight.role = "underline"
            return straight

        case .strikeOut:
            guard abs(b.x - a.x) > 2 else { return nil }
            // 同上：原生 .strikeOut 不读 border 宽度，改自绘 + 加密
            let s = PenStrokeAnnotation(pts: Self.densifiedLine(a: a, b: b),
                                        color: NSColor(settings.strikeColor),
                                        width: CGFloat(settings.strikeWidth))
            s.role = "strikeOut"
            return s

        case .pen:
            return penInk()

        case .shape:
            return shapeAnnotation(a: a, b: b)

        case .redact:
            let rect = normalizedRect(a, b)
            guard rect.width > 2, rect.height > 2 else { return nil }
            let redactNS = NSColor(settings.redactColor)
            let anno = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            anno.color = redactNS
            anno.interiorColor = redactNS   // 填充遮盖
            anno.userName = DocumentStore.redactMarker   // 保存时据此压平进页面内容
            return anno

        default:
            return nil
        }
    }

    // MARK: 波浪线（macOS PDFKit 无 Squiggly 子类型，用自绘笔迹画正弦波）

    /// 直线加密：两点之间每 ~3pt 补一个中间点（供自绘笔迹的部分擦除切分使用）
    private static func densifiedLine(a: NSPoint, b: NSPoint) -> [NSPoint] {
        let dist = hypot(b.x - a.x, b.y - a.y)
        let n = max(Int(dist / 3.0), 1)
        return (0...n).map { i in
            let t = CGFloat(i) / CGFloat(n)
            return NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    private func wavyInk(a: NSPoint, b: NSPoint, color: NSColor, width: CGFloat) -> PenStrokeAnnotation? {
        let midY = (a.y + b.y) / 2
        let x0 = min(a.x, b.x), x1 = max(a.x, b.x)
        let amp: CGFloat = 2.5, period: CGFloat = 8.0
        var pts: [NSPoint] = []
        var x = x0
        while x <= x1 {
            pts.append(NSPoint(x: x, y: midY + amp * sin((x - x0) / period * 2 * .pi)))
            x += 1
        }
        guard pts.count > 1 else { return nil }
        return PenStrokeAnnotation(pts: pts, color: color, width: width)
    }

    // MARK: 手绘笔（拖动采集点列 → 平滑 → 自绘笔迹批注）

    private func penInk() -> PDFAnnotation? {
        var pts = penPoints
        guard pts.count > 1 else { return nil }
        if settings.penSmooth {
            pts = smoothed(pts)
        }
        return PenStrokeAnnotation(pts: pts,
                                   color: NSColor(settings.penColor).withAlphaComponent(CGFloat(settings.penOpacity)),
                                   width: CGFloat(settings.penWidth))
    }

    /// 滑动平均平滑（窗口 5 双趟；「原始」完全跟随鼠标轨迹）
    private func smoothed(_ pts: [NSPoint]) -> [NSPoint] {
        guard pts.count > 4 else { return pts }
        func pass(_ input: [NSPoint]) -> [NSPoint] {
            var out: [NSPoint] = [input[0]]
            for i in 1..<(input.count - 1) {
                let lo = max(i - 2, 0), hi = min(i + 2, input.count - 1)
                var sx: CGFloat = 0, sy: CGFloat = 0
                for j in lo...hi { sx += input[j].x; sy += input[j].y }
                out.append(NSPoint(x: sx / CGFloat(hi - lo + 1), y: sy / CGFloat(hi - lo + 1)))
            }
            out.append(input[input.count - 1])
            return out
        }
        return pass(pass(pts))
    }

    // MARK: 形状（矩形/椭圆自绘支持填充图案；直线/箭头走 .line 批注）

    private func shapeAnnotation(a: NSPoint, b: NSPoint) -> PDFAnnotation? {
        let opacity = CGFloat(settings.shapeOpacity)
        let strokeColor = NSColor(settings.shapeStrokeColor).withAlphaComponent(opacity)
        let width = CGFloat(settings.shapeStrokeWidth)
        let dash = settings.shapeDash

        switch settings.shapeVariant {
        case .rect, .ellipse:
            let rect = normalizedRect(a, b)
            guard rect.width > 2, rect.height > 2 else { return nil }
            // bounds 按线宽外扩，粗描边不被注记边界截断；实际绘制区域用 contentRect 记录
            // 用 .stamp 类型强制 PDFKit 走自绘外观流（.square 类型 macOS 上画完不显示）
            let pad = width / 2 + 2
            let outer = rect.insetBy(dx: -pad, dy: -pad)
            let anno = PatternShapeAnnotation(bounds: outer, forType: .stamp, withProperties: nil)
            anno.contentRect = rect
            anno.isEllipse = settings.shapeVariant == .ellipse
            anno.pattern = settings.shapePattern
            anno.fillCol = settings.shapeFillColor.map { NSColor($0).withAlphaComponent(opacity) }
            anno.strokeCol = strokeColor
            anno.strokeW = width
            anno.dash = dash
            anno.color = .clear
            return anno

        case .line, .arrow, .doubleArrow:
            guard hypot(b.x - a.x, b.y - a.y) > 3 else { return nil }
            let rect = normalizedRect(a, b).insetBy(dx: -width - 6, dy: -width - 6)
            let l = PDFAnnotation(bounds: rect, forType: .line, withProperties: nil)
            // PDFKit 的 startPoint/endPoint 是相对注记 bounds 原点的坐标（不是页面空间）
            l.startPoint = NSPoint(x: a.x - rect.origin.x, y: a.y - rect.origin.y)
            l.endPoint = NSPoint(x: b.x - rect.origin.x, y: b.y - rect.origin.y)
            l.startLineStyle = settings.shapeVariant == .doubleArrow ? .openArrow : .none
            l.endLineStyle = (settings.shapeVariant == .arrow || settings.shapeVariant == .doubleArrow)
                ? .openArrow : .none
            l.color = strokeColor
            let border = PDFBorder()
            border.lineWidth = width
            if let dash = dash, !dash.isEmpty {
                border.dashPattern = dash
            }
            l.border = border
            return l
        }
    }

    private func normalizedRect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func hitPage(_ event: NSEvent) -> PDFPage? {
        let loc = convert(event.locationInWindow, from: nil)
        return page(for: loc, nearest: true)
    }
}
