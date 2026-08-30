# dbx-ohos

DBX 数据库客户端在 HarmonyOS 上的移植工程。

- 上游项目：[https://github.com/t8y2/dbx](https://github.com/t8y2/dbx)
- 本仓库 fork：`git@github.com:GetZ110/dbx.git`（分支 `harmonyos-port`）

## 仓库结构

```
dbx-ohos/
├── upstream/
│   └── dbx/            # 上游 dbx 源码（submodule，指向 harmonyos-port 分支）
├── harmony/
│   └── dbxohos/        # HarmonyOS HAP 工程（ArkTS Web + Rust NAPI .so）
└── README.md
```

## 快速开始

```bash
# 克隆仓库（包含 submodule）
git clone --recurse-submodules git@github.com:GetZ110/dbx-ohos.git
cd dbx-ohos

# 如果已经克隆但没拉 submodule
git submodule update --init --recursive
```

### 构建原生 `.so`

```bash
cd upstream/dbx
OHOS_NDK_HOME=/path/to/ohos-sdk/native cargo build --release -p dbx-ohos
cp target/release/libdbx_ohos.so \
  ../../harmony/dbxohos/entry/libs/arm64-v8a/libdbx_ohos.so
```

### 构建 HAP

用 DevEco Studio 打开 `harmony/dbxohos`，构建运行即可。

## 已完成

- [x] 上游 `dbx` 源码以 submodule 方式纳入，移植分支 `harmonyos-port`
- [x] Rust NAPI 集成：`crates/dbx-ohos` 导出 `startServer` / `stopServer` / MCP 相关方法
- [x] 原生 MCP Server：`dbx-web` 通过 Streamable HTTP 提供 `/mcp`
- [x] 原生 `/api/health` 就绪路由，启动时等待服务就绪后再加载 Web
- [x] 冷启动防重入：避免 `onWindowStageCreate` / `onForeground` 竞态产生双 Web 实例
- [x] 前后台切换：后台停止本地服务，前台恢复并只触发 Web reload，不重建页面
- [x] 主题/外观偏好持久化：原生 Preferences + `javaScriptOnDocumentStart` 注入恢复
- [x] 启动优化：MCP 复用 `AppState`，避免二次打开 SQLite 导致冷启动变慢
- [x] 一键启动脚本 `start-dbx.sh`（宿主机开发用）
- [x] HarmonyOS 构建/移植文档
- [x] 2in1 沉浸式工具栏：隐藏系统标题栏，Web 工具栏作为标题栏，原生窗口按钮保留
- [x] 窗口按钮主题跟随：通过 `setDecorButtonStyle()` 随应用/系统亮暗切换颜色
- [x] 窗口按钮动态避让：通过 `getTitleButtonRect()` 动态计算工具栏右侧预留宽度
- [x] 窗口顶部拖拽/双击最大化：`setWindowTitleMoveEnabled` + JS `startMoving()`
- [x] 加载页/启动主题：读取软件设置主题，`system` 模式跟随系统真实亮暗
- [x] Web 组件 `darkMode(Auto)`：`prefers-color-scheme` 跟随系统
- [x] 加载页防白闪：首次内容绘制（`onFirstContentfulPaint`）后再隐藏加载层

## 待办

- [ ] P2：PC/平板 UX 优化（触摸适配、原生侧边栏、按窗口类型布局）
- [ ] P2：查询表格 **Canvas 渲染模式流畅度优化**（当前 Canvas 自绘网格为每帧全量重绘：可见格 × `fillText` + `measureText`，且背板 = `dpr² × uiScale`，大数据量滚动在 ArkWeb 上一帧画不完导致丢帧。计划改增量绘制：行块纹理离屏缓存 + 平移贴图 + DPR 降级；优化落地前，UI 已支持「视图选项 → 渲染模式切 DOM」作为流畅兜底）
- [ ] 待研究：系统全局任务栏/Dock 颜色随应用主题（当前应用侧无法控制，最大化后 Dock 仍为系统色）
- [ ] P3：沙箱数据备份/导出/导入、连接加密确认、云同步验证
- [ ] P4：DevEco 签名配置、签名 HAP/APP 发布
- [ ] P5：原生 ArkUI 替换连接管理 / SQL 编辑器（长期）
- [ ] P6：构建脚本、patch 文档、ohosTest 单元测试
- [ ] 可选：MCP 拆分到独立端口（当前与 Web 共用 `4224/mcp`）

## 当前分支方案（PC / 2in1）

当前 `feat/harmony-desktop-mode` 分支采用“沉浸式 + Web 工具栏作为标题栏”的方案：

- `EntryAbility` 隐藏系统标题栏，进入全屏沉浸布局；
- 保留系统原生窗口按钮（最小化 / 最大化 / 关闭），并让按钮颜色随应用/系统主题切换；
- Web 端注入脚本把窗口动作桥接到原生 `WindowBridge`：
  - 最小化 / 最大化 / 关闭
  - 工具栏空白区域拖拽窗口
  - 双击最大化 / 还原
- 工具栏右侧通过 `getTitleButtonRect()` 动态预留系统按钮区域，避免与 Web 工具按钮重叠；
- 主题链路：Web `localStorage` → `WebPrefsBridge.savePref` → `WindowBridge.setThemeMode` → 原生 `setDecorButtonStyle` / `AppStorage`；
- 加载页读取软件设置主题；`system` 模式时读取系统真实亮暗；Web 使用 `darkMode(Auto)` 让 `prefers-color-scheme` 跟随系统；
- 加载页在 `onFirstContentfulPaint` 后再隐藏，避免 ArkWeb 白色首帧闪烁。

> 与 `main` 分支相比，本分支主要差异集中在 2in1 窗口化适配、原生窗口按钮主题同步、加载页主题与防白闪逻辑。

## 移植说明

- 上游 fork：`git@github.com:GetZ110/dbx.git`，分支 `harmonyos-port`
- Rust 侧新增 `crates/dbx-ohos`（NAPI 导出 `startServer` / `stopServer` / MCP）
- `dbx-web` 新增 `/api/health` 就绪路由，并复用 `AppState` 避免二次打开 SQLite
- 鸿蒙壳使用 ArkWeb 加载本地 `dbx-web` 服务；主题/外观偏好通过原生 Preferences 持久化

## License

本项目使用 **Apache-2.0** 许可证。
