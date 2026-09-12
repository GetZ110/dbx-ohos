# AGENTS.md

给新会话 AI / agent 的快速上下文。详细用户文档见根 `README.md`；本文件只记录工程上下文、关键约束和下一步任务。

## 项目一句话

把开源数据库客户端 [dbx](https://github.com/t8y2/dbx) 移植到 HarmonyOS：用 ArkUI Web 组件加载本地 `dbx-web` HTTP 服务，Rust 后端以 NAPI `.so` 内嵌进 HAP。

## 仓库结构

```
dbx-ohos/                     # 父仓库，只有 main 一个分支，直接在 main 上开发
├── upstream/
│   └── dbx/            # git submodule → GetZ110/dbx 的 harmonyos-port 分支（上游 t8y2/dbx 的 fork）
├── harmony/
│   └── dbxohos/        # HarmonyOS HAP 工程（DevEco 项目）
├── AGENTS.md           # 本文件
└── README.md
```

> 分支约定：父仓库 `main` 为唯一开发分支（原 `feat/harmony-desktop-mode` 桌面模式分支已合并进来并删除）；submodule 侧固定用 `harmonyos-port`。

## 关键架构

- HAP 启动 `EntryAbility`：
  1. 把 `resources/rawfile/dbx-dist` 复制到沙箱——**只在指纹变化时复制**（`RawFileCopier.copyRawDirIfNeeded`，指纹存 Preferences `dbx-dist-fingerprint`），且全程异步
  2. 与复制**并行**通过 `NativeBridge.startServer()` 启动 Rust `dbx-web`（NAPI）
  3. 失败时回退 ArkTS `HttpServer`
  4. 等待 `/api/health` 就绪（短间隔起步的退避轮询）后 `loadContent('pages/Index')`
- `Index.ets` 是全屏 `Web`，加载 `http://127.0.0.1:4224/`
- 原生 HTTP 服务**只绑 `127.0.0.1`**（`DBX_BIND_HOST`，见「关键约束」）
- 原生 MCP：`dbx-web` 在 `/mcp` 挂载 Streamable HTTP MCP（与 Web 同端口 4224）
- 主题持久化：ArkWeb localStorage 在部分 HarmonyOS 设备重启后不可靠；已用原生 Preferences + `javaScriptOnDocumentStart` 注入恢复兜底
- 启动页文案分两段：服务未就绪显示「正在启动 DBX 本地服务…」，`AppStorage dbx_service_ready` 置位后显示「正在加载界面…」

## 重要文件

| 路径 | 说明 |
|---|---|
| `upstream/dbx/crates/dbx-ohos/` | Rust NAPI 插件（cdylib `libdbx_ohos.so`） |
| `upstream/dbx/crates/dbx-web/src/lib.rs` | `dbx-web` HTTP 服务入口；含 `/api/health`、MCP、`AppState` 复用、静态资源缓存头 |
| `upstream/dbx/crates/dbx-mcp/src/backend.rs` | `LocalBackend::with_app_state()` 复用 AppState |
| `harmony/dbxohos/entry/src/main/ets/entryability/EntryAbility.ets` | 生命周期、服务启停、防重入、恢复 reload |
| `harmony/dbxohos/entry/src/main/ets/pages/Index.ets` | Web 组件、JSProxy、主题注入脚本、错误过滤、启动页 |
| `harmony/dbxohos/entry/src/main/ets/services/RawFileCopier.ets` | rawfile → 沙箱复制；指纹判断 + 全异步 I/O |
| `harmony/dbxohos/entry/src/main/ets/services/ThemePrefs.ets` | 原生 Preferences 持久化（含 dist 指纹） |
| `harmony/dbxohos/entry/src/main/ets/services/WebPrefsBridge.ets` | 暴露给 Web 的 `dbxNativePrefs` JS 桥 |
| `harmony/dbxohos/entry/src/main/ets/services/ServerHealthChecker.ets` | `/api/health` 轮询（短间隔起步退避） |
| `harmony/tools/inject_modulepreload.py` | 给构建产物 `index.html` 注入启动闭包 `modulepreload`（每次替换 dist 后必须重跑） |

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
- 同步上游 v0.5.98（95 commits，冲突 1 处 + lib.rs 回填 5 条上游路由）
- 同步上游 v0.6.2（冲突 1 处）
- 同步上游 v0.6.9（382 commits，1123 文件；冲突 2 处 + lib.rs 回填 1 条上游路由 `/app-settings/sql-file-upload-max-bytes`）
- HAP 产物重建流程落地：前端 dist 走 fork CI（GetZ110/dbx Actions 从合并后源码构建，勿用 Release 包——其落后 main 几十个提交）、Rust `.so` 本地 OHOS release 构建，已写入「同步上游」章节
- JRE 解压适配：`extract_jre_tar` 改为逐条目解包并跳过 symlink（沙箱创建符号链接返回 EPERM；JRE 包仅 `legal/` 下有链接）
- 系统任务栏/Dock 与「跟随系统」主题（2026-09 重做，推翻旧结论）：旧的「应用侧不可控」结论**错误**——观察到的白色来自 `applySystemBarColor` 里 `savedTheme === 'dark'` 的粗糙判断（'system' 被当成 light → 强行刷白），而该函数**只在 `windowStatusChange` 进入最大化时调用**，所以表现为「一最大化 dock 就变白/变暗」。
  - 正确做法：始终把**有效外观**显式写入应用 colorMode（`context.setColorMode`），并同步 `setWindowSystemBarProperties`；`'system'` 不再留空（留空会让 dock 回退白色）。
  - 「跟随系统」的**唯一真值来源是 `uiAppearance.getDarkMode()`**（`@kit.ArkUI`，返回 `ALWAYS_DARK=0` / `ALWAYS_LIGHT=1`）。已实测：应用把 colorMode 强制为 light 时，该 API 仍返回系统真实值（system=dark 时返回 0）——即它**不受应用 override 影响**。
  - **绝不要**用 `window.matchMedia('(prefers-color-scheme: dark)')` 或 web 侧渲染结果反推系统状态：ArkWeb 跟随应用 colorMode，会形成「system → 回读上一次显式模式」的自锁（表现为暗色切「跟随系统」后固定暗色）。
  - **绝不要**在应用 override 之后再读 `resourceManager.getConfigurationSync().colorMode`（返回的是 override 值，会污染系统状态缓存）；只在 onCreate 覆盖前读一次作为 fallback。
  - 桥接：`dbxNativeWindow.syncSystemAppearance()`（web 每秒轮询：native 重读系统态并重刷 chrome，返回有效外观）、`getEffectiveAppearance()`、`setAppearanceFromWeb()`（web→native 只同步标题按钮色）。原生态同时写入 AppStorage `dbx_system_dark` 供加载页使用。
  - 系统深色模式开关会走 `EntryAbility.onConfigurationUpdate` → `refreshSystemDark()`，1s 轮询作为兜底；两者都会重刷 colorMode / 标题按钮 / 系统栏。
  - 防坑：`setColorMode()` 会**同步重入** `onConfigurationUpdate`，故 `lastAppliedColorMode` 必须在调用**之前**置位，否则无限递归 → `RangeError: Stack overflow`（运行时按致命 JS 错误杀进程）。
- 启动性能优化（2026-09-12，真机 HUAWEI MateBook Pro / HAD-W32 实测，冷启动 `aa force-stop` + `aa start`）：
  - 基线：进程创建 → 首屏 FCP **3.09s**，完全可交互约 3.3s。分解：原生服务 0.2s 就绪，之后是 Web 侧 2.7s，其中「前端模块图加载」单项 **1.73s**（4.59MB / 243 chunk）。
  - 根因：每次冷启动无条件重写 695 个前端文件 → 每个文件 `Last-Modified` 都变 → `If-Modified-Since` 永不命中 → WebView 每次都重新下载 + 重新编译整个启动闭包。
  - 已修：① 指纹判断跳过重复复制（`dbx-dist-fingerprint`）② `/api/health` 改短间隔起步退避（原固定 300ms，最坏白等 300ms）③ 静态资源 `Cache-Control`（`assets/*` 一年 immutable、其余 no-cache）+ `ETag` + `If-None-Match→304`，MCP/API 的路由与压缩层不受影响 ④ 复制改全异步 + 与原生服务启动并行 ⑤ 启动页文案分段 ⑥ `index.html` 注入 23 条 `modulepreload`（覆盖启动闭包 83% 字节）⑦ `libdbx_ohos.so` 改 `import lazy` ⑧ 启动页隐藏兜底 2s→400ms、40 次→10 次、并新增「`#root` 有子节点即隐藏」判定。
  - 另修：原生服务改绑 `127.0.0.1`（此前 `0.0.0.0` + `disablePassword=true` = 局域网可无认证调用全部 API）；OHOS 上 UI 缩放改走 CSS `zoom`（ArkWeb 无 `setZoom`）。
  - 「真削冷路径」两项的实测结论（2026-09-13，真机 HAD-W32，**结论：都不成立，勿重复尝试**）：
    - **#1 `precompileJavaScript` 预生成 V8 code cache —— 收益远小于成本**。API 可用（23/23 chunk 成功，3906KB），但有四个坑：① 进程内**第一次调用必然 reject(-1)**，第 2 次同参数才返回 0 → 必须重试；② `script` 必须传 **`string`**（`fs.readTextSync`），传 `Uint8Array` 会 -1（同样的文件！）；③ `CacheOptions.responseHeaders` 只认 `E-Tag`/`Last-Modified`，且要与真实响应一致（用 HEAD 读，键名大小写不敏感）；④ **生成耗时 7.2s**（3.9MB），而 `bm clean -c` 后冷启动的 `frontend modules loaded` 只从 **1589ms → 1456ms**（-133ms，-8%）——因为生成的 code cache 与 HTTP 缓存同目录、一起被清掉；而稳态本来就命中 HTTP 缓存自带的 code cache（315ms），没有可复用空间。代码保留在 `CodeCacheWarmer.ets`，默认由 `AppConstants.ENABLE_CODE_CACHE_WARMUP=false` 关闭。
    - **#2 砍启动闭包 —— 列的三项都不可回收**：
      - `en` 476KB **不是浪费**：`i18n/index.ts` 确实静态导入 en，但**每个非英文 locale 的 chunk 都通过 `locales/fallback.ts` 的 `withEnglishFallback()` 静态导入 en 并以其为底合并**（`zh-CN-*.js` 第一条 import 就是 `./en-*.js`），所以 zh-CN 用户照样要加载 en；去掉 i18n 那句静态导入只会把发现时机推后、字节数不变。真要省，前提是「各语言已完整翻译 → 去掉英文字底合并」，那是上游 i18n 设计变更（缺键会显示原始 key），不属于启动补丁。
      - `codemirror` 483KB：被共享 chunk 图拉入 —— `lib/sql/sqlCompletion.ts` 运行时导入 `@codemirror/lang-sql` 的 8 个方言对象、`lib/sql/sqlSyntaxTreeWindow.ts` 导入 `@codemirror/language` 的 `syntaxTree`，而它们又被打进 api 共享 chunk（`api-*.js` 的第一条 import 就是 `codemirror-*.js`）。要去掉必须把这些共享 SQL 模块改成动态导入 = 上游重构。
      - `api` 655KB / `App` 877KB：核心图（737 个 API 函数 + 全部视图/对话框），不可切分。
    - 含义：**Web 侧冷路径的可回收空间已经很小**，再想显著变快只能动上游打包/代码分割策略，或走上面「ArkUI 重构评估」的阶段 1（原生外壳，让第一屏不依赖 ArkWeb）。

## ArkUI 重构评估（2026-09-13，结论：暂不全量重构）

前端实测规模（`wc`/`find`，非测试代码）：

| 维度 | 数量 |
|---|---|
| 源码 | 459 个 `.vue` + 2047 个 `.ts`，**≈48.9 万行**（`.vue` 20.5 万 + `.ts` 28.4 万），另有 16.3 万行测试 |
| 组件 | 444 个 `.vue`，其中 **84 个 `*Dialog*`**，45 个功能目录 |
| 巨石 | `DataGrid.vue` **14309 行**、`ConnectionDialog.vue` 9381、`QueryEditor.vue` 7740、`SidebarTreeRuntimeHost.vue` 6505、`AiAssistant.vue` 5716 |
| 状态层 | 15 个 Pinia store + 71 个 composable |
| API 层 | `api.ts` 1017 + `tauri.ts` 5216 + `http.ts` 4535（同一 **737 函数**接口两套实现） |
| 连接类型 | **80 种**（`types/generated/databaseTypes.ts`） |
| i18n | 26 种语言，`en.ts` 单文件 9768 行 |

**三个必须从零造轮子的成本中心**：① SQL 编辑器（CodeMirror 6 × 14 包，ArkUI 无可用的代码编辑器控件）8–14 人月；② DataGrid 自绘（虚拟滚动/canvas/冻结列/区域选择…）5–9 人月；③ 图表/血缘/ER（echarts + vue-flow + elkjs + leaflet）4–7 人月。合计估算 **44–77 人月（5–8 人年）**，另加 ArkTS 严格模式导致的 30–50% 改写量。

**不建议全量重构的两个理由**：① 上游极活跃（上次同步 382 commits/1123 文件），原生前端会把「同步上游」从 merge 变成永久重写；② 收益（去 ArkWeb 启动 ~0.6s、去 HTTP/沙箱拷贝 ~0.1s、网格不丢帧、原生输入）与 5–8 人年 + 永久分叉不成比例。

**推荐的渐进路线（备案，不在短期开工）**：

- 阶段 0（进行中）：继续压 Web 侧——V8 code cache、砍启动闭包（`en` 静态兜底、`codemirror`、`api`、`App`）。投入产出比最高。
- 阶段 1（1–3 人月，低风险）：**原生外壳**——连接列表/最近连接/设置/启动页与错误页用 ArkUI 渲染，工作区仍是 Web；ArkWeb 在后台预热。顺带消掉启动页主题门控问题。
- 阶段 2（3–6 人月）：**高频简单面板原生化**——侧边栏树/对象浏览器/结构编辑器+DDL/导入导出向导/驱动管理（ArkUI `List/Form/Navigation/Dialog` 可覆盖）。
- 阶段 3（不建议）：DataGrid 自绘 + SQL 编辑器自研，各自都是独立项目，除非有明确产品理由，否则保留 Web 版。

## 下一步任务

- P2：PC/平板 UX 优化
  - 触摸适配
  - 原生标题栏 / 侧边栏
  - 按窗口类型（tablet / 2in1）做布局
  - 启动加载页跟随已保存的明暗主题
- P2：查询表格 **Canvas 渲染模式流畅度优化**（上游 `DataGrid.vue` canvas 模式每帧全量重绘导致 ArkWeb 上大数据量滚动丢帧；计划改为行块纹理缓存 + 增量绘制 + DPR 降级。落地前靠「视图选项 → 渲染模式切 DOM」兜底，该提示已写入 v1.1.0 release notes）
- P3：沙箱数据备份/导出/导入、连接加密确认、云同步验证
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
- **不要再无条件重写沙箱里的 `dbx-dist`**：`ServeDir` 的缓存校验器就是文件 mtime，重写 = mtime 变 = WebView 每次重新下载并重新编译 4.59MB 启动闭包（这是 1.73s 的大头）。只允许在指纹变化时复制（`RawFileCopier.copyRawDirIfNeeded`）；调试时若要强制重拷，改 `AppConstants.DIST_FINGERPRINT_KEY` 的值或清应用数据。
- **原生 HTTP 服务必须绑 `127.0.0.1`**：HAP 传 `disablePassword: true`（`auth_middleware` 直接放行所有 `/api/*`），绑 `0.0.0.0` 等于把整套数据库客户端 API 暴露给局域网。`dbx-web` 用 `DBX_BIND_HOST`（默认仍是 `0.0.0.0`，保持桌面/浏览器部署行为），`dbx-ohos` 里固定设成 `127.0.0.1`——**不要删这行**。
- **静态资源的缓存头**：`mount_public_base_path` 给静态服务单独套了 `Cache-Control`/`ETag`/`If-None-Match→304` 与压缩（`assets/*` 一年 immutable，其余 `no-cache`）。这套层只包静态服务，`/api` 与 `/mcp` 的层不受影响；压缩谓词 `StaticCompressionPredicate` 必须继续排除 `206`/`304`，否则会破坏 `ServeDir` 的 Range 语义。
- **loopback 上不要开静态 gzip**（`static_compression_enabled()` 已按 `DBX_BIND_HOST` 判掉）：设备上实测取回启动闭包的 243 个 chunk，`Accept-Encoding: gzip` 要 **2.16s**、`identity` 只要 **1.21s** —— 压缩 CPU 远比省下的 loopback 传输值钱。只有绑 `0.0.0.0` 的桌面/浏览器部署才开。
- **`import lazy` 用于 `libdbx_ohos.so`**：46MB 的 `.so` 只在首次调用 `NativeBridge` 时才 dlopen（API ≥ 12 直接可用，无需额外配置）。若换回普通 `import`，dlopen 会提前到 Ability 模块求值阶段。
- **发版约定（release 只挂未签名包）**：签名 HAP 含 debug profile（绑定设备 UDID），不可公开发布；每次发 release 前，先把 `AppScope/app.json5` 的 `versionName`/`versionCode` 升到与 release 版本一致（当前基线：1.3.1 ↔ 1003001），再构建并替换 release 资产，保证未签名 hap 的包内版本与 release tag 对齐（2026-08-28 与 2026-09-10 均按此流程替换 release 资产）。

## 同步上游（t8y2/dbx main → harmonyos-port）

```bash
# 1. 拉取
git -C upstream/dbx fetch origin --prune
git -C upstream/dbx fetch upstream main --no-tags --prune

# 2. 合并（保持既有 merge 模式，勿 rebase；信息格式见历史）
git -C upstream/dbx merge --no-ff --no-edit upstream/main \
  -m "merge: sync upstream/main (vX.Y.Z+) into harmonyos-port"

# 3. 解冲突（原则：上游进展 + 保留 OHOS 定制，见下方「同步特有坑」）

# 4. 验证编译（OHOS NDK 环境）
cd upstream/dbx
OHOS_NDK_HOME=/storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_1/native \
  cargo check -p dbx-ohos    # 只编译 lib 目标，很快；不覆盖 bin 目标

# 5. 回填 lib.rs 缺失路由（必须，见坑①）；对新增 .route() 逐个确认 handler 在 routes/ 中存在

# 6. 提交（husky pre-commit 依赖 pnpm，本机无 pnpm → 必须 --no-verify）
git -C upstream/dbx add -A
git -C upstream/dbx commit --no-verify -m "merge: sync upstream/main ..."

# 7. 推送：submodule → 父仓库指针 → 父仓库
git -C upstream/dbx push origin harmonyos-port
cd ../.. && git add upstream/dbx && git commit -m "chore: bump upstream/dbx ..."
git push origin main

# 8. 重建 HAP 嵌入产物（前端 dist + Rust .so），见下方「HAP 产物重建」
```

### HAP 产物重建（同步后必须做，否则 HAP 仍是旧版）

HAP 嵌两个构建产物（都被 git 跟踪）：`rawfile/dbx-dist/`（前端，669 文件/22MB）与 `entry/libs/arm64-v8a/libdbx_ohos.so`（后端，43MB）。两者都必须从**合并后的源码**重建，缺一不可：

**① 前端 dist —— 不能本地构建，必须走 fork CI**

- 本机是 OpenHarmony 环境（`node` 为 OHOS 版，`process.platform = openharmony`）：沙箱禁止 `dlopen` `.node`（`Permission denied`）与 WASM/WASI 加载（`UVWASI_EACCES`），且无 pnpm → 本地 vite/rolldown 构建硬性不可行。
- **不要解包上游 Release 包**（`DBX_<ver>_arm64-browser-static.tar.gz`）：它的 dist 落后于 `upstream/main` HEAD（v0.5.96 Release tag 比 main 落后 52 个提交），直接拷贝会让 HAP 前端与源码脱节。
- 正确做法：在 **fork 仓库（GetZ110/dbx）的 GitHub Actions** 上从合并后的 `harmonyos-port` 构建，取回产物：

```bash
# a) 建临时分支 + 极简 workflow（Node 22 + pnpm/action-setup + pnpm install --frozen-lockfile + pnpm build + upload-artifact dist/），
#    触发方式用 push（workflow_dispatch 要求 workflow 在默认分支，临时分支上不可用）
git -C upstream/dbx checkout -b ci/build-web-dist
#   写 .github/workflows/build-web-dist.yml：on: push: branches: [ci/build-web-dist]
git -C upstream/dbx add .github/workflows/build-web-dist.yml
git -C upstream/dbx commit --no-verify -m "ci: temp workflow to build web dist"
git -C upstream/dbx push origin ci/build-web-dist

# b) 等 run 完成后取 artifact。注意本机拉 artifact 经常中途断流（HTTP/2 unexpected EOF），
#    且 /tmp 已满（curl -o /tmp/... 会报 "client returned ERROR on write"）——务必落到工作区内、带 -C - 断点续传重试：
RUN_ID=$(gh run list --repo GetZ110/dbx --workflow build-web-dist.yml --limit 1 --json databaseId --jq '.[0].databaseId')
AID=$(gh api "repos/GetZ110/dbx/actions/runs/$RUN_ID/artifacts" --jq '.artifacts[0].id')
TOK=$(gh auth token)
# 先取签名跳转 URL（Range 可用，故可续传），再循环 curl -C - 直到字节数与 size_in_bytes 相等
SIGNED=$(curl -sS -o /dev/null -w '%{redirect_url}' -H "Authorization: Bearer $TOK" \
  -H "Accept: application/vnd.github+json" "https://api.github.com/repos/GetZ110/dbx/actions/artifacts/$AID/zip")
for i in $(seq 1 60); do timeout 90 curl -sS -C - -o target/dist.zip "$SIGNED"; \
  [ "$(stat -c%s target/dist.zip)" -ge "$(gh api repos/GetZ110/dbx/actions/artifacts/$AID --jq .size_in_bytes)" ] && break; done
unzip -t target/dist.zip   # 必须校验完整性

# c) 解包替换；替换前顶层文件结构应与旧 dist 一致（assets/ index.html fonts/ icons/ 等）
unzip -q dist.zip -d web-dist
DEST=harmony/dbxohos/entry/src/main/resources/rawfile/dbx-dist
rm -rf $DEST && mkdir -p $DEST && cp -r web-dist/. $DEST/

# c2) 【必须】给新的 index.html 注入启动闭包 modulepreload（幂等，可重复执行）
#     构建产物只 preload 4 个 chunk，而启动闭包有 243 个 / 4.59MB；
#     脚本按静态 import 图算出闭包，注入大于 16KB 的 23 个 chunk（≈83% 字节）。
#     dist 一被整体替换，这步就得重跑，否则第 ⑥ 项优化失效。
python3 harmony/tools/inject_modulepreload.py

# d) 删临时分支回收（本地 + 远程），删除时 workflow 一并消失
git -C upstream/dbx push origin --delete ci/build-web-dist
git -C upstream/dbx branch -D ci/build-web-dist
```

**② Rust `.so` —— 本地 release 构建（约 13–31 分钟）**

```bash
cd upstream/dbx
OHOS_NDK_HOME=/storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_1/native \
  cargo build --release -p dbx-ohos
cp target/release/libdbx_ohos.so ../../harmony/dbxohos/entry/libs/arm64-v8a/libdbx_ohos.so
```

**③ 验证与提交**

- 替换后确认 dist 顶层结构与旧版一致（`index.html` 引用的 `assets/index-*.js` 哈希应变，如 `index-D6HJCmZ4` → 新哈希），变更应全部落在 dbx-dist 与 .so 内
- 父仓库提交：`git commit -m "build(hap): rebuild embedded artifacts from synced v0.5.98 source"` 并推送
- 注意：dist 整体替换 = 大量「删旧文件 + 加新文件」的 diff（hash 命名），这是正常的

### 同步特有坑

- **① 双路由表（每次同步必查）**：上游只在 `crates/dbx-web/src/main.rs`（桌面入口）加新路由；OHOS 实际入口是 `crates/dbx-web/src/lib.rs`（NAPI 调 `dbx_web::run_server_with_shutdown`）。合并后必须对比并回填，否则 OHOS 端缺新 API（v0.5.96 漏了 25 条）：
  ```bash
  comm -23 <(grep -oE '"/[a-z0-9/_-]+"' crates/dbx-web/src/main.rs | sort -u) \
           <(grep -oE '"/[a-z0-9/_-]+"' crates/dbx-web/src/lib.rs | sort -u)
  ```
  反向对比（lib.rs 独有）应只剩 harmony 特有路由：`/mq/*`、`/health`、`/mcp`、`/api/query/extract-data-grid-selection`——这些**不要删**。
- **② `dbx-core/Cargo.toml` 大概率冲突**：保留 OHOS 定制（`rusqlite` 带 `bundled`、`mysql_async` 用 `default-rustls-ring`、`rustls`/`russh` 用 `ring`）；上游新增依赖要保留（如 `libsqlite3-hotbundle` 及其 `sqlite-multiple-ciphers` feature），它们是桌面端 `src-tauri` 用的，删了会让桌面 feature 悬空。
- **③ 版本号**：上游 `src-tauri` / `dbx-web` / `dbx-mcp` 版本号随之上移（如 0.5.93→0.5.96），确认 `Cargo.lock` 与 `Cargo.toml` 一致（`cargo metadata` 可快速验证解析）。
- **④ 上游新增桌面功能必须同时判 `isTauriRuntime()`（每次同步必查）**：鸿蒙运行时是「类桌面但非 Tauri」——注入 `__HARMONY_DESKTOP__` 使 `isDesktopRuntime()` 为 true，但**刻意不注入** `__TAURI_INTERNALS__`（否则 `api.ts` 会切到 Tauri 后端）。因此上游任何只判 `isDesktopRuntime()` 就调 `@tauri-apps/*` 的新代码，在 OHOS 上都会抛：
  - `getCurrentWebviewWindow()` / `getCurrentWindow()` → `Cannot read properties of undefined (reading 'metadata')`
  - `listen()` / `emit()` → `Cannot read properties of undefined (reading 'transformCallback')`

  这类异常若发生在 `App.vue` 启动的 try/catch 里，会被错误地报成 **「加载已保存连接失败：…」**（与连接无关，极易误判）。排查方式：`hdc hilog | grep -E "unhandled rejection|Cannot read properties of undefined"`，正常启动应为 0 条。

  已加守卫的位置（合并后若被上游覆盖需重加）：`App.vue` 的 `initializeUpdatePreparation()` / `setupDetachedWindowEvents()`、`setupTauriListeners()`（`composables/useTauriEvents.ts`）、`uiScaleApplyQueue` 的 apply 回调（非 Tauri 时走 `applyUiScaleWithCss()`，ArkWeb 没有 `setZoom`）。**每次同步后建议全局扫一遍**：

  ```bash
  # 找出「只判 isDesktop / isDesktopRuntime 却触碰 @tauri-apps」的新代码
  grep -rn "isDesktop" apps/desktop/src --include=*.vue --include=*.ts | grep -v isTauriRuntime
  ```

## 验证方式

真机/模拟器 hilog 过滤：

```bash
hdc hilog | grep -E "DBX_ABILITY|DBX_NATIVE|DBX_HEALTH|DBX_PAGE|DBX_THEME_PREFS"
```

正常启动应看到：

- `native server started on port 4224`
- `frontend unchanged (fp=…), skipped copy in Xms`（首次安装/换版本后应变为 `frontend copied from rawfile in Xms`）
- `Local service ready in Xms`（正常应 < 200ms）
- `server ready: http://127.0.0.1:4224/api/health (attempt N)`（N 应为 1–3）
- `Succeeded in loading the content.` 只出现一次
- `Index about to appear` 只出现一次
- Web 侧 `[STARTUP]` 埋点：`frontend bootstrap begin` → `frontend modules loaded` → `vue mounted`
- 不应再出现 `[DBX] Failed to apply UI scale` 与 `Cannot read properties of undefined (reading 'transformCallback')`

### 冷启动耗时测量（对比优化效果用）

```bash
hdc shell aa force-stop com.dbx.ohos; sleep 1
hdc shell hilog -r
(hdc hilog > .tmp/perf.log &) ; sleep 2
hdc shell aa start -a EntryAbility -b com.dbx.ohos
# 等 ~25s，然后按时间戳对齐这几条：
#   进程创建      APPSPAWN 里该 pid 的第一行
#   首屏          chromium: [WebLoadTracker] PageFirstContentfulPaintInPage … FCP:<ms>
#   可交互        [STARTUP] savedSqlStore.initFromStorage: Xms
grep -E "DBX_ABILITY|DBX_COPY|DBX_HEALTH|ARKWEB-CONSOLE" .tmp/perf.log
```

2026-09-12 优化前基线（HAD-W32）：进程创建 → FCP 3.09s，`frontend modules loaded` 单项 1.73s。
