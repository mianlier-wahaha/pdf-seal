import SwiftUI
import Combine
import PDFKit

// MARK: - 多文档会话：每个标签页一套独立的 文档 + 章参数，印章库全局共享

@MainActor
final class Session: ObservableObject {
    let id = UUID()
    let doc = DocumentStore()
    let settings = StampSettings()
    private var cancellables: [AnyCancellable] = []

    init() {
        // 会话内：章参数变更 → 该会话文档脏标记（原先挂在 AppDelegate.bind，多会话后随会话建）
        settings.$qifengStamps.dropFirst().sink { [weak doc] _ in doc?.isDirty = true }.store(in: &cancellables)
        settings.$fullStamps.dropFirst().sink { [weak doc] _ in doc?.isDirty = true }.store(in: &cancellables)
        settings.$watermark.dropFirst().sink { [weak doc] _ in doc?.isDirty = true }.store(in: &cancellables)
    }

    var title: String { doc.url?.lastPathComponent ?? L("未命名") }

    /// 打开文件到本会话（若该会话已开着同一文件则刷新）
    func load(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        doc.load(url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        settings.syncPageCount(doc.pageCount)
        doc.isDirty = false   // syncPageCount 的清空会触发脏标记，这里回置
    }
}

@MainActor
final class Workspace: ObservableObject {
    /// 启动即含一个空白会话；关闭最后一个标签时也回到空白会话
    @Published var sessions: [Session] = [Session()]
    @Published var activeIndex: Int = 0

    var active: Session { sessions[activeIndex] }

    /// 打开 PDF：已开着同一文件则切过去；存在空白会话（启动默认页）则就地替换；否则新开标签
    @discardableResult
    func openURL(_ url: URL) -> Session {
        if let i = sessions.firstIndex(where: { $0.doc.url == url }) {
            activeIndex = i
            return sessions[i]
        }
        if let i = sessions.firstIndex(where: { $0.doc.url == nil && !$0.doc.isDirty }) {
            sessions[i].load(url: url)
            activeIndex = i
            return sessions[i]
        }
        let s = Session()
        s.load(url: url)
        sessions.append(s)
        activeIndex = sessions.count - 1
        return s
    }

    /// 关闭标签：切到相邻标签；全关时回到一个空白会话
    func close(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions.remove(at: i)
        if sessions.isEmpty {
            sessions = [Session()]
            activeIndex = 0
        } else if activeIndex >= sessions.count {
            activeIndex = sessions.count - 1
        } else if activeIndex > i {
            // 关闭的是当前标签左侧的：当前下标前移一位，保持指向同一会话
            activeIndex -= 1
        }
    }

    /// 拖拽排序
    func move(_ id: UUID, to index: Int) {
        guard let i = sessions.firstIndex(where: { $0.id == id }), i != index,
              sessions.indices.contains(index) else { return }
        let s = sessions.remove(at: i)
        sessions.insert(s, at: index)
        if let ni = sessions.firstIndex(where: { $0.id == s.id }) {
            activeIndex = ni
        }
    }
}
