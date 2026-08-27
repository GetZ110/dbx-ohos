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
- 同步上游 v0.5.96（136 commits，冲突 1 处 + lib.rs 回填 25 条上游路由）
- HAP 产物重建流程落地：前端 dist 走 fork CI（GetZ110/dbx Actions 从合并后源码构建，勿用 Release 包——其落后 main 几十个提交）、Rust `.so` 本地 OHOS release 构建，已写入「同步上游」章节

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
- **发版约定（release 只挂未签名包）**：签名 HAP 含 debug profile（绑定设备 UDID），不可公开发布；每次发 release 前，先把 `AppScope/app.json5` 的 `versionName`/`versionCode` 升到与 release 版本一致（当前基线：1.1.0 ↔ 1001000），再构建并替换 release 资产，保证未签名 hap 的包内版本与 release tag 对齐（本次 2026-08-27 已按此流程替换 v1.1.0 资产）。

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

# b) 等 run 完成后取 artifact（gh run download 可能静默失败，改用 gh api 直拉 zip）
RUN_ID=$(gh run list --repo GetZ110/dbx --workflow build-web-dist.yml --limit 1 --json databaseId --jq '.[0].databaseId')
AID=$(gh api "repos/GetZ110/dbx/actions/runs/$RUN_ID/artifacts" --jq '.artifacts[0].id')
TOK=$(gh auth token)
gh api -H "Authorization: Bearer $TOK" -H "Accept: application/vnd.github+json" \
  "repos/GetZ110/dbx/actions/artifacts/$AID/zip" > dist.zip   # 注意：给足超时，5MB 左右

# c) 解包替换；替换前顶层文件结构应与旧 dist 一致（assets/ index.html fonts/ icons/ 等）
unzip -q dist.zip -d web-dist
DEST=harmony/dbxohos/entry/src/main/resources/rawfile/dbx-dist
rm -rf $DEST && mkdir -p $DEST && cp -r web-dist/. $DEST/

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
- 父仓库提交：`git commit -m "build(hap): rebuild embedded artifacts from synced v0.5.96 source"` 并推送
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
