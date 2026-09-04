import SwiftUI

/// Slider 拖动结束回调（SwiftUI Slider 无原生 onEditingChanged 的 label 变体，用包装实现）
struct SliderEditEnd: ViewModifier {
    let action: () -> Void
    @State private var isEditing = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isEditing { isEditing = true }
                    }
                    .onEnded { _ in
                        if isEditing {
                            isEditing = false
                            action()
                        }
                    }
            )
    }
}

extension View {
    func onEditingEnded(_ action: @escaping () -> Void) -> some View {
        modifier(SliderEditEnd(action: action))
    }
}
