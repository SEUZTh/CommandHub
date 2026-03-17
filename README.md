# CommandHub

CommandHub 是一个 macOS SwiftUI 应用，用来自动收集你复制过的命令文本，并通过全局快捷键快速搜索、重新复制。

当前版本的定位很明确：

- 后台监听剪贴板
- 将识别到的命令保存到内存
- 按快捷键弹出搜索窗口
- 选中一条命令后重新复制到系统剪贴板

它不会直接执行命令，只负责“收集”和“找回”。

## 功能概览

- 全局快捷键：`Command + Shift + V`
- 自动监听剪贴板中的文本变化
- 按行解析文本并提取命令
- 支持关键字搜索历史命令
- 支持键盘上下选择、回车复制、`Esc` 关闭
- 最多保留最近 `200` 条命令

## 运行要求

- macOS 13+
- Xcode 15+，或支持 Swift 5.9 的本地工具链

## 启动方式

### 使用 SwiftPM

```bash
swift build
swift run
```

### 使用 Xcode

1. 打开 `CommandHub.xcodeproj`
2. 选择 `CommandHub` Scheme
3. 点击 Run

Bundle ID: `ttt.CommandHub`

## 启动后如何使用

应用启动后不会自动弹出主界面，这是当前实现的正常行为。程序会在后台运行，并立即开始做两件事：

1. 监听系统剪贴板
2. 注册全局快捷键 `Command + Shift + V`

实际使用流程如下：

1. 保持应用在后台运行。
2. 在任意应用中复制一段文本。
3. CommandHub 会检查剪贴板内容，并按行提取可保存的命令。
4. 需要复用命令时，按 `Command + Shift + V` 打开搜索窗口。
5. 在搜索框中输入关键字筛选命令。
6. 使用方向键选择结果，按回车将选中的命令复制到剪贴板。
7. 或者直接点击列表中的某一行，也会立即复制该命令。
8. 回到终端或其他应用粘贴使用。

## 命令收集规则

剪贴板中的文本会按行拆分。满足以下条件的行会被视为可保存命令：

- 非空
- 不以 `#` 开头
- 长度不少于 2 个字符

例如下面这段文本：

```bash
# build
npm install
npm run dev
```

最终会保存：

- `npm install`
- `npm run dev`

## 搜索窗口行为

弹出窗口后：

- 搜索框会自动获得焦点
- 默认选中第一条结果
- 回车：复制当前选中项
- 方向键上/下：切换选中项
- 鼠标点击：直接复制对应命令
- `Esc`：关闭窗口

## 当前限制

当前版本仍然是一个最小可用实现，已知限制如下：

- 命令历史只保存在内存中，退出应用后会丢失
- 只做“重新复制”，不直接执行命令
- 只避免“最新一条与上一条完全相同”的连续重复
- 上下文信息目前是占位值，尚未解析真实环境或页面信息
- 设置页面目前只是占位界面

## 计划文档

- 当前计划入口：[PLAN.md](/Users/zth/MyProjects/CommandHub/PLAN.md)
- 版本计划目录：[docs/plans/README.md](/Users/zth/MyProjects/CommandHub/docs/plans/README.md)

## 项目结构

```text
Sources/CommandHub/
├── App/                 # 应用入口与生命周期
├── Core/
│   ├── Clipboard/       # 剪贴板监听
│   ├── Context/         # 上下文解析
│   └── Parser/          # 命令解析
├── Data/Models/         # 数据模型
├── Features/Launcher/   # 快捷启动窗口与交互
└── Services/            # 热键与存储服务
```

## 依赖

- [HotKey](https://github.com/soffes/HotKey)

## 后续可扩展方向

- 持久化历史记录
- 菜单栏图标和菜单
- 命令分组、标签、收藏
- 上下文感知过滤
- 多设备同步
- 历史清理和导出
