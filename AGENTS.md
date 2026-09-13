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
├── harmony/tools/      # 构建后处理与验证脚本（inject_modulepreload.py、startup_smoke.sh）
├── AGENTS.md           # 本文件
└── README.md
```

> 分支约定：父仓库 `main` 为唯一开发分支（原 `feat/harmony-desktop-mode` 已合并删除）；submodule 侧固定用 `harmonyos-port`。**两边都已推到 origin**，改动请保持同步推送。

## 当前状态（2026-09-13）

- **版本**：`AppScope/app.json5` = `versionName 1.3.2 / versionCode 1003002`（2026-09-13 升版，发布准备已完成，**尚未发到 GitHub release**，见「下一步任务 P0」）。上游仍是 dbx v0.6.9。
- **启动指标**（真机 HUAWEI MateBook Pro / HAD-W32，`force-stop` + `aa start`）：

  | 场景 | `frontend modules loaded` | 页内 FCP | 进程创建→FCP |
  |---|---|---|---|
  | 稳态（WebView 缓存命中） | **283–338ms** | ~1.04s | **1.65s** |
  | 冷缓存（`bm clean -c` / 新装或更新后首次） | **1456–1589ms** | ~2.7s | **3.8s** |

  优化前基线：稳态 `frontend modules loaded` 1.73s、FCP 3.09s。已完成的 8 项优化与根因见附录 A/C。
- **启动冒烟已脚本化**：`harmony/tools/startup_smoke.sh`（2026-09-13 真机三连通过：暖 293ms/991ms → 冷 1573ms/2656ms → 回温 296ms/1006ms；见「验证方式」）。
- **结论**：Web 侧冷路径的可回收空间基本见底（附录 C 有两项"看起来能省但实测不成立"的记录）。下一步按「下一步任务」的优先级走。

## 关键架构（启动链路）

`EntryAbility`：

1. 把 `resources/rawfile/dbx-dist` 复制到沙箱——**只在指纹变化时复制**（`RawFileCopier.copyRawDirIfNeeded`，指纹存 Preferences `dbx-dist-fingerprint`），全程异步
2. 与复制**并行**通过 `NativeBridge.startServer()` 启动 Rust `dbx-web`（NAPI，`import lazy` 加载 `.so`）
3. 失败时回退 ArkTS `HttpServer`
4. 短间隔起步退避轮询 `/api/health` 就绪后 `loadContent('pages/Index')`

`Index.ets` 是全屏 `Web`，加载 `http://127.0.0.1:4224/`；启动页文案分两段（`AppStorage dbx_service_ready` 未就绪 = 「正在启动 DBX 本地服务…」，就绪 = 「正在加载界面…」），并在 `#root` 有子节点时隐藏（Vue mount 即隐藏，早于 FCP）。

其余：原生 MCP 挂在同端口 `/mcp`；主题/外观走原生 Preferences + `javaScriptOnDocumentStart` 注入兜底。

## 重要文件

| 路径 | 说明 |
|---|---|
| `upstream/dbx/crates/dbx-ohos/` | Rust NAPI 插件（cdylib `libdbx_ohos.so`，~46MB） |
| `upstream/dbx/crates/dbx-web/src/lib.rs` | `dbx-web` HTTP 服务入口；`/api/health`、MCP、`AppState` 复用、静态资源缓存头、`DBX_BIND_HOST` |
| `upstream/dbx/crates/dbx-mcp/src/backend.rs` | `LocalBackend::with_app_state()` 复用 AppState |
| `harmony/dbxohos/entry/src/main/ets/entryability/EntryAbility.ets` | 生命周期、服务启停、防重入、恢复 reload |
| `harmony/dbxohos/entry/src/main/ets/pages/Index.ets` | Web 组件、JSProxy、注入脚本、启动页、code cache 预热挂点（默认关） |
| `harmony/dbxohos/entry/src/main/ets/services/RawFileCopier.ets` | rawfile → 沙箱复制；指纹判断 + 全异步 I/O |
| `harmony/dbxohos/entry/src/main/ets/services/ServerHealthChecker.ets` | `/api/health` 轮询（短间隔起步退避） |
| `harmony/dbxohos/entry/src/main/ets/services/CodeCacheWarmer.ets` | `precompileJavaScript` 参考实现，**默认关闭**（见附录 C） |
| `harmony/dbxohos/entry/src/main/ets/services/ThemePrefs.ets` | 原生 Preferences（主题 + dist 指纹） |
| `harmony/dbxohos/entry/src/main/ets/services/WindowBridge.ets` | 窗口控制 + 系统外观桥（`dbxNativeWindow`）：minimize/maximize/close/drag/外观同步 |
| `harmony/dbxohos/entry/src/main/ets/services/WebPrefsBridge.ets` | 暴露给 Web 的 `dbxNativePrefs` JS 桥 |
| `harmony/tools/inject_modulepreload.py` | 给构建产物 `index.html` 注入启动闭包 `modulepreload`（**替换 dist 后必须重跑**） |
| `harmony/tools/startup_smoke.sh` | 启动冒烟：`force-stop → hilog -r → aa start → 抓 25s → 12 条断言`。`--mode warm\|cold\|auto`、`--log`（离线重跑断言，不需设备）、`--serial`；退出码 0/1/2 |

## 构建命令

### Rust `.so`

```bash
cd upstream/dbx
OHOS_NDK_HOME=/storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_1/native \
  cargo build --release -p dbx-ohos
cp target/release/libdbx_ohos.so \
  ../../harmony/dbxohos/entry/libs/arm64-v8a/libdbx_ohos.so
```

注意：完整 release 构建很慢（LTO + codegen-units=1，约 **13–31 分钟**）。只需类型检查时用 `cargo check -p dbx-ohos`（约 1 分钟）。

### HAP（推荐：devecocli 一键）

```bash
export DEVECO_CLI_CLT_PATH=/storage/Users/currentUser/deveco_tools
export DEVECO_SDK_HOME=/storage/Users/currentUser/deveco_tools/sdk
cd harmony/dbxohos
devecocli run --device 127.0.0.1:43817            # 构建+装机+启动
devecocli run --skip-build --device 127.0.0.1:43817
```

`devecocli` 是全局 npm 包 `@deveco-test/hmos-deveco-code`（bin: `/storage/Users/currentUser/.npm-global/bin/devecocli`，**不在默认 PATH**）。根目录 `dev-run.sh` 已封装环境变量与 PATH，直接 `./dev-run.sh [--skip-build]`。设备掉线时先 `hdc list targets` 确认本机连接情况；确实没有设备再 `hdc tconn 127.0.0.1:43817`（见「验证方式/测试设备连接顺序」）。

裸 hvigor 构建（只需验 ArkTS 编译时最快，约 10s）：

```bash
export DEVECO_SDK_HOME=/storage/Users/currentUser/deveco_tools/sdk
cd harmony/dbxohos
node /storage/Users/currentUser/deveco_tools/hvigor/bin/hvigorw.js \
  --mode module -p product=default --no-daemon assembleHap
# 产物：entry/build/default/outputs/default/entry-default-{signed,unsigned}.hap
```

### 命令行环境修复（本机已做，勿删）

- SDK 工具链缺 `x` 位：`chmod +x` 过 `toolchains/{hdc,restool,ark_disasm,syscap_tool,...}`、`toolchains/lib/{ohos_packing_tool,hap-sign-tool,binary-sign-tool}`、`ets/.../ark/build/bin/{es2abc,panda_guard}`
- `node_modules/@ohos/hvigor-ohos-plugin` → symlink 到 `deveco_tools/hvigor/hvigor-ohos-plugin`
- plugin 的 `node_modules/@ohos/hvigor` → symlink 到 `deveco_tools/hvigor/hvigor`；hvigor 自身 `node_modules/@ohos/hvigor` → 自链接（worker 解析需要）
- `deveco_tools/tool/node` → symlink 到 `deveco_tools/node`（CLT 布局需要）
- 已知小问题：`devecocli check lint` 能跑但报告为空（codelinter 与 SDK 26/OHOS 7.0 Beta 兼容问题），当前以 hvigor `CompileArkTS` 无错为准。

## 下一步任务（按优先级，2026-09-13 排定）

### P0 收口：验最后一处 + 发 1.3.2（1–2 天）

1. ✅ **UI 缩放已修复并经人工确认通过（2026-09-13）**：问题链与修法见「关键约束/UI 缩放」（初版 CSS `zoom` 整页右溢 → 误用实为视觉缩放的 `zoom()` → 最终 CSS `zoom` + 视口单位补偿 + 工具栏反向 zoom 固定尺寸 + 壳 min-size 归零）。纯 native 侧注入，不需要重建 dist。自动化不变量：0.75–1.9 全档 `shell = 视口`、`scroll == client`、`toolbar = 视口宽×40` 恒定、`vvScale = 1`；启动冒烟 12/12。
1b. ⚠️ **缩放值是持久化的，但启动时落地两次**（2026-09-13 实测：清空日志后冷启、无任何按键，页面依次打 `DBX-ZOOM reset:1` → `applied:1.3`）——settings store 默认值先应用，随后异步水合出持久化值，因此启动瞬间有一帧未缩放的闪烁（旧结论"缩放不跨重启保留"是错的，别照它改）。想消掉闪烁需要把 uiScale 也镜像进原生 Preferences 并在 `documentStart` 就应用（theme 已有同款机制），属 P2 打磨，不影响 1.3.2。
2. 🔶 **1.3.2 发布准备已完成，待发布（2026-09-13）**：`AppScope/app.json5` 已升 `1.3.2 / 1003002` → 重新打包（dist 与 `.so` 都是最新的，**没有**重跑 fork CI / Rust release）→ 未签名包内版本已核验为 1003002 → 归档 `release/DBX_HarmonyOS_v1.3.2_dbx0.6.9_unsigned.hap`（68,638,143 字节，SHA-256 `79bd458c…47e90`）→ 写了 `release/RELEASE_NOTES_v1.3.2.md`（启动 3.09s→1.65s、局域网暴露修复、UI 缩放修复含弹层锚定，并注明"缩放值会记住但启动有一帧闪烁"）。该 RC 已装机（`bm dump` 确认 versionCode 1003002）并跑启动冒烟 12/12。
   - **注意（2026-09-13 两次刷新）**：归档后又因缩放相关的两个 bug 各重新打包一次，均**覆盖同名资产**——① 下拉弹层漂移/跑到窗口外；② 上一条的修复把弹层内容也抵消成"不跟随缩放、始终固定大小"（用户反馈），改为 wrapper 抵消定位 + 子元素恢复缩放。字节数与 SHA 因此变过两次（68,636,268/`759f54ab…` → 68,637,989/`72aeedc3…` → 现值为准）。发布时以这里与 notes 里的 SHA 为准。
   - **待办＝发布动作本身**：在 GitHub 新建 release（tag 建议 `v1.3.2-dbx0.6.9`），**只挂未签名包**，附 notes 全文；不要覆盖 v1.3.1 资产。发布前建议按发版约定的"全新安装 = 冷缓存路径"再走一遍安装验证。
   - `release/` 在 `.gitignore` 里：包与 notes 不入 git，只作本地归档 + 后续上传 release 用。
3. ✅ **启动冒烟已脚本化（2026-09-13 完成）**：`harmony/tools/startup_smoke.sh`——`force-stop → hilog -r → aa start → 抓 25s 日志 → 12 条断言`（断言清单见「验证方式」）。用法：`--mode warm|cold|auto`、`--log <file>`（离线对历史日志重跑断言，不需要设备）、`--serial`；退出码 0/1/2。
   - 理由：这一轮改的东西大多**错了会静默退化**——指纹判断错 → 用户一直用旧前端；缓存头丢 → 冷启动退回 3.8s；启动页隐藏逻辑错 → 闪白；gzip 门控失效 → 白烧 1s CPU。没有自动化只能靠人记。
   - 验证记录：真机三连（暖 293ms/991ms → `bm clean -c` 冷 1573ms/2656ms → 回温 296ms/1006ms）全部 12/12 PASS；离线负向测试确认冷日志在 `--mode warm` 下正确判 FAIL，注入 `Cannot read properties of undefined` 后正确判 FAIL。

### P1 二选一（按真实痛点）

- **A. DataGrid canvas 渲染卡顿**（先 0.5 天量化，再 1–3 周）：上游 `DataGrid.vue`（14309 行）canvas 模式每帧全量重绘，大数据量滚动丢帧。建议先接 `test.sqlite`/`local-mysql` 跑 5000+ 行滚动，抓帧率/丢帧率，把"卡"变成数字再决定投入。落地前靠「视图选项 → 渲染模式切 DOM」兜底（v1.1.0 release notes 已写）。
  - 倾向先做这个：启动已到 2s 量级、边际收益递减，而滚动卡顿是**每天都在用**的体验。
- **B. 阶段 1 原生外壳**（1–3 人月）：连接列表/最近连接/设置/启动页与错误页用 ArkUI 渲染，工作区仍是 Web；ArkWeb 后台预热。顺带消掉启动页主题门控那套复杂度。适合"仍嫌点开要等"的诉求。

### P2 长线 / 需上游配合

- **上游代码分割**：把编辑器/图表/语言包真正拆出首屏（上限 ~900KB ≈ 启动闭包 20%），要改 vite 配置 + 拆 `lib/sql/*` 共享模块，走 fork CI 验证。
- **沙箱数据备份/导出/导入、连接加密确认、云同步验证**。
- **平板/触控适配**（仅在确定做平板形态时启动：触摸适配、按窗口类型布局）。

### 已关闭 / 勿重复尝试（详见附录 C）

- ❌ `precompileJavaScript` 预生成 V8 code cache（成本 7.2s vs 收益 133ms）
- ❌ 砍启动闭包（`en`/`codemirror`/`api`/`App` 四项均不可回收）
- ❌ 全量 ArkUI 重构（44–77 人月 + 永久分叉，见附录 B）

## 关键约束 / 坑

### ArkTS（严格模式）

- 静态方法里不能直接用 `this`
- 不能用未类型化对象字面量 / 结构类型（**带类型的对象字面量可以**，如 `const o: webview.CacheOptions = { responseHeaders: [] }`）
- 不能任意 `throw`
- `onConsole` 必须返回 boolean
- `WebResourceRequest` 用 `getRequestUrl()`，不是 `getUrl()`
- `fs` 没有 `readFileSync`：读文本用 `fs.readTextSync`，读字节用 `openSync` + `statSync().size` + `new ArrayBuffer(n)` + `readSync` + `closeSync`
- `@ohos.net.http` 的 `response.header` 是 `Object`，需 `as Record<string, string>` 且**键名大小写不敏感**（用 `Object.keys` 逐个 `toLowerCase()` 比对）

### ArkWeb / 启动链路

- **`onErrorReceive` 里非 `isMainFrame()` 的子资源错误必须忽略**，否则弹全屏"加载失败"。
- **不要重复 `loadContent`**：会产生多个 Web 实例 → IndexedDB LOCK、localStorage/主题丢失。前后台恢复只 `loadUrl` reload。
- **不要再无条件重写沙箱里的 `dbx-dist`**：`ServeDir` 的缓存校验器就是文件 mtime，重写 = mtime 变 = WebView 重新下载并重新编译 4.59MB 启动闭包（1.73s 的大头）。只允许在指纹变化时复制；调试要强制重拷就改 `AppConstants.DIST_FINGERPRINT_KEY` 的值或清应用数据。
- **主题持久化**：ArkWeb localStorage 跨完全退出可能不落盘；方案是 JS 注入把 `dbx-*` 写进原生 Preferences，启动前再恢复进 localStorage。
- **主题与系统外观（2026-09 重做，推翻旧结论，以下每条都是踩过的坑）**：
  - 「跟随系统」的**唯一真值来源是 `uiAppearance.getDarkMode()`**（`@kit.ArkUI`，`ALWAYS_DARK=0`/`ALWAYS_LIGHT=1`）。实测：应用强制 colorMode 为 light 时该 API 仍返回系统真实值，**不受 override 影响**。
  - **绝不要**用 `window.matchMedia('(prefers-color-scheme: dark)')` 或 web 侧渲染结果反推系统状态：ArkWeb 跟随应用 colorMode，会形成「system → 回读上一次显式模式」的自锁。
  - **绝不要**在应用 override 之后再读 `resourceManager.getConfigurationSync().colorMode`（返回 override 值，会污染系统状态缓存）；只在 onCreate 覆盖前读一次作 fallback。
  - 始终把**有效外观**显式写进应用 colorMode（`context.setColorMode`）并同步 `setWindowSystemBarProperties`；`'system'` 不能留空（留空 dock 回退白色）。旧结论「应用侧不可控」是错的——白色来自 `applySystemBarColor` 里 `savedTheme === 'dark'` 的粗糙判断，且该函数只在最大化时调用，所以表现为"一最大化就变白"。
  - `setColorMode()` 会**同步重入** `onConfigurationUpdate`，故 `lastAppliedColorMode` 必须在调用**之前**置位，否则无限递归 → `RangeError: Stack overflow`（按致命 JS 错误杀进程）。
  - 桥接：`dbxNativeWindow.syncSystemAppearance()`（web 每秒轮询，native 重读系统态并重刷 chrome，返回有效外观）、`getEffectiveAppearance()`、`setAppearanceFromWeb()`（web→native 只同步标题按钮色）；native 同时写 AppStorage `dbx_system_dark` 供启动页用。
- **`import lazy` 用于 `libdbx_ohos.so`**：46MB 的 `.so` 只在首次调用 `NativeBridge` 时 dlopen（API ≥ 12 直接可用）。`NativeBridge.isAvailable()` 内部 try/catch，加载失败降级 ArkTS 服务而不是中断启动。
- **启动页隐藏**：`#root` 有子节点即隐藏（= Vue mount，早于 FCP）；兜底 `onPageEnd+400ms`，主题探测最多 10 次、硬上限 60 次。不要把隐藏时机改到"等 FCP"，那会更晚。

### UI 缩放（2026-09-13 两次修正，别再走弯路）

**结论：2-in-1 上没有可用的"浏览器式页面缩放"，只能用 CSS `zoom` + 视口单位补偿。**

- ❌ **`WebviewController.zoom(factor)` 是视觉（手势）缩放，不是页面缩放**。真机实测（窗口 1101×734 CSS px）：`zoom(1.2)` 后 `window.innerWidth` 不变、`visualViewport.scale` 从 1 变到 1.1→1.32；表现为整页放大+平移（要看边缘得滑动），缩到 <1 会被"页面对齐宽度"卡住（等于没效果），放大后再复位还留着平移偏移（看起来"必须重启"）。而且必须 `zoomAccess(true)`。**不要再用它实现 UI 缩放。**
- ❌ **`metaViewport(true)` + `initialScale(percent)` 在 2-in-1 上无效**：SDK 文档明确 "If the device is 2-in-1, the viewport property is not supported"，viewport meta 根本不解析。
- ✅ **最终方案：CSS `zoom` on `<html>`（web 侧原有实现，能真正重排）+ 注入补偿样式**。CSS zoom 的硬伤是视口单位不随缩放变化，`App.vue` 的壳是 `fixed inset-0 h-screen w-screen overflow-hidden`。`Index.ets` 的 `uiScaleBridgeScript`（`javaScriptOnDocumentStart` 注入）在 `dbx:ui-scale-applied` 时把这些折算回窗口：
  - `:root --dbx-viewport-height: calc(100vh / z)`（对话框的 max-height 用的就是它）
  - `.h-screen / .w-screen / .min-h-screen / .max-h-screen` → `calc(100vh|100vw / z) !important`
  - **`.h-screen.w-screen` 的 `min-width/min-height` 归零**：内层壳还带 Tailwind `min-w-[760px] min-h-[600px]`，补偿后壳宽 `100vw/z` 一旦小于它，最小值反而把壳撑回 `760×z` 而溢出（实测 z=1.5 → 1140px、z=1.6 → 1216px，视口只有 1101px）。缩放期间必须放开最小值，让布局真正重排进窗口。
  - **`.app-toolbar` 反向 zoom `1/z`**：工具栏在 OHOS 上就是标题栏，紧邻的系统窗口按钮是固定尺寸，所以工具栏**不应该**跟着设置缩放（否则 125% 时明显不协调，且 `getTitleButtonReserveWidth()` 那段 `padding-right` 会被放大 z 倍——z=1.5 留白过大、z=0.75 留白只剩 0.75 倍，设置按钮会压到最大化按钮上）。反向 zoom 让净缩放 = 1：字号清晰、尺寸恒定、预留宽度也恒定。内容区照常缩放。
  - **`[data-reka-popper-content-wrapper]` 反向 zoom `1/z` + 其子元素再 zoom `z`**：这是 reka-ui（radix-vue 系）所有浮层（select / dropdown-menu / popover / tooltip / 对话框）的定位容器。它用 floating-ui 的坐标做 `position:fixed + transform`，而那些坐标来自 `getBoundingClientRect()`——**已经是缩放后的视觉像素**；容器自己又处在 zoom 过的坐标系里，于是坐标被二次放大，弹层偏移 `(z-1)×自身位置`，越靠右下越偏，130% 时设置页的「界面缩放」下拉框直接跑到窗口外（2026-09-13 用户报的 bug）。
    **两条规则必须成对**：只抵消 wrapper 会让弹层内容也停在 100% 尺寸（用户立刻反馈"下拉菜单不跟随缩放、始终固定大小"）；只放大子元素而不抵消 wrapper 则回到漂移。正确组合是"定位用视觉像素、内容照常缩放"：`html [data-reka-popper-content-wrapper]{zoom:1/z}` 管坐标，`html [data-reka-popper-content-wrapper]>*{zoom:z}` 管尺寸，净内容缩放 = 1（相对页面坐标系），最终绘制仍是 z 倍。浮层里的 `--reka-popper-anchor-*` 等变量在 CSS 里无人消费，所以不需要额外折算。
  - `[data-slot=dialog-content|dialog-positioner]` 的 max-width / max-height
  回到 100% 时**整张注入样式表被删除**，完全交还给应用自己的 CSS（不残留 `--dbx-viewport-height`、min-size、toolbar zoom、popper wrapper zoom 覆盖）。
- **不变量**（页面会打 `DBX-ZOOM` 日志；改这块务必复测）：任意档位（实测 0.75–1.9）下 `.fixed.inset-0` 壳的 right/bottom == 视口、`documentElement.scrollWidth/Height` == `clientWidth/Height`、`.app-toolbar` 恒为 `视口宽×40`、`visualViewport.scale` 恒为 1。
- **浮层锚定自查**（脚本里有个默认关闭的 inspector，把 `uiScaleBridgeScript` 里的 `DBX_DEBUG_LAYERS` 改成 `true` 重新打包即可）：打开任意下拉/弹窗后会打 `DBX-LAYER` 行，要求 `wrapper ... zoom=1/z`、`select-content` 的 rect 紧贴触发器且落在视口内、`hit=` 命中弹层自身。实测 130% → 弹层在触发器正下方；75% → 因下方空间不足自动翻到上方，两者都在视口内。
- `.zoomAccess(false)`：不再用 `zoom()`，也避免手势缩放和这个设置打架。
- 长期建议：补偿逻辑的"正统"位置是 `App.vue`（与 `isTauriRuntime` 分支并列），但改它要重建 dist（fork CI）；等下次同步上游/重建 dist 时挪进去，`uiScaleBridgeScript` 就能退化成纯日志。

### Rust 服务

- **不要用 `aws-lc-rs`**：OHOS 目标链接失败；TLS 相关 crate 已切到 `ring`（`rustls`、`russh`、`mysql_async`）。
- **原生 HTTP 服务必须绑 `127.0.0.1`**：HAP 传 `disablePassword: true`（`auth_middleware` 直接放行所有 `/api/*`），绑 `0.0.0.0` 等于把整套数据库客户端 API 暴露给局域网。`dbx-web` 用 `DBX_BIND_HOST`（默认 `0.0.0.0`，保持桌面/浏览器部署行为），`dbx-ohos` 里固定设 `127.0.0.1`——**不要删这行**。
- **`/api/health` 必须有**：否则 `ServerHealthChecker` 空等 10 秒。
- **MCP 启动**：不要用 `LocalBackend::open()` 再开一次 SQLite，复用已打开的 `AppState`（重复开会加约 10s）。
- **静态资源缓存头**：`mount_public_base_path` 给静态服务单独套 `Cache-Control`（`assets/*` 一年 immutable、其余 `no-cache`）+ `ETag` + `If-None-Match→304`，只包静态服务，`/api` 与 `/mcp` 的层不受影响。压缩谓词 `StaticCompressionPredicate` 必须继续排除 `206`/`304`，否则破坏 `ServeDir` 的 Range 语义。
- **loopback 上不要开静态 gzip**（`static_compression_enabled()` 按 `DBX_BIND_HOST` 判）：实测取启动闭包 243 个 chunk，gzip **2.16s** vs identity **1.21s**；压缩 CPU 远比省下的 loopback 传输值钱。只有绑 `0.0.0.0` 的部署才开。

### 产物 / 构建

- HAP 嵌两个 **git 跟踪**的产物：`rawfile/dbx-dist/`（前端，695 文件/26MB）与 `entry/libs/arm64-v8a/libdbx_ohos.so`（~46MB）。两者都必须从**合并后的源码**重建（流程见「HAP 产物重建」）。
- **前端 dist 不能本地构建**：本机是 OpenHarmony 环境，沙箱禁止 `dlopen` `.node` 与 WASM/WASI，且本机 node 跑不了 vite/rolldown → 必须走 fork CI。
- **不要解包上游 Release 包**当 dist 用（`DBX_<ver>_arm64-browser-static.tar.gz` 落后 main 几十个提交）。
- **替换 dist 后必须重跑** `python3 harmony/tools/inject_modulepreload.py`（幂等），否则第 ⑥ 项优化静默失效。
- 本机 `/tmp` 不可写、拉 GitHub artifact 常断流 → 一律落到工作区内并带 `-C -` 续传。

### 发版

- **release 只挂未签名包**：签名 HAP 含 debug profile（绑定设备 UDID），不可公开发布。
- 每次发版先把 `AppScope/app.json5` 的 `versionName`/`versionCode` 升到与 release 版本一致（当前基线 1.3.2 ↔ 1003002；1.3.1 ↔ 1003001 是上一个已发布版本），再构建并替换 release 资产，保证未签名 hap 的包内版本与 release tag 对齐（2026-08-28、2026-09-10、2026-09-13 均按此流程）。
- **核实包内版本**（打包后必查，`pack.info` 是 `version` 嵌套结构，不是平铺字段）：
  ```bash
  unzip -o -q <hap> pack.info module.json -d .tmp/hapcheck
  python3 -c "import json;d=json.load(open('.tmp/hapcheck/pack.info'));print(d['summary']['app'])"
  # → {'bundleName': 'com.dbx.ohos', 'version': {'code': 1003002, 'name': '1.3.2'}}
  ```

## 同步上游（t8y2/dbx main → harmonyos-port）

### 同步前必查清单（每次必做）

1. **保住这 4 处本地补丁**（上游合并容易覆盖）：
   - `crates/dbx-web/src/lib.rs`：静态资源缓存头/ETag 中间件、`DBX_BIND_HOST`、loopback 关闭静态 gzip
   - `crates/dbx-ohos/src/lib.rs`：`DBX_BIND_HOST=127.0.0.1`
   - `apps/desktop/src/App.vue`：`uiScaleApplyQueue` 的非 Tauri 分支（`applyUiScaleWithCss`）
   - `harmony/dbxohos/.../NativeBridge.ets` / `Index.ets` / `RawFileCopier.ets` / `ServerHealthChecker.ets`（OHOS 侧不与上游冲突，但要确认能编译）
2. **回填 `lib.rs` 路由**（坑① 的命令），反向差异应只剩 `/mq/*`、`/health`、`/mcp`、`/api/query/extract-data-grid-selection`。
3. **扫 `isTauriRuntime`**（坑④ 的命令）。
4. **重建两个产物**并重跑 `inject_modulepreload.py`，然后跑启动冒烟。

### 流程

```bash
# 1. 拉取
git -C upstream/dbx fetch origin --prune
git -C upstream/dbx fetch upstream main --no-tags --prune

# 2. 合并（保持既有 merge 模式，勿 rebase）
git -C upstream/dbx merge --no-ff --no-edit upstream/main \
  -m "merge: sync upstream/main (vX.Y.Z+) into harmonyos-port"

# 3. 解冲突（原则：上游进展 + 保留 OHOS 定制，见上「同步前必查清单」）

# 4. 验证编译（只编 lib 目标，很快）
cd upstream/dbx
OHOS_NDK_HOME=/storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_1/native \
  cargo check -p dbx-ohos

# 5. 回填 lib.rs 缺失路由（坑①）；逐个确认新 .route() 的 handler 在 routes/ 存在

# 6. 提交（husky pre-commit 依赖 pnpm → 必须 --no-verify）
git -C upstream/dbx add -A
git -C upstream/dbx commit --no-verify -m "merge: sync upstream/main ..."

# 7. 推送：submodule → 父仓库指针 → 父仓库
git -C upstream/dbx push origin harmonyos-port
cd ../.. && git add upstream/dbx && git commit -m "chore: bump upstream/dbx ..."
git push origin main

# 8. 重建 HAP 嵌入产物，见下
```

### HAP 产物重建（同步后必须做，否则 HAP 仍是旧版）

**① 前端 dist —— 不能本地构建，必须走 fork CI**（GetZ110/dbx Actions，从合并后的 `harmonyos-port` 构建）

```bash
# a) 临时分支 + 极简 workflow（Node 22 + pnpm/action-setup + pnpm --filter dbx... install --frozen-lockfile
#    + pnpm build + upload-artifact dist/）；触发用 push（workflow_dispatch 要求 workflow 在默认分支）
git -C upstream/dbx checkout -b ci/build-web-dist
#   写 .github/workflows/build-web-dist.yml：on: push: branches: [ci/build-web-dist]
git -C upstream/dbx add .github/workflows/build-web-dist.yml
git -C upstream/dbx commit --no-verify -m "ci: temp workflow to build web dist"
git -C upstream/dbx push origin ci/build-web-dist

# b) 等 run 完成后取 artifact（务必工作区内 + -C - 续传，本机拉取常断流）
RUN_ID=$(gh run list --repo GetZ110/dbx --workflow build-web-dist.yml --limit 1 --json databaseId --jq '.[0].databaseId')
AID=$(gh api "repos/GetZ110/dbx/actions/runs/$RUN_ID/artifacts" --jq '.artifacts[0].id')
TOK=$(gh auth token)
SIGNED=$(curl -sS -o /dev/null -w '%{redirect_url}' -H "Authorization: Bearer $TOK" \
  -H "Accept: application/vnd.github+json" "https://api.github.com/repos/GetZ110/dbx/actions/artifacts/$AID/zip")
for i in $(seq 1 60); do timeout 90 curl -sS -C - -o .tmp/ci-dist/dist.zip "$SIGNED"; \
  [ "$(stat -c%s .tmp/ci-dist/dist.zip)" -ge "$(gh api repos/GetZ110/dbx/actions/artifacts/$AID --jq .size_in_bytes)" ] && break; done
unzip -t .tmp/ci-dist/dist.zip          # 必须校验完整性

# c) 解包替换（替换前顶层结构应与旧 dist 一致：assets/ index.html fonts/ icons/ 等）
unzip -q .tmp/ci-dist/dist.zip -d .tmp/ci-dist/web-dist
DEST=harmony/dbxohos/entry/src/main/resources/rawfile/dbx-dist
rm -rf $DEST && mkdir -p $DEST && cp -r .tmp/ci-dist/web-dist/. $DEST/

# c2) 【必须】注入启动闭包 modulepreload（幂等）：只 preload 4 个 → 23 个（≈83% 字节）
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

- 确认 `index.html` 引用的 `assets/index-*.js` 哈希变了（说明 dist 真的换了），变更应全部落在 dbx-dist 与 `.so` 内
- 父仓库提交 `build(hap): rebuild embedded artifacts from ...` 并推送；dist 整体替换 = 大量「删旧 hash + 加新 hash」的 diff，正常

### 同步特有坑

- **① 双路由表（每次同步必查）**：上游只在 `crates/dbx-web/src/main.rs`（桌面入口）加新路由；OHOS 实际入口是 `crates/dbx-web/src/lib.rs`（NAPI 调 `dbx_web::run_server_with_shutdown`）。合并后必须对比回填，否则 OHOS 端缺新 API（v0.5.96 漏了 25 条）：
  ```bash
  comm -23 <(grep -oE '"/[a-z0-9/_-]+"' crates/dbx-web/src/main.rs | sort -u) \
           <(grep -oE '"/[a-z0-9/_-]+"' crates/dbx-web/src/lib.rs | sort -u)
  ```
- **② `dbx-core/Cargo.toml` 大概率冲突**：保留 OHOS 定制（`rusqlite` 带 `bundled`、`mysql_async` 用 `default-rustls-ring`、`rustls`/`russh` 用 `ring`）；上游新增依赖要保留（如 `libsqlite3-hotbundle` + `sqlite-multiple-ciphers`），它们给桌面 `src-tauri` 用，删了会让 desktop feature 悬空。
- **③ 版本号**：上游 `src-tauri`/`dbx-web`/`dbx-mcp` 版本随之上移，确认 `Cargo.lock` 与 `Cargo.toml` 一致（`cargo metadata` 可快速验证）。
- **④ 上游新增桌面功能必须同时判 `isTauriRuntime()`（每次同步必查）**：鸿蒙是「类桌面但非 Tauri」——注入 `__HARMONY_DESKTOP__` 使 `isDesktopRuntime()` 为 true，但**刻意不注入** `__TAURI_INTERNALS__`（否则 `api.ts` 会切到 Tauri 后端）。因此只判 `isDesktopRuntime()` 就调 `@tauri-apps/*` 的新代码在 OHOS 上必抛：
  - `getCurrentWebviewWindow()`/`getCurrentWindow()` → `Cannot read properties of undefined (reading 'metadata')`
  - `listen()`/`emit()` → `Cannot read properties of undefined (reading 'transformCallback')`

  发生在 `App.vue` 启动 try/catch 里时会被误报成 **「加载已保存连接失败：…」**（与连接无关，极易误判）。排查：`hdc hilog | grep -E "unhandled rejection|Cannot read properties of undefined"`，正常启动 0 条。

  已加守卫的位置（被上游覆盖需重加）：`App.vue` 的 `initializeUpdatePreparation()` / `setupDetachedWindowEvents()`、`composables/useTauriEvents.ts` 的 `setupTauriListeners()`、`uiScaleApplyQueue` 的 apply 回调。合并后扫一遍：
  ```bash
  grep -rn "isDesktop" apps/desktop/src --include=*.vue --include=*.ts | grep -v isTauriRuntime
  ```

## 验证方式

### 测试设备连接顺序（约定）

连接测试设备时**先确认本机连接情况**：`hdc list targets` 里已有的本机设备/模拟器优先，命中就直接使用，**不再 `hdc tconn`**。只有本机确实没有可用于鸿蒙测试的设备时，才考虑其他连接方式（网络 `hdc tconn <ip:port>`，本机 MateBook Pro 为 `127.0.0.1:43817`）。

`startup_smoke.sh` 已按此顺序实现：本机有设备 → 打印「本机已有可用设备…（优先使用，不再 tconn）」并直接以 `-t <target>` 执行；本机无设备 → 打印回退提示后尝试 `tconn`；两者都不行才退出码 2，并提示「先在本机启动模拟器/USB 接入设备，确认本机不支持鸿蒙测试后再考虑其他连接」。

### 启动冒烟（已脚本化：`harmony/tools/startup_smoke.sh`）

```bash
./harmony/tools/startup_smoke.sh --mode warm          # 稳态，严格阈值（≤400ms / ≤1.3s）
./harmony/tools/startup_smoke.sh --mode cold          # bm clean -c 之后（≤1700ms / ≤3.0s）
./harmony/tools/startup_smoke.sh --log .tmp/xxx.log   # 离线对历史日志重跑断言（不需设备）
```

设备掉线时**先 `hdc list targets` 确认本机连接情况**，确实没有设备再 `hdc tconn 127.0.0.1:43817`（见上「测试设备连接顺序」）；脚本会按同一顺序处理，本机已有设备时不再 tconn。`--serial`（或 `HDC_TARGET`）默认 `127.0.0.1:43817`，只用于在候选设备中选择 / 作为回退地址。默认 `--mode auto` 按实测自动分档：≤400ms 记 warm PASS，≤1700ms 记 WARN（冷缓存/偏慢），超过则判回归 FAIL。

> 改脚本时的坑：抓日志那行 `hdc hilog` 必须**直接执行**（`"$HDC" -t "$TARGET" hilog &`），不能包进 shell 函数——否则 `$!` 是子 shell 的 PID，`kill` 只杀子 shell，真正的 `hdc hilog` 变成孤儿进程持续往日志里追加，日志会被下一次启动的日志污染，离线断言随之误判为「加载了 2 次」。

脚本内部等价于下面这段手测流程：

```bash
hdc shell aa force-stop com.dbx.ohos; sleep 1
hdc shell hilog -r
(hdc hilog > .tmp/perf.log &) ; sleep 2
hdc shell aa start -a EntryAbility -b com.dbx.ohos
sleep 25   # 然后按下表断言
```

| 断言 | 期望 |
|---|---|
| `DBX_COPY: frontend unchanged …, skipped copy` | 稳态必须出现（首次安装/换版本后应为 `frontend copied from rawfile`） |
| `Local service ready in Xms` | < 200ms |
| `server ready: …/api/health (attempt N)` | N ≤ 3 |
| `[STARTUP] frontend modules loaded` 与 `bootstrap begin` 的间隔 | 稳态 < 400ms（冷缓存 < 1.7s） |
| `PageFirstContentfulPaintInPage … FCP` | 稳态页内 < 1.3s |
| `Succeeded in loading the content.` / `Index about to appear` | 各只出现一次 |
| `transformCallback` / `Failed to apply UI scale` / `Cannot read properties of undefined` | **0 条** |

日志过滤：`hdc hilog | grep -E "DBX_ABILITY|DBX_NATIVE|DBX_HEALTH|DBX_PAGE|DBX_COPY|DBX_THEME_PREFS|ARKWEB-CONSOLE"`

### 冷启动耗时测量（对比优化效果用）

```bash
PID=$(grep -E "DBX_ABILITY: Ability onCreate" .tmp/perf.log | head -1 | awk '{print $3}')
grep -n " $PID $PID E C02C11" .tmp/perf.log | head -1     # 进程创建（APPSPAWN 首行）
grep -oE "FCP:[0-9]+ms" .tmp/perf.log | head -1           # 页内 FCP
grep -E "ARKWEB-CONSOLE" .tmp/perf.log | grep -E "modules loaded|vue mounted"
```

冷缓存场景用 `hdc shell "bm clean -c -n com.dbx.ohos"` 制造（**只清缓存、不动已保存的连接**）。

### 驱动真机 UI（缩放 / 截图 / 布局测量）

```bash
H="hdc -t 127.0.0.1:43817"
$H shell "uinput -K -d 2072 -d 2058 -u 2058 -u 2072"      # Ctrl+= (keycode: CTRL 2072, = 2058, - 2057, 0 2000)
$H shell "uinput -T -c <x> <y>"                            # 绝对坐标点击（物理像素）
$H shell "uinput -K -t 'text'"                            # 输入文本
$H shell snapshot_display -f /data/local/tmp/s.jpeg && $H file recv /data/local/tmp/s.jpeg .tmp/s.jpeg
$H shell "uitest dumpLayout -p /data/local/tmp/l.json" && $H file recv /data/local/tmp/l.json .tmp/l.json
```

- `dumpLayout` 顶层 `root` 的 bounds 就是应用窗口：`[0,0][3120,1961]` = 最大化；更小 = 浮动窗口（此时沉浸式工具栏不渲染，**看不到工具栏右侧按钮**，验缩放要在最大化下做）。
- **注入的点击/按键落到最上层窗口**，且未聚焦窗口的第一次点击常常只聚焦不触发按钮（需要连点两次）。DBX 被别的窗口遮挡时，先把它点/切到前台再操作。
- 判定 UI 缩放是否正确，别看"看起来变大了"：读页面自己打的 `DBX-ZOOM` 行（`dbx:ui-scale-applied` 后输出），要求 `shell=<视口宽>x<视口高>`（`.fixed.inset-0` 壳与视口一致）、`scroll == client`、`toolbar=<视口宽>x40` 恒定、`vvScale=1`。`WebviewController.zoom()` 的坏状态是 `vvScale≠1` 且 `inner` 不变；CSS zoom 漏补偿的坏状态是 `toolbar` 宽随档位变化（z≥1.45 时曾被内层 `min-w-[760px]` 撑到 1140/1216）。

---

## 附录 A：已完成（历史）

- Rust NAPI 集成（`startServer`/`stopServer`/MCP）、原生 MCP Streamable HTTP（`/mcp`）、原生 `/api/health` 就绪探测
- 冷启动防重入（避免双 Web 实例）；前后台恢复只 reload 不重复 `loadContent`
- 主题/外观偏好原生 Preferences 持久化（细则见「关键约束/ArkWeb」）
- MCP 复用 `AppState`（重复打开 SQLite 曾加约 10s）
- 底部导航避让：`WindowBridge` 用 `getWindowAvoidArea(TYPE_NAVIGATION_INDICATOR)` + `on('avoidAreaChange')` 维护高度，`Index.ets` 注 `windowSafeAreaScript` 每 500ms 给 `<body>` 加 padding-bottom（2in1 上为 0，无副作用）
- 仓库按 submodule 结构托管到 GitHub
- 同步上游 v0.5.98（95 commits，冲突 1 处 + 回填 5 条路由）、v0.6.2（冲突 1 处）、v0.6.9（382 commits/1123 文件，冲突 2 处 + 回填 1 条路由）
- HAP 产物重建流程落地（dist 走 fork CI、`.so` 本地构建）；JRE 解压改逐条目并跳过 symlink（沙箱 symlink EPERM）
- UI 缩放：CSS `zoom`（web 侧原有实现）**+ 视口单位补偿**，纯 native 侧注入，见「关键约束/UI 缩放」
  （2026-09-13 两次修正：两度走弯路——先是「ArkWeb 无 setZoom」的错结论，后是误用实为视觉缩放的 `zoom()`）
- **启动优化（2026-09-12/13，3.09s → 1.65s，-46%）**：见下面 8 条 + 附录 C 的否定结论
  1. 指纹判断跳过重复复制（`dbx-dist-fingerprint`）——顺带让 mtime 稳定、HTTP/代码缓存得以复用
  2. `/api/health` 短间隔起步退避（原固定 300ms）
  3. 静态资源 `Cache-Control` + `ETag` + `304`
  4. 复制改全异步 + 与原生服务启动并行
  5. 启动页文案分段；隐藏逻辑改为 `#root` 有子节点即隐藏（兜底 2s→400ms、40 次→10 次）
  6. `index.html` 注入 23 条 `modulepreload`（`inject_modulepreload.py`）
  7. `libdbx_ohos.so` 改 `import lazy`
  8. 原生服务改绑 `127.0.0.1`；loopback 关闭静态 gzip

## 附录 B：ArkUI 重构评估（2026-09-13，结论：暂不全量重构）

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

**三个必须从零造轮子的成本中心**：① SQL 编辑器（CodeMirror 6 × 14 包，ArkUI 无可用的代码编辑器控件）8–14 人月；② DataGrid 自绘（虚拟滚动/canvas/冻结列/区域选择…）5–9 人月；③ 图表/血缘/ER（echarts + vue-flow + elkjs + leaflet）4–7 人月。合计 **44–77 人月（5–8 人年）**，另加 ArkTS 严格模式导致的 30–50% 改写量。

**不建议全量重构**：① 上游极活跃（上次同步 382 commits/1123 文件），原生前端会把「同步上游」从 merge 变成永久重写；② 收益（去 ArkWeb 启动 ~0.6s、去 HTTP/沙箱拷贝 ~0.1s、网格不丢帧、原生输入）与 5–8 人年 + 永久分叉不成比例。

**渐进路线**：阶段 1 原生外壳（1–3 人月，见「下一步任务 P1-B」）→ 阶段 2 高频简单面板原生化（3–6 人月：侧边栏树/对象浏览器/结构编辑器+DDL/导入导出向导/驱动管理）→ 阶段 3（不建议）DataGrid 自绘 + SQL 编辑器自研。

## 附录 C：冷路径两项"想省但省不掉"的实测结论（勿重复尝试）

- **#1 `precompileJavaScript` 预生成 V8 code cache —— 成本远大于收益**。API 可用（23/23 chunk 成功、3906KB），但有四个坑：
  1. 进程内**第一次调用必然 reject(-1)**，同参数第 2 次才返回 0 → 必须重试；
  2. `script` 必须传 **`string`**（`fs.readTextSync`），传 `Uint8Array` 会 -1（**同一个文件**）；
  3. `CacheOptions.responseHeaders` 只认 `E-Tag`/`Last-Modified`，且要与真实响应一致（用 HEAD 读）；
  4. **生成耗时 7.2s**（3.9MB），而 `bm clean -c` 后冷启动的 `frontend modules loaded` 只从 **1589ms → 1456ms**（-133ms）——生成的 code cache 与 HTTP 缓存同目录、一起被清掉；稳态本来就命中 HTTP 缓存自带的 code cache（283ms）。

  参考实现在 `CodeCacheWarmer.ets`，由 `AppConstants.ENABLE_CODE_CACHE_WARMUP=false` 关闭。
- **#2 砍启动闭包 —— 四项都不可回收**：
  - `en` 476KB **不是浪费**：`i18n/index.ts` 确实静态导入 en，但**每个非英文 locale 的 chunk 都通过 `locales/fallback.ts` 的 `withEnglishFallback()` 静态导入 en 并以其为底合并**（`zh-CN-*.js` 第一条 import 就是 `./en-*.js`），zh-CN 用户照样要加载；去掉 i18n 那句静态导入只会把发现时机推后、字节数不变。真要省的前提是「各语言翻译已完整 → 去掉英文字底合并」——那是上游 i18n 设计变更（缺键会显示原始 key），不属于启动补丁。
  - `codemirror` 483KB：被共享 chunk 图拉入——`lib/sql/sqlCompletion.ts` 运行时导入 `@codemirror/lang-sql` 的 8 个方言对象、`lib/sql/sqlSyntaxTreeWindow.ts` 导入 `@codemirror/language` 的 `syntaxTree`，两者被打进 api 共享 chunk（`api-*.js` 第一条 import 就是 `codemirror-*.js`）。要拆必须把这些共享 SQL 模块改成动态导入 = 上游重构。
  - `api` 655KB / `App` 877KB：核心图（737 个 API 函数 + 全部视图/对话框），不可切分。
- **含义**：Web 侧冷路径的可回收空间已经很小；再想显著变快只能动上游打包/代码分割，或走「附录 B 阶段 1」。
