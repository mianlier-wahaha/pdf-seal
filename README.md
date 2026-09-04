# PDF 骑缝章

一个原生 macOS 应用，为 PDF 文件加盖**电子骑缝章**与**正文章**。SwiftUI + PDFKit/CoreGraphics 实现，零第三方依赖，纯本地处理，不上传任何文件。

![平台](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## 功能

### 骑缝章
- 四种缝位：右缝 / 左缝 / 上缝 / 下缝
- 页范围：全部页或指定起止页
- **上下偏移**：拖动滑杆实时调整章条在缝上的位置，多条骑缝章可错开互不覆盖
- 支持添加多条骑缝章实例，各自锁定印章、缝位、范围与偏移

### 正文章
- 点击页面任意位置落章，支持多次添加多枚
- 选中章后：拖动移动位置、右下角控制点等比缩放
- 每枚章实例**锁定添加时的印章**，切换印章库互不影响

### 印章库
- 导入 PNG / JPG 图片创建电子章
- **白色转透明**：带容错阈值滑杆的实时预览，扫描件、拍照图均可处理
- 物理尺寸设定（厘米），支持锁定长宽比；同一枚章在不同纸张规格上保持实际打印大小
- 印章库持久化存储，重开应用自动恢复

### 预览与文件
- 页面缩放：双指捏合 / 输入框 / 预设（25%–200%）
- 页码跳转、底部状态栏
- 保存（覆盖原文件）/ 另存为 / 关闭
- `Esc` 取消选中，`⌘Z` / `Ctrl+Z` 撤销上一次调整

## 环境要求

- macOS 13.0 及以上
- Xcode Command Line Tools（`xcode-select --install`）

## 构建与运行

```bash
# 方式一：命令行直接运行
swift run PDFSeal

# 方式二：打包成 .app（同时生成 release/ 下的 zip 与 dmg）
./scripts/make_app.sh
```

> 注意：macOS 新版 SwiftPM 沙箱与本机策略可能冲突，构建需带 `--disable-sandbox`（脚本已处理）。

## 项目结构

```
Sources/
├── SealCore/    # 盖章引擎：骑缝/正章几何计算、PDF 导出、测试资产
├── PDFSeal/     # SwiftUI 应用界面
└── SealTool/    # 无头验证 CLI（生成测试 PDF、盖章、渲染比对）
scripts/         # 打包脚本（.app / zip / dmg）与图标生成
```

## 技术要点

- 盖章以 CoreGraphics 原生矢量绘制贴片，**不栅格化**，生成文件体积小、文字可选中
- 正确处理页面 `/Rotate` 旋转：旋转页的骑缝章按显示方向计算
- 采用「按页面尺寸分组 → 临时 PDF → PDFKit 按页序合并」方案，规避 macOS 26 上 per-page MediaBox 不生效的问题

## License

[MIT](LICENSE)
