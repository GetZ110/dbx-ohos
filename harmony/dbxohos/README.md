# DBX HarmonyOS（dbxohos）

DBX 的 HarmonyOS 移植工程：**ArkUI Web 组件 + 本地 HTTP 服务**。

目标设备：**鸿蒙平板（tablet）和鸿蒙 PC（2in1）**。

当前版本定位：**v1 Web 壳**，先跑通“应用内启动本地服务 + Web 加载 DBX 前端”，后续再逐步替换为原生 ArkUI / Rust `.so` 后端。

---

## 1. 当前实现

| 模块 | 状态 | 说明 |
|---|---|---|
| ArkUI `Web` 组件 | ✅ | 全屏加载 `http://127.0.0.1:4224` |
| Rust 原生后端 | ✅ | `entry/libs/arm64-v8a/libdbx_ohos.so` 内嵌 `dbx-web`，提供完整 `/api/*` |
| 本地 HTTP 服务 | ✅ | 优先启动 Rust 原生服务；失败时回退 ArkTS TCP 服务 |
| 前端资源 | ✅ | `resources/rawfile/dbx-dist` 内置 DBX SPA（约 30MB） |
| MCP Server | ✅ 原生 | Rust `dbx-mcp` Streamable HTTP 已挂载到 `http://127.0.0.1:4224/mcp` |
| DBX API 全量能力 | ✅ 原生 | 已通过 Rust `dbx-web` NAPI 接入 |
| 原生 ArkUI 界面 | ⏳ | 后续版本再逐步替换 Web 壳 |
| PC / 平板窗口适配 | ✅ 基础 | 全屏 Web + 自动响应式；后续按设备细化触控/窗口 |

---

## 2. 工程结构

```
dbxohos/
├── AppScope/                         # 应用级配置
│   ├── app.json5
│   └── resources/
├── entry/
│   ├── build-profile.json5
│   ├── hvigorfile.ts
│   ├── oh-package.json5
│   └── src/main/
│       ├── module.json5              # 设备类型 + 权限
│       ├── ets/
│       │   ├── common/Constants.ets  # 端口/路径常量
│       │   ├── entryability/EntryAbility.ets
│       │   ├── pages/Index.ets       # ArkUI Web 页面
│       │   ├── native/NativeBridge.ets # Rust NAPI 桥
│       │   └── services/
│       │       ├── RawFileCopier.ets # rawfile -> 沙箱
│       │       ├── HttpServer.ets    # ArkTS 本地 HTTP 服务（回退/MCP）
│       │       ├── ServerHealthChecker.ets # 启动就绪探测
│       │       └── McpServer.ets     # MCP JSON-RPC stub
│       ├── libs/arm64-v8a/
│       │   └── libdbx_ohos.so        # Rust dbx-web NAPI 原生库
│       └── resources/
│           ├── base/
│           └── rawfile/dbx-dist/     # DBX 前端 dist
```

---

## 3. 构建与运行

### 3.1 环境要求

- DevEco Studio 5.x+ / HarmonyOS SDK 6.1.0(23) 或兼容版本
- 支持 `tablet`、`2in1` 的设备或模拟器

### 3.2 打开工程

1. 使用 DevEco Studio 打开本目录：
   ```
   /storage/Users/currentUser/DevEcoStudioProjects/dbxohos
   ```
2. 等待工程 Sync 完成。
3. 选择 `entry` 运行到平板或 PC 模拟器/真机。

### 3.3 命令行构建（可选）

在 DevEco Studio 自带终端或配置好 hvigorw 后：

```bash
hvigorw assembleHap --mode module -p product=default
```

或直接使用 DevEco Studio 的 **Build > Build Hap(s)/APP(s)**。

> 未签名 HAP 仅用于本地调试；真机安装通常需要签名配置。

---

## 4. 运行行为

1. `EntryAbility` 启动时：
   - 将 `rawfile/dbx-dist` 拷贝到应用沙箱 `filesDir/dbx-dist`；
   - 优先调用 Rust NAPI `NativeBridge.startServer()`，启动内嵌 `dbx-web`，监听 `127.0.0.1:4224`；
   - 若原生启动失败，回退到 ArkTS TCP HTTP 服务。
2. `Index.ets` 加载 `http://127.0.0.1:4224/`。
3. 本地服务：
   - 静态文件：DBX SPA
   - `/api/*`：由 Rust `dbx-web` 提供完整 DBX 能力
   - `/mcp`：Rust `dbx-mcp` Streamable HTTP 原生 MCP

---

## 5. MCP Server

原生 MCP Server 已通过 Rust `dbx-mcp` + `rmcp` Streamable HTTP 接入：

```
POST http://127.0.0.1:4224/mcp
```

实现内容：

- `initialize`
- `notifications/initialized`
- `tools/list`
- `tools/call`（真实调用 `dbx-core`，支持连接列表、Schema、SQL 查询、Redis、Mongo 等）
- `dbx_open_session` / `dbx_close_session` / `dbx_execute_query` 等 DBX 工具

> 原生模式下不再需要 ArkTS MCP stub；ArkTS `/mcp` stub 仅在 Rust 原生服务启动失败的回退模式中使用。

---

## 6. PC / 平板适配说明

当前 v1 采用全屏 `Web` 组件，天然适配不同窗口尺寸：

- PC：窗口可缩放，Web 全屏填充。
- 平板：竖屏/横屏自适应，Web 自动重排。
- 触控：Web 组件默认支持触摸滚动、点击；后续针对 DBX 的右键菜单、拖拽、快捷键做触屏适配。

后续计划：

- 根据 `window.getWindowProperties()` 区分 PC/平板布局。
- 增加原生标题栏、侧边栏、命令面板等 ArkUI 原生组件。
- 将高频操作（连接管理、SQL 编辑器）逐步 ArkUI 原生化。

---

## 7. Rust 原生后端接入

### 7.1 已完成

- `dbx-web` 已重构为库 + 薄 main：
  - `crates/dbx-web/src/lib.rs` 暴露 `pub async fn run_server()`
- 新增 `crates/dbx-ohos`：
  - 使用 `napi-ohos` / `napi-derive-ohos`
  - 导出 `startServer`、`stopServer`、`startMcpServer`、`stopMcpServer`
- 已构建并放入鸿蒙工程：
  ```
  entry/libs/arm64-v8a/libdbx_ohos.so
  ```
- ArkTS 通过 `NativeBridge.ets` 调用原生 `startServer`。

### 7.2 构建命令（Rust 侧）

```bash
export OHOS_NDK_HOME=/storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_1/native
cd /storage/Users/currentUser/GitProject/dbx
cargo build --release -p dbx-ohos
cp target/release/libdbx_ohos.so \
  /storage/Users/currentUser/DevEcoStudioProjects/dbxohos/entry/libs/arm64-v8a/libdbx_ohos.so
```

### 7.3 P1 生命周期已完成

- ✅ `stopServer` 使用 `CancellationToken` 优雅关闭 Rust 服务
- ✅ 启动时等待 `/api/health` 就绪后再加载 Web 页面（原生 `dbx-web` 已新增该路由）
- ✅ 前后台切换时停止/恢复本地服务并重新加载页面
- ✅ 修复冷启动竞态：`onWindowStageCreate` 与 `onForeground` 共享同一次启动流程，避免双 Web 实例导致 IndexedDB/localStorage 无法持久化（明暗主题丢失）
- ✅ 恢复时只触发 Web reload，不再重复 `loadContent`，避免再次产生双 Web 实例
- ✅ 主题/外观偏好增加原生 Preferences 持久化：`javaScriptOnDocumentStart` 注入脚本在 SPA 启动前恢复 `localStorage`，并拦截 `dbx-*` 写入同步到原生存储
- ✅ MCP 复用已打开的 `AppState`，不再二次打开 SQLite，显著缩短冷启动时间

### 7.4 下一步

- 可选：将 MCP 单独拆到独立端口（当前与 Web 共用 `4224/mcp`）。

---

## 8. 已知限制

- `/api/*` 已由 Rust `dbx-web` 提供真实能力。
- ArkTS TCP HTTP 服务仅作为回退和 MCP stub，不再承载主 API。
- MCP 已由 Rust `dbx-mcp` 原生提供；ArkTS stub 仅作为回退保留。
- `stopServer` 当前为 best-effort，不保证立即释放端口。
- 未签名 HAP 只能在开发者模式/模拟器调试。

---

## 9. 文件清单

```
README.md
AppScope/app.json5
entry/src/main/module.json5
entry/src/main/ets/common/Constants.ets
entry/src/main/ets/entryability/EntryAbility.ets
entry/src/main/ets/pages/Index.ets
entry/src/main/ets/native/NativeBridge.ets
entry/src/main/ets/services/RawFileCopier.ets
entry/src/main/ets/services/HttpServer.ets
entry/src/main/ets/services/ServerHealthChecker.ets
entry/src/main/ets/services/McpServer.ets
entry/src/main/ets/services/ThemePrefs.ets
entry/src/main/ets/services/WebPrefsBridge.ets
entry/libs/arm64-v8a/libdbx_ohos.so
entry/src/main/resources/rawfile/dbx-dist/
```
