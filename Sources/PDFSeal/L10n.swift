import Foundation

/// 取本地化字符串（源语言为简体中文，键即中文原文）
func L(_ key: String) -> String { L10n.t(key) }

/// 带参数的本地化字符串（键中使用 %d / %@ 占位）
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.t(key), locale: Locale.current, arguments: args)
}

enum L10n {
    /// 跟随系统语言：en / zh-Hans / zh-Hant（其他中文变体归入简体或繁体）
    static var langCode: String {
        let pref = Bundle.main.preferredLocalizations.first
            ?? Locale.preferredLanguages.first ?? "zh-Hans"
        if pref.hasPrefix("en") { return "en" }
        if pref.contains("Hant") || pref.contains("HK") || pref.contains("MO") { return "zh-Hant" }
        return "zh-Hans"
    }

    static func t(_ key: String) -> String {
        switch langCode {
        case "en": return en[key] ?? key
        case "zh-Hant": return zhHant[key] ?? key
        default: return key
        }
    }

    static let en: [String: String] = [
        "PDF 骑缝章": "PDF Seal",
        "打开": "Open",
        "保存": "Save",
        "另存为": "Save As",
        "关闭": "Close",
        "拼合校验": "Jigsaw Check",
        "出错了": "Error",
        "好": "OK",
        "是否确认关闭？": "Close this document?",
        "取消": "Cancel",
        "确定": "OK",
        "把 PDF 拖进来，或点「打开」选择文件": "Drag a PDF here, or click “Open PDF…”",
        "打开 PDF…": "Open PDF…",
        "已载入 %d 页": "Loaded · %d pages",
        "已保存：%@": "Saved: %@",
        "已导出：%@": "Exported: %@",
        "请先打开 PDF": "Open a PDF first",
        "请先添加印章再保存": "Add a stamp before saving",
        "请先添加印章再导出": "Add a stamp before exporting",
        "文件名后缀": "seam-stamped",
        "骑缝章": "Seam Stamps",
        "缝位": "Edge",
        "右缝": "Right",
        "左缝": "Left",
        "上缝": "Top",
        "下缝": "Bottom",
        "全部页": "All Pages",
        "页码": "Page",
        "上": "Up",
        "下": "Down",
        "添加": "Add",
        "移除全部": "Remove All",
        "正文章": "Body Stamps",
        "添加一枚按当前选项盖章的章；可多次添加多枚。添加后点击页面落位、拖动微调、右键章可删除":
            "Click Add to place a stamp with the current options — add as many as you need. After that: click to position, drag to fine-tune, right-click to delete.",
        "已添加 %d 枚章；点击预览中的章可选中它":
            "%d stamps added — click a stamp in the preview to select it",
        "已添加 %d 条骑缝章；调整本滑杆后点「添加」可错开上下位置":
            "%d seam stamps added — adjust the slider and click Add to stagger them vertically",
        "删除本页章": "Remove from This Page",
        "删除此章（所有页）": "Delete Stamp (All Pages)",
        "恢复本页章": "Restore on This Page",
        "删除本页骑缝章条": "Remove This Seam Slice",
        "删除此骑缝章（所有页）": "Delete Seam Stamp (All Pages)",
        "恢复本页骑缝章条": "Restore This Seam Slice",
        "缩放": "Zoom",
        "印章库": "Seal Library",
        "还没有印章\n点右上角 + 导入章图": "No seals yet\nClick + to import an image",
        "导入印章图片（PNG / JPG）": "Import seal image (PNG / JPG)",
        "选择印章图片（扫描或拍照的章图均可）": "Choose a seal image — scanned or photographed works",
        "删除": "Delete",
        "新建图章": "New Seal",
        "白色转成透明": "Make White Transparent",
        "容错": "Tolerance",
        "尺寸(cm)": "Size (cm)",
        "锁定比例": "Lock Aspect Ratio",
        "名称": "Name",
        "印章名称": "Seal name",
        "章预览": "Seal preview",
        "印章": "Seal",
        "保存印章失败": "Failed to save seal",
        "保存印章失败：%@": "Failed to save seal: %@",
        "仅支持 PDF 文件": "Only PDF files are supported",
        "无法打开 PDF（可能已加密或损坏）": "Cannot open PDF (it may be encrypted or damaged)",
        "模拟拼合校验": "Seam Jigsaw Preview",
        "把每页边缘的章条按页序拼合，应能还原出右侧的完整印章":
            "The slices from page edges reassemble into the full seal on the right",
        "拼合结果": "Reassembled",
        "原始印章": "Original Seal",
        "请先选择印章": "Select a seal first",
        "当前页范围：第 %d — %d 页（共 %d 条）": "Page range: %d – %d (%d slices)",
    ]

    static let zhHant: [String: String] = [
        "PDF 骑缝章": "PDF 騎縫章",
        "打开": "打開",
        "保存": "儲存",
        "另存为": "另存為",
        "关闭": "關閉",
        "拼合校验": "拼合校驗",
        "出错了": "發生錯誤",
        "好": "好",
        "是否确认关闭？": "是否確認關閉？",
        "取消": "取消",
        "确定": "確定",
        "把 PDF 拖进来，或点「打开」选择文件": "將 PDF 拖進來，或點「打開」選擇文件",
        "打开 PDF…": "打開 PDF…",
        "已载入 %d 页": "已載入 %d 頁",
        "已保存：%@": "已儲存：%@",
        "已导出：%@": "已匯出：%@",
        "请先打开 PDF": "請先打開 PDF",
        "请先添加印章再保存": "請先新增印章再儲存",
        "请先添加印章再导出": "請先新增印章再匯出",
        "文件名后缀": "騎縫章",
        "骑缝章": "騎縫章",
        "缝位": "縫位",
        "右缝": "右縫",
        "左缝": "左縫",
        "上缝": "上縫",
        "下缝": "下縫",
        "全部页": "全部頁面",
        "页码": "頁碼",
        "上": "上",
        "下": "下",
        "添加": "新增",
        "移除全部": "全部移除",
        "正文章": "正文印章",
        "添加一枚按当前选项盖章的章；可多次添加多枚。添加后点击页面落位、拖动微调、右键章可删除":
            "每次「新增」會以目前選項放置一枚印章，可連續新增多枚。新增後點擊頁面落位、拖曳微調、右鍵章可刪除",
        "已添加 %d 枚章；点击预览中的章可选中它":
            "已新增 %d 枚印章；點擊預覽中的印章可選取它",
        "已添加 %d 条骑缝章；调整本滑杆后点「添加」可错开上下位置":
            "已新增 %d 條騎縫章；調整本滑桿後點「新增」可錯開上下位置",
        "删除本页章": "刪除本頁印章",
        "删除此章（所有页）": "刪除此印章（所有頁面）",
        "恢复本页章": "回復本頁印章",
        "删除本页骑缝章条": "刪除本頁騎縫章條",
        "删除此骑缝章（所有页）": "刪除此騎縫章（所有頁面）",
        "恢复本页骑缝章条": "回復本頁騎縫章條",
        "缩放": "縮放",
        "印章库": "印章庫",
        "还没有印章\n点右上角 + 导入章图": "尚無印章\n點右上角 + 匯入章圖",
        "导入印章图片（PNG / JPG）": "匯入印章圖片（PNG / JPG）",
        "选择印章图片（扫描或拍照的章图均可）": "選擇印章圖片（掃描或拍照的章圖均可）",
        "删除": "刪除",
        "新建图章": "新增圖章",
        "白色转成透明": "白色轉為透明",
        "容错": "容錯",
        "尺寸(cm)": "尺寸 (cm)",
        "锁定比例": "鎖定比例",
        "名称": "名稱",
        "印章名称": "印章名稱",
        "章预览": "章預覽",
        "印章": "印章",
        "保存印章失败": "儲存印章失敗",
        "保存印章失败：%@": "儲存印章失敗：%@",
        "仅支持 PDF 文件": "僅支援 PDF 文件",
        "无法打开 PDF（可能已加密或损坏）": "無法打開 PDF（可能已加密或損壞）",
        "模拟拼合校验": "模擬拼合校驗",
        "把每页边缘的章条按页序拼合，应能还原出右侧的完整印章":
            "把每頁邊緣的章條按頁序拼合，應能還原出右側的完整印章",
        "拼合结果": "拼合結果",
        "原始印章": "原始印章",
        "请先选择印章": "請先選擇印章",
        "当前页范围：第 %d — %d 页（共 %d 条）": "目前頁面範圍：第 %d — %d 頁（共 %d 條）",
    ]
}
