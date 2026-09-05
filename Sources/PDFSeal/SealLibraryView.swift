import SwiftUI
import UniformTypeIdentifiers

struct SealLibraryView: View {
    @EnvironmentObject private var seals: SealStore
    @EnvironmentObject private var settings: StampSettings
    @EnvironmentObject private var doc: DocumentStore
    @State private var pendingImport: PendingImport?
    @State private var draggingItem: SealItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("印章库")).font(.headline)
                Spacer()
                Button { pickSealImage() } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .help(L("导入印章图片（PNG / JPG）"))
            }
            .padding(12)

            if seals.seals.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "seal").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(L("还没有印章\n点右上角 + 导入章图")).font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    List {
                        ForEach(seals.seals) { item in
                            SealRow(item: item)
                                .listRowBackground(item.id == seals.selectedID ? Color.accentColor.opacity(0.15) : .clear)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    seals.selectedID = item.id
                                    let d = seals.physicalSize(for: item.id)
                                    settings.applySealPhysicalSize(widthCm: d.widthCm, heightCm: d.heightCm,
                                                                   pageHeightPt: doc.pageSizes.first?.height)
                                }
                                .contextMenu {
                                    Button(L("删除"), role: .destructive) { seals.delete(item) }
                                }
                                // 拖拽重排：AppKit 级 onDrag/onDrop 实时换位（sidebar List 的 .onMove 在
                                // macOS 上经常不触发拖拽，故不用）。拖起时章图跟随光标，dropEntered 换位。
                                .onDrag {
                                    draggingItem = item
                                    return NSItemProvider(object: item.id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate:
                                    SealRowDropDelegate(item: item, dragging: $draggingItem, store: seals))
                        }
                    }
                    .listStyle(.sidebar)
                    // 兜底：拖到行与行之间的空隙/列表空白处松手也能结束并落盘
                    .onDrop(of: [.text], delegate:
                        SealListDropDelegate(dragging: $draggingItem, store: seals))
                    Text(L("拖拽可排序；选中后按 ↑/↓ 上下移动"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
        }
        .sheet(item: $pendingImport) { pending in
            SealCreateSheet(pending: pending) {
                pendingImport = nil
            }
        }
    }

    /// NSOpenPanel 直调：SwiftUI fileImporter 在部分视图层级下不弹窗
    private func pickSealImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.message = L("选择印章图片（扫描或拍照的章图均可）")
        let handle: (URL) -> Void = { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let img = NSImage(contentsOf: url) else {
                seals.importError = "无法读取图片，请使用 PNG/JPG"
                return
            }
            pendingImport = PendingImport(
                image: img,
                suggestedName: url.deletingPathExtension().lastPathComponent)
        }
        if let win = NSApp.mainWindow {
            panel.beginSheetModal(for: win) { resp in
                if resp == .OK, let url = panel.url { handle(url) }
            }
        } else {
            if panel.runModal() == .OK, let url = panel.url { handle(url) }
        }
    }
}

private struct SealRow: View {
    @EnvironmentObject private var seals: SealStore
    let item: SealItem

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let img = seals.image(for: item.id) {
                    Image(nsImage: img).resizable().scaledToFit()
                } else {
                    Image(systemName: "seal").font(.system(size: 40))
                }
            }
            .frame(width: 64, height: 64)
            TextField("", text: nameBinding)
                .textFieldStyle(.plain)
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var nameBinding: Binding<String> {
        Binding(get: { item.name }, set: { seals.rename(item, to: $0) })
    }
}

/// 行级落点：拖到某行上时把被拖章实时移动到该行位置
private struct SealRowDropDelegate: DropDelegate {
    let item: SealItem
    @Binding var dragging: SealItem?
    let store: SealStore

    func dropEntered(info: DropInfo) {
        guard let dragged = dragging, dragged.id != item.id else { return }
        store.moveSeal(dragged, to: item)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if dragging != nil { store.persistOrder() }
        dragging = nil
        return true
    }
}

/// 列表级兜底落点：松手在行间空隙/空白处也能结束拖拽并落盘
private struct SealListDropDelegate: DropDelegate {
    @Binding var dragging: SealItem?
    let store: SealStore

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if dragging != nil { store.persistOrder() }
        dragging = nil
        return true
    }
}
