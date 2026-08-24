# AGENTS.md

给新会话 AI / agent 的快速上下文。详细用户文档见根 `README.md`；本文件只记录工程上下文、关键约束和下一步任务。

## 项目一句话

把开源数据库客户端 [dbx](https://github.com/t8y2/dbx) 移植到 HarmonyOS：用 ArkUI Web 组件加载本地 `dbx-web` HTTP 服务，Rust 后端以 NAPI `.so` 内嵌进 HAP。

## 仓库结构

```
dbx-ohos/
├── upstream/
│   └── dbx/            # git submodule → GetZ110/dbx 的 harmonyos-port 分支（上游 t8y2/dbx 的 fork）
├── harmony/
│   └── dbxohos/        # HarmonyOS HAP 工程（DevEco 项目）
├── AGENTS.md           # 本文件
└── README.md
```

## 关键架构

- HAP 启动 `EntryAbility`：
  1. 把 `resources/rawfile/dbx-dist` 复制到沙箱
  2. 优先通过 `NativeBridge.startServer()` 启动 Rust `dbx-web`（NAPI）
  3. 失败时回退 ArkTS `HttpServer`
  4. 等待 `/api/health` 就绪后 `loadContent('pages/Index')`
- `Index.ets` 是全屏 `Web`，加载 `http://127.0.0.1:4224/`
- 原生 MCP：`dbx-web` 在 `/mcp` 挂载 Streamable HTTP MCP（与 Web 同端口 4224）
- 主题持久化：ArkWeb localStorage 在部分 HarmonyOS 设备重启后不可靠；已用原生 Preferences + `javaScriptOnDocumentStart` 注入恢复兜底

## 重要文件

| 路径 | 说明 |
|---|---|
| `upstream/dbx/crates/dbx-ohos/` | Rust NAPI 插件（cdylib `libdbx_ohos.so`） |
| `upstream/dbx/crates/dbx-web/src/lib.rs` | `dbx-web` HTTP 服务入口；含 `/api/health`、MCP、`AppState` 复用 |
| `upstream/dbx/crates/dbx-mcp/src/backend.rs` | `LocalBackend::with_app_state()` 复用 AppState |
| `harmony/dbxohos/entry/src/main/ets/entryability/EntryAbility.ets` | 生命周期、服务启停、防重入、恢复 reload |
| `harmony/dbxohos/entry/src/main/ets/pages/Index.ets` | Web 组件、JSProxy、主题注入脚本、错误过滤 |
| `harmony/dbxohos/entry/src/main/ets/services/ThemePrefs.ets` | 原生 Preferences 持久化 |
| `harmony/dbxohos/entry/src/main/ets/services/WebPrefsBridge.ets` | 暴露给 Web 的 `dbxNativePrefs` JS 桥 |
| `harmony/dbxohos/entry/src/main/ets/services/ServerHealthChecker.ets` | `/api/health` 轮询 |

## 构建命令

### Rust `.so`

```bash
cd upstream/dbx
OHOS_NDK_HOME=/storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_1/native \
  cargo build --release -p dbx-ohos
cp target/release/libdbx_ohos.so \
  ../../harmony/dbxohos/entry/libs/arm64-v8a/libdbx_ohos.so
```

注意：完整 release 构建很慢（LTO + codegen-units=1，约 13–26 分钟）。

### HAP（推荐：devecocli 一键）

- 推荐方式（已在本机验证）：
  ```bash
  export DEVECO_CLI_CLT_PATH=/storage/Users/currentUser/deveco_tools
  export DEVECO_SDK_HOME=/storage/Users/currentUser/deveco_tools/sdk
  cd harmony/dbxohos
  devecocli run --device 127.0.0.1:43817   # 构建+装机+启动
  devecocli run --skip-build --device 127.0.0.1:43817  # 只部署
  ```
  `devecocli` 是全局 npm 包 `@deveco-test/hmos-deveco-code`（bin: `~/.npm-global/bin/devecocli`）。根目录 `dev-run.sh` 已封装上述环境变量，可 `./dev-run.sh [--skip-build]`。
- 裸 hvigor 构建（同样可用，需先做下方环境修复）：
  ```bash
  export DEVECO_SDK_HOME=/storage/Users/currentUser/deveco_tools/sdk
  cd harmony/dbxohos
  node /storage/Users/currentUser/deveco_tools/hvigor/bin/hvigorw.js \
    --mode module -p product=default --no-daemon assembleHap
  # 产物：entry/build/default/outputs/default/entry-default-signed.hap
  ```
- 命令行环境修复（本机已做，勿删）：
  - SDK 工具链缺 `x` 位：`chmod +x` 过 `toolchains/{hdc,restool,ark_disasm,syscap_tool,...}`、`toolchains/lib/{ohos_packing_tool,hap-sign-tool,binary-sign-tool}`、`ets/.../ark/build/bin/{es2abc,panda_guard}`
  - `node_modules/@ohos/hvigor-ohos-plugin` → symlink 到 `deveco_tools/hvigor/hvigor-ohos-plugin`
  - plugin 的 `node_modules/@ohos/hvigor` → symlink 到 `deveco_tools/hvigor/hvigor`；hvigor 自身 `node_modules/@ohos/hvigor` → 自链接（worker 解析需要）
  - `deveco_tools/tool/node` → symlink 到 `deveco_tools/node`（CLT 布局需要）
- 已知小问题：`devecocli check lint` 流程能跑但报告为空（codelinter 与 SDK 26/OHOS 7.0 Beta 兼容问题），当前以 hvigor `CompileArkTS` 编译无错为准。

## 已完成

- Rust NAPI 集成（`startServer` / `stopServer` / MCP）
- 原生 MCP Streamable HTTP（`/mcp`）
- 原生 `/api/health` 就绪探测
- 冷启动防重入，避免双 Web 实例
- 前后台恢复只 reload，不重复 `loadContent`
- 主题/外观偏好原生 Preferences 持久化
- MCP 复用 `AppState`，避免二次打开 SQLite
- 底部导航区避让：`WindowBridge` 用 `getWindowAvoidArea(TYPE_NAVIGATION_INDICATOR)` + `on('avoidAreaChange')` 维护高度，`Index.ets` 注入 `windowSafeAreaScript` 每 500ms 读取 `getBottomNavHeight()` 并给 `<body>` 加 padding-bottom（2in1 上该值为 0，无副作用）
- 仓库已按 submodule 结构托管到 GitHub

## 下一步任务

- P2：PC/平板 UX 优化
  - 触摸适配
  - 原生标题栏 / 侧边栏
  - 按窗口类型（tablet / 2in1）做布局
  - 启动加载页跟随已保存的明暗主题
- P2：查询表格 **Canvas 渲染模式流畅度优化**（上游 `DataGrid.vue` canvas 模式每帧全量重绘导致 ArkWeb 上大数据量滚动丢帧；计划改为行块纹理缓存 + 增量绘制 + DPR 降级。落地前靠「视图选项 → 渲染模式切 DOM」兜底，该提示已写入 v1.1.0 release notes）
- 待研究：系统全局任务栏/Dock 颜色无法由应用侧控制（已试 setColorMode / setWindowSystemBarProperties，最大化后 Dock 仍为系统色，记录待后续处理）
- P3：沙箱数据备份/导出/导入、连接加密确认、云同步验证
- P4：DevEco 签名配置、签名 HAP/APP 发布
- P5：原生 ArkUI 替换连接管理 / SQL 编辑器（长期）
- P6：构建脚本、patch 文档、ohosTest 单元测试
- 可选：MCP 拆分到独立端口

## 关键约束 / 坑

- **不要用 `aws-lc-rs`**：OHOS 目标链接失败；TLS 相关 crate 已切到 `ring`（`rustls`、`russh`、`mysql_async`）。
- **ArkTS 严格模式**：
  - 静态方法里不能直接用 `this`
  - 不能用未类型化对象字面量 / 结构类型
  - 不能任意 `throw`
  - `onConsole` 必须返回 boolean
  - `WebResourceRequest` 用 `getRequestUrl()`，不是 `getUrl()`
- **Web 错误处理**：`onErrorReceive` 里非 `isMainFrame()` 的子资源错误必须忽略，否则弹全屏“加载失败”。
- **不要重复 `loadContent`**：多次调用会产生多个 Web 实例，导致 IndexedDB LOCK、localStorage/主题丢失。
- **主题持久化**：ArkWeb localStorage 跨完全退出可能不落盘；当前方案是 JS 注入把 `dbx-*` 写入原生 Preferences，启动前再恢复进 localStorage。
- **健康检查**：原生 `dbx-web` 必须有 `/api/health`；否则 `ServerHealthChecker` 会空等 10 秒。
- **MCP 启动**：不要用 `LocalBackend::open()` 再开一次 SQLite，应复用已打开的 `AppState`。

## 验证方式

真机/模拟器 hilog 过滤：

```bash
hdc hilog | grep -E "DBX_ABILITY|DBX_NATIVE|DBX_HEALTH|DBX_PAGE|DBX_THEME_PREFS"
```

正常启动应看到：

- `native server started on port 4224`
- `server ready: http://127.0.0.1:4224/api/health`
- `Succeeded in loading the content.` 只出现一次
- `Index about to appear` 只出现一次
