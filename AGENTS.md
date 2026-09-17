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

## 当前状态（2026-09-13；包名/签名一节 2026-09-16 更新）

- **包名（2026-09-16 改名 + 重签名，已验证）**：`io.github.getz110.dbx`（原 `com.dbx.ohos` —— 末段 `ohos` 是 AGC 保留字，不合规）。用 **DevEco Studio 自动签名**对新包名重签完成：profile 换成 `~/Documents/ohos/config/default_dbxohosdUZI6Tr9cHl_4UaRvJYTYdNNEYSb0rK5vsYaH3PWw2Q.{cer,p7b,p12}`（内部 `"bundle-name":"io.github.getz110.dbx"`、`"allowed-acls":["ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY"]`），DevEco 同时改写了 `build-profile.json5` 的 `signingConfigs`。之后 CLI `assembleHap` **`SignHap` 通过**，签名/未签名包 `pack.info` 均为新包名（69,018,553 / 68,605,764 字节，`version 1.3.3 / 1003003`），`./dev-run.sh --skip-build` 装机启动正常，两轮真机日志离线复跑启动冒烟各 **12/12 PASS**。**注意：签名 profile 与包名绑死，再改包名必须重做签名**（不改就会 `SignHap` 报 `00303074`）。**开 DevEco 前先 `harmony/tools/hvigor_links.sh off`，回 CLI 前 `on`**（否则 DevEco 同步报 `00302013`，见「DevEco Studio 与命令行构建的冲突」）。改名后是**全新的应用身份**：老 `com.dbx.ohos` 已手动卸载，数据（连接/驱动/JRE）**没有迁移**，历史 `release/*.hap` 仍是老包名。详见「构建命令 → 改包名（bundleName）」。
- **版本**：`AppScope/app.json5` = `versionName 1.3.3 / versionCode 1003003`，**已于 2026-09-13 发布到 GitHub release**（tag `v1.3.3-dbx0.6.9`，Latest；hotfix：结果表格第一行被表头压住 + 切 Canvas 丢表头）。上一版是 `1.3.2 / 1003002`（tag `v1.3.2-dbx0.6.9`，资产未被覆盖）。上游仍是 dbx v0.6.9，dist/.so 未重建。
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

### 改包名（bundleName）

包名受 AGC 规范约束：≥3 段点分、7–128 字符、每段只允许字母/数字/下划线、首段以字母开头、每段以字母或数字结尾、**不能把保留字作为独立段**（`oh`/`ohos`/`harmony`/`harmonyos`/`openharmony`/`system`）。`com.dbx.ohos` 就是踩了最后一条，2026-09-16 改成 `io.github.getz110.dbx`。

**改名要动的地方**：
1. `harmony/dbxohos/AppScope/app.json5` 的 `bundleName`（唯一真值）；
2. `harmony/tools/startup_smoke.sh` 的 `BUNDLE=`（以及注释里的示例）；
3. `AGENTS.md` 里所有 `aa start/force-stop/bm clean -n` 示例；
4. 无需改代码：ArkTS/Rust 都没硬编码包名，沙箱路径由运行时给。

**改完必须重做签名，否则装不上**（实测）：

```
> hvigor ERROR: Failed :entry:default@SignHap...
> 00303074 Configuration Error
> The bundleName in app.json5/hvigorfile.ts does not match the bundleName in the generated SigningConfigs
```

原因：签名 profile（`.p7b`，本项目放在 `~/Documents/ohos/config/`，`default_dbxohos*.p7b`）内部带 `"bundle-name"`，与 `app.json5` 必须一致；`build-profile.json5` 的 `app.signingConfigs[].material` 指向了 cert/profile 路径。修法二选一：
- **DevEco Studio**：用新包名打开工程 → `File > Project Structure > Project > Signing Configs` → 勾自动签名（需登录华为账号，且该 bundle name 已在 AGC 注册）→ 它生成新的 profile/cert，并把 `build-profile.json5` 的 signingConfigs 指过去；
- **AGC**：按新包名注册应用 → 申请 debug/release Profile（要用的 ACL 权限一并勾）→ 下载 `.p7b` 替换本机 profile，并同步改 `build-profile.json5` 里的 `certpath`/`profile`。

**注意**：未签名包不受影响（`assembleHap` 会先生成 `entry-default-unsigned.hap` 再签名失败），所以**发版产物仍可构建**；只有本地装机调试需要新 profile。另外改名 = 新应用，老的 `com.dbx.ohos` 已手动卸载、**数据不迁移**，历史 release（`release/*.hap`）都还是老包名。

**本次实操记录（2026-09-16：改名 + 重签名一次跑通）**：

1. 改 `AppScope/app.json5` 的 `bundleName` → `io.github.getz110.dbx`，同步 `startup_smoke.sh` 的 `BUNDLE=` 与 AGENTS.md 里的 `aa start/force-stop/bm clean -n` 示例；
2. CLI `assembleHap` 首次在 `SignHap` 失败（`00303074`，旧 profile 绑着老包名）；
3. `harmony/tools/hvigor_links.sh off` → DevEco Studio 打开工程 → `File > Project Structure > Project > Signing Configs` → 勾自动签名（`Associate with registered application` / `Automatically generate signature`，需登录华为账号）→ 同步/构建通过，生成新 profile/cert（文件名见上「当前状态」）；
4. DevEco 改写 `build-profile.json5` 的 `app.signingConfigs[0].material`（`certpath`/`profile`/`storeFile` 三项都指向新文件）；
5. `harmony/tools/hvigor_links.sh on` → CLI `assembleHap` **`SignHap` 通过，BUILD SUCCESSFUL**；`entry-default-signed.hap` 69,018,553 B / `entry-default-unsigned.hap` 68,605,764 B，两者 `pack.info` 均为 `bundleName = io.github.getz110.dbx`、`version 1.3.3 / 1003003`；
6. `./dev-run.sh --skip-build` 装机 + 启动正常；对两轮真机日志离线复跑启动冒烟，各 **12/12 PASS**（`modules loaded` 338ms / 356ms，页内 FCP 1237ms / 1159ms）。

**顺带证实**：DevEco 自动签名会**代申请受限 ACL**——新 profile 的 `"acls":{"allowed-acls":[...]}` 里被自动写进了 `ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY`（本机上一份 profile 是 `allowed-acls: []`）。将来要 JIT 那几个权限，同样走这条自动签名路径（见「JIT / 可执行内存权限」）。**注意 `module.json5` 里先别留权限声明**，否则装机报 `9568289`（约束 1）。

### DevEco Studio 与命令行构建的冲突（hvigor 依赖挂接，2026-09-16 实测）

**两套 hvigor 不能共用同一份项目依赖**：

| 环境 | hvigor 从哪来 | 项目需要什么 |
|---|---|---|
| 命令行（`deveco_tools`） | `$DEVECO_TOOLS/hvigor/bin/hvigorw.js`（6.23.15-next） | **必须**有 `node_modules/@ohos/{hvigor,hvigor-ohos-plugin}` → 符号链接到 `$DEVECO_TOOLS/hvigor/*`；缺了报 `Cannot find module '@ohos/hvigor-ohos-plugin'`（`NODE_PATH` 无效，hvigor 用自己的解析逻辑） |
| DevEco Studio | 它自带的一份，跑在自己的 HNP 沙箱里（日志里是 `/data/app/hvigor.org/hvigor_1.0.0/bin/hvigorw.js`） | 项目里**不能有**指向项目外的这些符号链接（沙箱读不到目标 / 与它自带的 hvigor 版本不匹配） |

冲突表现（DevEco 同步/构建时）：

```
> hvigor ERROR: 00302013 Script Error
> Error Message: The root node is not yet available for build. At file: hvigorfile.ts or hvigorconfig.ts
> hvigor ERROR: BUILD FAILED in 3 s 225 ms
```

官方对 `00302013` 的解释是"根节点还没准备好用于构建"，列出的可能原因是在 `hvigorconfig.ts` 里过早调用 API（本项目没有 `hvigorconfig.ts`）；本项目实测的成因是 **app 插件（`appTasks`）没被加载出来**，于是根节点始终不注册——即上面那条"DevEco 读不到项目外的插件"。判据：同一个工程用 CLI 跑 `hvigorw.js --sync -p product=default` **通过**，在 DevEco 里失败。

**切换脚本**（`harmony/tools/hvigor_links.sh`）：

```bash
./harmony/tools/hvigor_links.sh status   # 看两个链接现状
./harmony/tools/hvigor_links.sh off      # 用 DevEco 之前：删符号链接 + 清 .hvigor/{cache,outputs}
./harmony/tools/hvigor_links.sh on       # 回到命令行构建：重建符号链接
```

- `off` 只 `rm` 符号链接本身，不动 `$DEVECO_TOOLS` 里的实体目录；清缓存是为了避免两套 hvigor 的缓存互相污染。
- **清缓存后第一次 CLI 构建可能失败一次**（报 hvigor-config 相关），再跑一次即正常。
- 用 DevEco 自动签名成功后，DevEco 会**改写 `build-profile.json5`**（新的 `signingConfigs`：新 profile/cert 路径）与 `local.properties`；之后跑 `hvigor_links.sh on`，命令行就能继续构建/装机（用的是 DevEco 生成的新 profile）。
- **顺序别搞反**：`off` → 开 DevEco（同步 / 自动签名）→ **关 DevEco** → `on` → CLI 构建/装机。两边都不切时是典型的"互相看不见"：DevEco 报 `00302013`、CLI 报 `Cannot find module '@ohos/hvigor-ohos-plugin'`，同一个根因的两面。自动签名还要求工程的 bundle name **已在 AGC 注册**、本机时间与北京时间一致（见「改包名」的实操记录）。

### 命令行环境修复（本机已做，勿删）

- SDK 工具链缺 `x` 位：`chmod +x` 过 `toolchains/{hdc,restool,ark_disasm,syscap_tool,...}`、`toolchains/lib/{ohos_packing_tool,hap-sign-tool,binary-sign-tool}`、`ets/.../ark/build/bin/{es2abc,panda_guard}`
- `node_modules/@ohos/hvigor-ohos-plugin` → symlink 到 `deveco_tools/hvigor/hvigor-ohos-plugin`
- plugin 的 `node_modules/@ohos/hvigor` → symlink 到 `deveco_tools/hvigor/hvigor`；hvigor 自身 `node_modules/@ohos/hvigor` → 自链接（worker 解析需要）
- `deveco_tools/tool/node` → symlink 到 `deveco_tools/node`（CLT 布局需要）
- 已知小问题：`devecocli check lint` 能跑但报告为空（codelinter 与 SDK 26/OHOS 7.0 Beta 兼容问题），当前以 hvigor `CompileArkTS` 无错为准。
- **`deveco_tools` 里的 OHOS clang 不可用**（2026-09-15 实测）：`sdk/default/openharmony/native/llvm/bin/{clang,clang-15}` 是无法执行的实体文件（`EPERM`；原本应是 `clang -> clang-15` 符号链接，被复制成普通文件后代码签名失效）。编原生代码（如 native child process 的子进程库）请用 **Harmonybrew 那份 NDK**：`OHOS_NDK_HOME=/storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_1/native`，示例见 `harmony/tools/build_ncp_spike.sh`。
- 写原生 child process 代码时：`AbilityKit/native_child_process.h` 自身没 include `<stdbool.h>`，包含它之前要先 `#include <stdbool.h>`，否则报 `unknown type name 'bool'`。

## 下一步任务（按优先级，2026-09-13 排定）

### P0 收口：验最后一处 + 发 1.3.2（1–2 天）

1. ✅ **UI 缩放已修复并经人工确认通过（2026-09-13）**：问题链与修法见「关键约束/UI 缩放」（初版 CSS `zoom` 整页右溢 → 误用实为视觉缩放的 `zoom()` → 最终 CSS `zoom` + 视口单位补偿 + 工具栏反向 zoom 固定尺寸 + 壳 min-size 归零）。纯 native 侧注入，不需要重建 dist。自动化不变量：0.75–1.9 全档 `shell = 视口`、`scroll == client`、`toolbar = 视口宽×40` 恒定、`vvScale = 1`；启动冒烟 12/12。
1b. ⚠️ **缩放值是持久化的，但启动时落地两次**（2026-09-13 实测：清空日志后冷启、无任何按键，页面依次打 `DBX-ZOOM reset:1` → `applied:1.3`）——settings store 默认值先应用，随后异步水合出持久化值，因此启动瞬间有一帧未缩放的闪烁（旧结论"缩放不跨重启保留"是错的，别照它改）。想消掉闪烁需要把 uiScale 也镜像进原生 Preferences 并在 `documentStart` 就应用（theme 已有同款机制），属 P2 打磨，不影响 1.3.2。
2. ✅ **1.3.2 已发布（2026-09-13）**：GitHub release `v1.3.2-dbx0.6.9`，标题 `DBX HarmonyOS v1.3.2 (upstream dbx v0.6.9)`，已置 Latest → https://github.com/GetZ110/dbx-ohos/releases/tag/v1.3.2-dbx0.6.9 。**只挂未签名包** `DBX_HarmonyOS_v1.3.2_dbx0.6.9_unsigned.hap`（68,638,143 字节，GitHub 侧 digest `sha256:79bd458c…47e90` 与本地实测一致），v1.3.1 资产未被覆盖。
   - 发布前链路：`AppScope/app.json5` 升 `1.3.2 / 1003002` → 重新打包（dist 与 `.so` 都是最新的，**没有**重跑 fork CI / Rust release）→ 未签名包内版本核验为 1003002 → 归档 + 写 `release/RELEASE_NOTES_v1.3.2.md`（含「已验证」小节，正文即 release body）→ 装机跑启动冒烟 12/12 → 人工确认 130% 下弹层锚定且内容跟随缩放。
   - 中途因缩放相关的两个 bug 各重新打包一次，均**覆盖同名资产**：① 弹层漂移/跑出窗口；② 上一版修复把弹层内容也抵消成"不跟随缩放、始终固定大小"（改为 wrapper 抵消定位 + 子元素恢复缩放）。最终字节 68,638,143 / SHA-256 `79bd458c…47e90`，已与线上 digest 核对一致。
   - `release/` 在 `.gitignore` 里：包与 notes 不入 git，只作本地归档 + 上传 release 用。
2b. ✅ **1.3.3 已发布（2026-09-13，hotfix）**：修复「结果表格第一行被表头压住」与「切 Canvas 渲染模式丢表头」两个用户可见问题（根因见「关键约束/数据表格表头注入」）。链路：`AppScope/app.json5` 升 `1.3.3 / 1003003` → 打包（**只改了 ArkTS 注入脚本，dist 与 `.so` 未重建**）→ 未签名包内版本核验 1003003 → 归档 `release/DBX_HarmonyOS_v1.3.3_dbx0.6.9_unsigned.hap`（68,640,949 字节，SHA-256 `2426e15e…fedcbb6`，与线上 digest 一致）+ `RELEASE_NOTES_v1.3.3.md` → 装机启动冒烟 12/12 PASS → `gh release create`（`--target main`，tag 指向版本提交 `deab2fd`）。v1.3.2 资产未被覆盖。
3. ✅ **启动冒烟已脚本化（2026-09-13 完成）**：`harmony/tools/startup_smoke.sh`——`force-stop → hilog -r → aa start → 抓 25s 日志 → 12 条断言`（断言清单见「验证方式」）。用法：`--mode warm|cold|auto`、`--log <file>`（离线对历史日志重跑断言，不需要设备）、`--serial`；退出码 0/1/2。
   - 理由：这一轮改的东西大多**错了会静默退化**——指纹判断错 → 用户一直用旧前端；缓存头丢 → 冷启动退回 3.8s；启动页隐藏逻辑错 → 闪白；gzip 门控失效 → 白烧 1s CPU。没有自动化只能靠人记。
   - 验证记录：真机三连（暖 293ms/991ms → `bm clean -c` 冷 1573ms/2656ms → 回温 296ms/1006ms）全部 12/12 PASS；离线负向测试确认冷日志在 `--mode warm` 下正确判 FAIL，注入 `Cannot read properties of undefined` 后正确判 FAIL。

### P0' agent 类驱动在 HarmonyOS 6 上不可用（2026-09-14 诊断；**2026-09-17 方案 D 已生产化，oracle 应用内跑通**）

- **根因**：HarmonyOS 6 强制 **ELF 代码签名**（`code_protect`/BinSec，hilog `node: CheckSigned, ret: 1017604106`）。沙箱里下载的未签名 ELF `execve` → `EACCES`；自签名后普通用户域能跑、**应用域仍 `EPERM`**。**别再往「chmod / 文件权限位」方向排查**，影响所有走子进程的 agent 驱动（oracle/达梦/hive/… 及 JRE）。
- **已被真机证伪、别再从头试的三条**：**A** HNP 随 HAP 分发（要华为二进制证书扩展 + 官方工具链的 signMap）；**B** 自己给 ELF 签名（受限权限要 AGC 审批的 ACL；更关键：2026-09-17 三级对照证明**连用应用自己的证书签都没用** —— 未签名 `EACCES(13)` → 自签名 `EPERM(1)` → 应用证书签名（华为签发开发证书 + profile）**仍 `EPERM(1)`**，拒绝点是 BinSec `LoadBinCtrlAndManage`「parent process cannot load this binary」，与签名身份无关）；**A′** agent ELF 放进 HAP `libs/`（装后 0644 无 x 位 → `execve` `EACCES`）。
- **可能解锁"应用直接执行沙箱 ELF"的只剩两条（均未验证）**：**HNP**；或 `ohos.permission.CUSTOM_SANDBOX`（"允许应用将沙箱类型改为动态沙箱"，system_basic / availableType NORMAL / provisionEnable，日志里的 `isCustomSandbox: 0` 正对应它，华为自家终端 HiShell 就申请了它）。`DISABLE_CODE_MEMORY_PROTECTION` 管的是 XPM 代码完整性保护，大概率无关；`atm perm -g` 绕不过（实测要求权限已被应用声明）。详见 `docs/ohos-agent-exec-denied.md` §18。
- **可行路线 D = native child process**：appspawn 以应用身份起子进程，入口是 `libs/` 里 .so 的导出函数（走 dlopen，不需要 x 位/签名）。
  - ✅ **oracle 端到端已跑通**（真机）：`libdbx_agent_oracle.so`（Go c-shared，28MB）在子进程里回 `{"ready":true}` + `handshake`；ArkTS 与 Rust 两侧都验证过（Rust：`UnixStream::pair()` + `#[link(name="child_process")] OH_Ability_StartNativeChildProcess`）。
  - ✅ **2026-09-17 生产化完成**：`crates/dbx-core/src/db/agent_ncp.rs` + `agent_driver.rs` 的 `AgentProcess`/`SpawnedAgent`/`spawn_agent_io()` + `agent_manager.rs` 的 `ohos_bundled_agent_launch()`（`"oracle" => libdbx_agent_oracle.so:Main`）。同一个 `/api/connection/test` 从 `Permission denied (os error 13)` 变成 **`dial tcp 127.0.0.1:1521: connect: connection refused`**（= 子进程起来、handshake 通过、go-ora 真的拨号）。报告：`docs/ohos-oracle-driver-report.md`；细节：`docs/ohos-agent-exec-denied.md` §17。注意 release 重建实测 **45m42s**，HAP 69→**90MB**。
  - **Go c-shared 在 musl 上有两处硬伤，必须打 Go 运行时补丁**（否则连 dlopen 都过不去）：① IE TLS（`runtime.load_g/save_g` 访问 `runtime.tls_g`，[go#54805](https://github.com/golang/go/issues/54805) 至今 open；`-fno-emulated-tls`/TLSDESC 也不行——OHOS musl 不支持 TLSDESC，这正是 OHOS clang 默认 `-femulated-tls` 的原因）→ 改调 C 侧 `static __thread`；② `_rt0_arm64_lib` 拿不到 argc/argv（musl 调 init_array 不传）→ 改用 asm 自带骨架。落地：`harmony/tools/go_ohos_overlay.py`（**`-overlay` 对 `.s` 生效**，不碰 GOROOT）+ `build_agent_cshared.sh`。
  - **E = JDBC 进程内 JVM：已评估，当前不可行**（三重卡死）：① 沙箱里的 .so `dlopen` 被拒（EINVAL），**只有 HAP `libs/` 能 dlopen**；② JIT 默认被禁（exec 内存 `EINVAL`），权限名与申请路径见「关键约束/坑 → **JIT / 可执行内存权限**」；③ dbx 下载的 JRE 是 **glibc** 的（`libjvm.so` 依赖 `libc.so.6`），OHOS 只有 musl。
- **内置驱动识别已通用化（2026-09-17）**：`ohos_bundled_agent_library()` = 已知列表 + 从 `/proc/self/maps` 推导 HAP `libs/` 目录后探测 `libdbx_agent_<key>.so`（`OnceLock` 缓存）；`is_driver_installed()` / `build_agent_list()` 把内置驱动报成 `installed=true, bundled=true, update_available=false`，`uninstall` 返回"随应用分发、不能单独卸载"。**收益：以后加驱动只需把 `.so` 放进 `entry/libs/arm64-v8a/` 重建 HAP（约 10s），不用再重建 46MB 的 Rust `.so`** —— 已用 14 字节假 `libdbx_agent_cassandra.so` 验证探测生效（报告 §6.6）。前端 dist 未重建，所以 UI 只显示"已安装"、没有"内置"标签。
- **还没做**：① 其余 13 个 Go agent 机械铺开（每个 `main()`→`runStdioAgent()` + `ohos_ncp.go`，共用 shim；`duckdb`/`tdengine` 是 Rust agent 走 cdylib）；② 前端 dist 重建以显示"内置"标签（可选）；③ JRE 内嵌 JVM；④ `compressNativeLibs` 与 feature HAP 控体积（HAP 已 90MB，每个 Go agent 压缩后 +20~28MB）。
- **启动回归已补验（2026-09-17）**：`startup_smoke.sh --mode warm` **12/12 PASS**（`modules loaded` 359ms / FCP 1216ms），加 28MB agent `.so` 后启动无回归。**驱动运行时启停也验过**：`AgentDriverClient`（驱动管理器"运行/重启"的 daemon 路径，`spawn_client_for_key`）也已接入 `spawn_agent_io()`；`/api/agents/runtime/restart|stop {"runtimeId":"agent:oracle"}` 均 `{"ok":true}`，`running pid=53176` ↔ `stopped` + 子进程无残留。**注意两条 spawn 路径都要接 NCP，只改 `AgentRuntimeClient` 会让 daemon 报 `libdbx_agent_oracle.so:Main: No such file or directory`。**
- 完整证据链/失败码/复现命令/脚手架清单见 `docs/ohos-agent-exec-denied.md` **§9–§17**（§13 spike、§14 Go+Rust 打通、§15 JDBC、§16 现状、§17 生产化实测）。

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

### 数据表格表头注入（DOM 渲染模式，2026-09-13 两处修复）

`Index.ets` 的 `gridHeaderInScrollerScript` 把 `.data-grid-header-shell` **搬进** `.data-grid-scroller` 做 sticky 表头（让表头与数据行在合成器上同步滚动，替代 dbx 每帧 `headerRef.scrollLeft = ...` 的 JS 同步；Canvas 模式 `canvas-grid-scroller` 直接跳过）。搬 Vue 拥有的节点有两个坑，都是用户报过的：

- **绝不写死表头高度**：表头真实高度跟渲染行数走（只有列名 28px；带 `int/TEXT` 类型行或注释行约 40px）。原先注入里 `minHeight/height = "28px"`，加上 `overflow: visible`，40px 的表头行会向下溢出 12px 压住第一行数据（现象：第一行的数字/文字被切掉上半）。现在只让内容决定高度。**排查手法**：CDP 读 `.data-grid-header-shell` 的 `getBoundingClientRect()` 与内联 `style`，再看第一行 `[data-row-index="0"]` 的 `top` 是否等于 shell 的 `bottom`，并在第一行顶部做 `document.elementFromPoint` —— 命中表头单元格即说明又被压住了。
- **搬迁必须可逆**：切到 Canvas 渲染模式时，Vue 的 patch 会移除 DOM 分支容器（`.relative.min-h-0.flex-1`），被搬进去的 shell 随之被摘出文档，表现为「表头消失、要重开标签页才回来」。脚本因此记录 shell 的原父节点（`moved` WeakMap），离开 DOM 模式或节点被摘除时放回原位并清空注入样式（`clearStyles` 含 `background/position/top/zIndex/width/overflow/boxShadow/visibility/flexShrink/minHeight/height`）。
- **放回要早于下一帧**：还原若只挂在 250ms 防抖的 `applyAll` 上，切模式时表头会先消失约 0.5s。现在 MutationObserver 回调里先跑 `healDetached()`（microtask，早于绘制），实测 DOM↔Canvas 反复切换 **0 帧**缺表头。
- 已知外观差异（未修，用户已确认不影响使用）：Canvas 网格底色取 `--background`（xcode 主题 `rgb(250,252,255)`），DOM 网格根是上游写死的白色，所以最后一列右侧空白区在 Canvas 下带一层约 5/255 的浅灰，看起来像表头多延伸一截。

### HarmonyOS 6 原生代码执行（agent 驱动，2026-09-14 实测）

- **应用沙箱里"下载来的 ELF"不能执行**，两级拦截：
  1. 无代码签名 → `execve` 返回 `EACCES`（hilog：`code_protect/BSS … node: CheckSigned, ret: 1017604106`，伴随 `FillElfModuleJson: empty module.json buf`）；
  2. 即使签名（自签名或**用应用自己的证书签**都一样），**应用域仍返回 `EPERM`** —— 拒绝点是 BinSec `LoadBinCtrlAndManage`「parent process cannot load this binary」（`binaryType: 5, isCustomSandbox: 0, isAllowExt: 0`），**与签名身份无关**（A/B/C 对照见 `docs/ohos-agent-exec-denied.md` §18）。
- **能跑原生代码的路**：**native child process**（本仓库已用，见 P0'）是唯一不需要华为侧授权的；**HNP** 是平台正路但要签名链路（本机 hvigor 插件无 hnp 逻辑、SDK 无 `hnpcli`）；`ohos.permission.CUSTOM_SANDBOX`（动态沙箱）是唯一可能让应用**直接 exec 沙箱 ELF** 的权限，未验证。`DISABLE_CODE_MEMORY_PROTECTION` 只关 XPM 代码完整性保护，与上面的二进制管控无关。
- 所以：**agent 类驱动必须随 HAP 分发（NCP）**；JDBC/JRE 仍不可行（沙箱 `.so` 不能 dlopen + glibc JRE）。详见 `docs/ohos-agent-exec-denied.md`。

### JIT / 可执行内存权限（2026-09-16 查证官方文档 + 真机实测）

**背景**：应用域默认**不能造可执行内存**。真机实测（子进程里跑 `jvm_probe.c`）：`mmap(PROT_READ|PROT_WRITE|PROT_EXEC)`、匿名 `mmap(PROT_READ|PROT_EXEC)`、`mprotect(→RWX)`、`mprotect(→RX)` 全部 `EINVAL(22)`，而普通 `mmap(RW)` 正常。所以任何 JIT（JVM/JS 引擎/自研 JIT）默认都起不来。

**权限名称与级别**（`sdk/default/openharmony/toolchains/lib/PermissionDefinitions.json`，均为 `grantMode: system_grant` + `availableLevel: system_basic` + `provisionEnable: true` + `isKernelEffect: true`）：

| 权限 | since | 用途 | 自动签名可代申请 |
|---|---|---|---|
| `ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY` | 14 | 申请可写可执行内存（**通用 JIT / JVM 要的就是它**） | ✅ 5.0.3 Release 起 |
| `ohos.permission.kernel.ALLOW_EXECUTABLE_FORT_MEMORY` | 14 | 系统 JS 引擎申请 `MAP_FORT` 匿名可执行内存 | ✅ 5.0.3 Release 起 |
| `ohos.permission.kernel.DISABLE_CODE_MEMORY_PROTECTION` | 14 | 关闭系统代码内存保护 | ✅ 5.0.3 Release 起 |
| `ohos.permission.kernel.ALLOW_USE_JITFORT_INTERFACE` | 16 | 新的 JITFort 接口 | ❌ 不在列表，须 AGC 人工申请 |

**两条申请路径（[FAQ faqs-appgallery-78](https://developer.huawei.com/consumer/cn/doc/harmonyos-faqs/faqs-appgallery-78) 原文）**：

1. **DevEco Studio 自动签名代申请（调试阶段推荐）**："在自动签名的过程中，将由 DevEco Studio 完成向 AGC 申请受限权限的步骤，开发者可直接使用。"
   - 步骤：`module.json5` 的 `requestPermissions` 声明权限 → 连真机 → `File > Project Structure > Project > Signing Configs` → 勾 **"Associate with registered application" / "Automatically generate signature"**（未登录先 Sign In）→ （可选）添加 ACL 权限信息（[自动签名](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing-auto)，"自动签名支持的ACL权限"清单见该文 §section5301916183411）。
   - 前置条件：DevEco Studio ≥ 6.0.0 Beta5 才有"关联注册应用的自动签名"（6.1.1 Beta1 起全球可用）；**应用须已在 AGC 注册且 bundle name 一致**；连真机（或把真机注册到 AGC）；本机时间须与北京时间一致。
2. **AGC 试用调试 Profile（审核等待期用）**：提交 ACL 申请后可创建试用调试 Profile，**有效期 5 天**、每应用最多 5 个；把 ACL 权限加进 Profile、下载后手动签名。正式流程则是 AGC「项目设置 → ACL 权限」申请（约 1 个工作日）→ 申请 debug/release Profile 时勾选「受限ACL权限（HarmonyOS API9及以上）」（[受限 ACL 权限申请](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/declare-permissions-in-acl)）。

**四条硬约束（都踩过或原文明确）**：

1. **声明了权限但没有权限证书 → 安装直接失败**：实测 `code:9568289 install failed due to grant request permissions failed. PermissionName: ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`（[JSVM 申请JIT权限指导](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/jsvm-apply-jit-profile) 的"适配注意事项"也这么写）。**所以千万别把权限留在 `module.json5` 里提交**，本仓库已还原。
2. 本机（纯 CLI：hvigor + `~/Documents/ohos/config/` 里那份 `"acls":{"allowed-acls":[]}` 的 debug profile，无 DevEco GUI、无登录账号）**跑不了自动签名**；要启用得在有 DevEco Studio 的机器上登录勾自动签名，或从 AGC 下载带 ACL 的 profile 替换本机 profile。
   - **2026-09-16 更新（已有实证）**：本机现已装 DevEco Studio 并用它自动签名成功，新 profile 的 `allowed-acls` 从 `[]` 变成 `["ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY"]` —— 即**自动签名确实会代为向 AGC 申请受限 ACL**，不是只换个 bundle name。JIT 这几个权限走同一条路即可（把权限写进 `module.json5` → DevEco 自动签名 → 装真机验证 → **验证完把权限声明撤掉**，见约束 1）；完整步骤见「改包名（bundleName）」的「本次实操记录」。
3. **坚盾守护模式开启期间，系统在全局范围内禁用 JIT，包括已获 ACL 权限的特权应用**（原文）。
4. 部分 ACL 权限**只对受邀应用开放**，非受邀应用在 AGC 上申请不到。

**对本项目的意义**：JIT 权限只解决"能不能造可执行内存"；它**不能**解决 §15 的另外两条（沙箱里的 .so 一律 `dlopen` 不了、dbx 下载的 JRE 是 glibc 而 OHOS 只有 musl），所以 JDBC 走进程内 JVM 依然不可行。将来若要做 JIT 类功能（JVM / 自研引擎），按上面路径 1 走即可，不必等功能开发完再申请。

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
- 每次发版先把 `AppScope/app.json5` 的 `versionName`/`versionCode` 升到与 release 版本一致（当前基线 1.3.3 ↔ 1003003；1.3.2 ↔ 1003002 是上一个已发布版本），再构建并替换 release 资产，保证未签名 hap 的包内版本与 release tag 对齐（2026-08-28、2026-09-10、2026-09-13 均按此流程）。
- **tag 与 release 一起建**：`gh release create <tag> --target main --latest`（本次 `v1.3.3-dbx0.6.9` → 版本提交 `deab2fd`）；建完在父仓库 `git fetch --tags origin` 把 tag 同步到本地，并用 `gh release view --json assets` 核对线上 digest 与本地 `sha256sum` 一致。
- **核实包内版本**（打包后必查，`pack.info` 是 `version` 嵌套结构，不是平铺字段）：
  ```bash
  unzip -o -q <hap> pack.info module.json -d .tmp/hapcheck
  python3 -c "import json;d=json.load(open('.tmp/hapcheck/pack.info'));print(d['summary']['app'])"
  # → {'bundleName': 'io.github.getz110.dbx', 'version': {'code': 1003003, 'name': '1.3.3'}}
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
hdc shell aa force-stop io.github.getz110.dbx; sleep 1
hdc shell hilog -r
(hdc hilog > .tmp/perf.log &) ; sleep 2
hdc shell aa start -a EntryAbility -b io.github.getz110.dbx
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

冷缓存场景用 `hdc shell "bm clean -c -n io.github.getz110.dbx"` 制造（**只清缓存、不动已保存的连接**）。

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
