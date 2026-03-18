# CommandHub

CommandHub 是一个 macOS SwiftUI 应用，用来自动收集你复制过的命令文本，并通过全局快捷键快速搜索、重新复制，并逐步把命令沉淀为可管理的个人知识条目。

当前版本的定位很明确：

- 后台监听剪贴板
- 将识别到的命令保存到本地 SQLite
- 按快捷键弹出搜索窗口
- 根据当前上下文优先推荐更合适的命令
- 支持收藏、别名、备注、分类和 workspace 归属
- 在结果列表旁查看详情并编辑命令元数据

它不会直接执行命令，只负责“收集”和“找回”。

## 功能概览

- 全局快捷键：`Command + Shift + V`
- 自动监听剪贴板中的文本变化
- 按行解析文本并提取命令
- 支持关键字搜索历史命令
- 支持基于当前浏览器环境的上下文排序
- 支持优先从 URL query `env` 识别业务环境名
- 支持 `All / Current Env Only` 搜索范围切换
- 支持 `Favorites / Category / Workspace` 过滤
- 支持命令分类、收藏、别名、备注与 workspace 归属
- 支持结果列表 + 详情区双栏浏览
- 支持 Settings 页面管理 workspace
- 支持键盘上下选择、回车复制、`Cmd + Enter` 复制并关闭、`Esc` 关闭
- 默认展示最多 `200` 条候选结果

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

## 权限说明

- 当 CommandHub 尝试读取 Chrome 或 Safari 当前标签页 URL 时，macOS 会弹出自动化权限提示。
- 该权限只用于解析当前 `url / domain / env`，从而提升搜索排序质量。
- 若用户拒绝授权，CommandHub 仍然可以正常采集、搜索和复制命令，只是不会启用浏览器上下文能力。

## 启动后如何使用

应用启动后不会自动弹出主界面，这是当前实现的正常行为。程序会在后台运行，并立即开始做两件事：

1. 监听系统剪贴板
2. 注册全局快捷键 `Command + Shift + V`

实际使用流程如下：

1. 保持应用在后台运行。
2. 在任意应用中复制一段文本。
3. CommandHub 会检查剪贴板内容，并按行提取可保存的命令。
4. 如果当前前台应用是 Chrome 或 Safari，CommandHub 会尝试读取当前标签页 URL，并为命令记录 `domain / env / sourceApp`。
5. 需要复用命令时，按 `Command + Shift + V` 打开搜索窗口。
6. 搜索窗口会先保留唤起前的前台应用，再解析顶部 context 状态，避免窗口激活后把 CommandHub 自己误判成当前应用。
7. 在搜索框中输入关键字筛选命令。
8. 根据当前上下文，结果会优先展示更匹配的命令。
9. 可通过顶部 `All / Current Env Only` 切换搜索范围，并通过 `Favorites / Category / Workspace` 做二级过滤。
10. 单击结果行时只会选中该命令，不会立即复制。
11. 右侧详情区可查看并编辑 alias、note、favorite 和 workspace。
12. 使用方向键切换结果，按回车将选中的命令复制到剪贴板。
13. 也可以按 `Cmd + Enter` 复制并立即关闭窗口。
14. 回到终端或其他应用粘贴使用。

当前 `env` 识别规则：

- 优先读取 URL query 中的 `env`
- 若 `env` 为常见别名，如 `stg`、`prod`，会归一化为 canonical 值
- 若 `env` 是业务自定义环境名，如 `ECE-H-126E`，会保留原值
- `host`、`xterm_host`、`container_id`、`container_host_name` 不参与环境名识别
- 环境匹配大小写无关，但 UI 展示保留原值

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
- 顶部会显示当前上下文状态；若从 Chrome / Safari 唤起，会优先显示唤起前标签页对应的网页 context
- 支持 `All / Current Env Only` 切换
- 支持 `Favorites / Category / Workspace` 二级过滤
- 默认选中第一条结果
- 结果项第一行优先展示 `alias`，第二行始终展示原始命令
- 结果项可展示 `[category] [env] [domain] [sourceApp]` 标签
- 右侧详情区可查看完整命令、note、workspace、context 和 usage 信息
- 回车：复制当前选中项
- `Cmd + Enter`：复制并关闭窗口
- `Cmd + Shift + F`：收藏 / 取消收藏
- `Cmd + E`：聚焦 alias 输入框
- `Cmd + F`：聚焦搜索框
- 方向键上/下：切换选中项
- 鼠标点击：仅选中对应命令
- `Backspace` 或 `Cmd + Delete`：删除当前命令（需确认）
- `Esc`：关闭窗口

## 设置页面

- 通过菜单栏 `CommandHub > Settings...` 打开
- 当前 Settings 主要用于 workspace 管理：
  - 新建 workspace
  - 重命名 workspace
  - 删除 workspace
  - 查看每个 workspace 绑定的命令数量

## 当前限制

当前版本仍然是一个最小可用实现，已知限制如下：

- 只做“重新复制”，不直接执行命令
- 浏览器上下文目前只支持 `Google Chrome` 和 `Safari`
- 目前只识别 query 参数名 `env`，不自动兼容 `environment` 等别名
- 不支持 Firefox、Arc、终端 host 等更细粒度上下文
- `note` 目前只作为弱匹配和辅助说明，不是强召回字段
- `category` 目前由规则自动推导，不支持手工编辑
- Settings 页面目前只提供 workspace 管理，不是完整偏好设置中心

## 计划文档

- 当前计划入口：[PLAN.md](/Users/zth/MyProjects/CommandHub/PLAN.md)
- 版本计划目录：[docs/plans/README.md](/Users/zth/MyProjects/CommandHub/docs/plans/README.md)
- 当前版本计划：[docs/plans/v1.4.md](/Users/zth/MyProjects/CommandHub/docs/plans/v1.4.md)
- 测试用例文档：[docs/testing/v1.4-test-cases.md](/Users/zth/MyProjects/CommandHub/docs/testing/v1.4-test-cases.md)
- 当前版本发布说明：[docs/releases/v1.4.0.md](/Users/zth/MyProjects/CommandHub/docs/releases/v1.4.0.md)

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
├── Features/Settings/   # Settings 中的 workspace 管理
└── Services/            # 热键与存储服务
```

## 依赖

- [HotKey](https://github.com/soffes/HotKey)

## 后续可扩展方向

- 菜单栏图标和菜单
- 自定义 env 规则配置
- 更多上下文来源，如终端 host、更多浏览器、IDE
- 命令标签与更细粒度的组织方式
- note / alias 的智能生成
- 多设备同步
- 历史清理和导出
