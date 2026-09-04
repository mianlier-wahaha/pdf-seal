import Foundation
import PDFKit

public enum PageBox {
    /// 页面显示尺寸（已叠加 /Rotate；PDFKit bounds(for:) 不含旋转，需手动换算）
    public static func displayedSize(_ page: PDFPage) -> CGSize {
        let b = page.bounds(for: .mediaBox).size
        let r = Int(page.rotation) % 360
        return (r == 90 || r == 270) ? CGSize(width: b.height, height: b.width) : b
    }
}
