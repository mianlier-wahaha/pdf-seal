import SwiftUI
import AppKit

extension View {
    /// 悬停显示小手（可交互控件），移开恢复箭头。
    /// 用 set 而非 push/pop：与 AnnotationPDFView 的手动 set 光标同一套机制，避免栈不平衡。
    /// 背景：macOS 原生按钮默认不显示 pointer（那是 Web 惯例），控制区必须显式声明。
    func handCursor() -> some View {
        onHover { hovering in
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}
