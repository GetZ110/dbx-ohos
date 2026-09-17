# HarmonyOS 上用不了 Oracle/agent 类驱动：排查、尝试与已跑通的方案（报告）

> 记录时间：2026-09-17 00:55（CST）
> 设备：HUAWEI MateBook Pro / HAD-W32（HarmonyOS 6，HongMeng Kernel，targetSdk 6.1.0(23)）
> 主机与设备为同一台机器（`hdc tconn 127.0.0.1:43817`），因此可以用 `curl 127.0.0.1:4224` 直接驱动应用内的 `dbx-web`。
> 项目版本：dbx-ohos 1.3.3 / 上游 dbx 0.6.9（`io.github.getz110.dbx`）。
> 详细证据链与历史实验：`docs/ohos-agent-exec-denied.md`（§1–§16）。

---

## 0. 结论速览（TL;DR）

| 问题 | 结论 |
|---|---|
| 报错 `Failed to spawn agent process …/oracle/agent: Permission denied (os error 13)` 是什么？ | 不是文件权限位问题，是 **HarmonyOS 6 的 BinSec/`code_protect` 强制 ELF 代码签名**：沙箱里"下载来的、不含应用身份的 ELF"不允许 `execve` |
| 有没有可行路线？ | **有**。平台正路是 **native child process**（`OH_Ability_StartNativeChildProcess`）：appspawn 直接 `dlopen` HAP `libs/` 里的 `.so`，不经过 `execve`，**不需要任何华为证书、签名或受限 ACL** |
| 实际验证了吗？ | 已验证。把 oracle agent 编成 `libdbx_agent_oracle.so`（Go c-shared）打进 HAP，应用侧改走 NCP 传输；真机上 Oracle 连接从 `Permission denied` 变成 **`dial tcp 127.0.0.1:1521: connect: connection refused`**（= agent 真的跑起来并去连数据库了） |
| 代价 | `.so` 重建一次约 46 分钟（LTO）；HAP 从 69MB → 90MB（oracle agent 压缩后 20.9MB）；每个要支持的驱动都要单独编一份 c-shared |
| 仍不可行 | **JDBC/JRE 类驱动**（沙箱 `.so` 不能 `dlopen` + JRE 是 glibc + JIT 内存受限）；**HNP** 路线（缺签名材料与工具链，见 §3）；其余 13 个 Go agent 需要机械铺开 |

---

## 1. 现象与复现（改之前）

设备已装 1.3.3，Oracle 驱动可正常下载安装：

```bash
curl -s -X POST http://127.0.0.1:4224/api/agents/install \
     -H 'content-type: application/json' -d '{"dbType":"oracle"}'
# → {"ok":true}   （6.6s，drivers/oracle/agent 落盘，版本 0.1.62）

curl -s -X POST http://127.0.0.1:4224/api/connection/test \
     -H 'content-type: application/json' \
     -d '{"config":{"id":"t1","name":"t1","db_type":"oracle","host":"127.0.0.1",
                    "port":1521,"username":"system","password":"x","database":"ORCL"}}'
```

返回（与用户报的完全一致）：

```json
{"version":1,"code":"DBX-LEGACY-0001","messageKey":"backendErrors.legacy",
 "source":"legacyBackend","operationOutcome":"unknown",
 "detail":"Failed to spawn agent process /data/storage/el2/base/haps/entry/files/dbx-data/agents/drivers/oracle/agent: Permission denied (os error 13)"}
```

同期 hilog 里的判定节点：

```
09-16 23:53:56.723 W C05610/code_protect/BSS: [BinSec][svc:node_task][ExecuteTemplate]:node based task failed. node: CheckSigned, ret: 1017604106
09-16 23:53:56.723 W C05610/code_protect/BSS: [BinSec][svc:bin_common][FillPermissionSection]:permission section not exist
09-16 23:53:56.723 W C05610/code_protect/BSS: [BinSec][svc:bin_common][FillElfModuleJson]:empty module.json buf. maybe the permission section is empty
```

要点：驱动文件本身落盘是 `0o755`（`repair_native_agent_execute_permission()` 就是干这个的），**再补执行位也没用**；内核在 `execve` 路径上先做代码签名检查。

---

## 2. 根因：应用沙箱不允许执行"外来 ELF"

两级拦截（都有真机实验，见 `docs/ohos-agent-exec-denied.md` §3）：

1. **没有 `.codesign`** → `execve` 直接 `EACCES`（`CheckSigned, ret: 1017604106`）。
2. **用 `binary-sign-tool -selfSign 1` 自签名后**：普通用户/开发终端域能跑（agent 正常回 `{"ready":true}`），但**由应用进程 spawn 时仍是 `EPERM`** —— 应用域还要求代码身份属于本应用（随 HAP 安装、由应用证书授权）。

所以"下载后自己签名"不是新路：签名解决第 1 层，第 2 层要的是**应用身份**，应用侧没有公开的"运行时签名/授权"入口。

---

## 3. 探索过的所有路线（含结论与证据）

| # | 路线 | 做法 | 结论 | 关键证据 |
|---|---|---|---|---|
| **A** | **HNP**（HarmonyOS Native Package，随 HAP 分发授权 ELF） | `hnp.json` + `bin/agent` 打 zip → `"hnpPackages"` | ❌ 本机装不上 | `ohos_packing_tool` 要求 HNP 带华为二进制证书扩展的 `signMap`；本机 hvigor 插件不带 hnp 逻辑、SDK 无 `hnpcli`；当前签名材料 `allowed-acls: []`，装机报 `9568289`。详见 §9 |
| **A′** | 把 agent 放进 HAP `libs/` 再 `execve` | 驱动文件直接随 HAP 进 `libs/arm64-v8a/` | ❌ 同样执行不了 | 装后是 `0644`（无 x 位）；即使补位也是 BinSec 那一层。详见 §12 |
| **B** | 受限权限 + 运行时自签名（`DISABLE_CODE_MEMORY_PROTECTION` / `ALLOW_WRITABLE_CODE_MEMORY`） | `module.json5` 声明 ACL | ❌ 装不上 | `code:9568289 install failed due to grant request permissions failed`（profile ACL 为空）；调试期可走 DevEco 自动签名代申请，但本机无法替代。详见 §10、§15.2 |
| **C** | 暂不支持，文档写明限制 | — | 备选 | — |
| **D** | **native child process**（appspawn `dlopen` HAP `libs/` 的 `.so`） | 子进程入口 `void Main(NativeChildProcess_Args)`，fd 传 socketpair | ✅ **可行，且已打通 oracle** | 本轮实测，见 §5/§6 |
| **E** | JDBC 走进程内 JVM（`dlopen(libjvm.so)` + `JNI_CreateJavaVM`） | 在 NCP 子进程里起 JVM | ❌ 三重卡死 | ① 沙箱 `.so` `dlopen` 返回 `EINVAL`（只有 HAP `libs/` 能 dlopen）；② JIT 默认被禁（`mmap RWX`/`mprotect RX` 全 `EINVAL`，需受限 ACL）；③ 官方 JRE 是 **glibc**，OHOS 只有 musl。详见 §15 |
| **D′** | 进程内 `dlopen` agent（不开子进程） | 在主进程 dlopen `libs/` 的 agent `.so` | ⚪ 未采用（D 更干净） | §15.1 已证明 HAP `libs/` 的 `.so` 可以 dlopen；但同一个 Go runtime 塞进主进程会和 tokio/信号/多实例耦合，子进程隔离更稳 |

**平台正路只有 D（和 A 的变体）**：这两条都绕开 `execve`。A 需要华为侧签名材料，D 不需要。

---

## 4. 方案 D 的架构

```
应用主进程 (uid 20020235, hap 域)
 ├─ dbx-web (libdbx_ohos.so, Rust)          ← NAPI，跑 stdio JSON-RPC 客户端
 │    └─ OH_Ability_StartNativeChildProcess("libdbx_agent_oracle.so:Main", fdList=[socketpair])
 │         │
 │         └─ socketpair ──────────────────────────────┐
 │                                                     │
 └─ appspawn 创建的子进程 (同一应用身份)                │
      io.github.getz110.dbx:Native_libdbx_agent_oracle0
      ├─ dlopen(/data/storage/el1/bundle/libs/arm64/libdbx_agent_oracle.so)  ← 不需要 x 位/签名
      ├─ dlsym("Main") → Main(args)
      └─ shim: 把 fdList 里的 fd dup2 到 0/1 → 跑原有 stdin/stdout JSON-RPC 循环
```

关键点：
- 子进程以**应用身份**运行（能访问自己的沙箱/网络），与 agent 需要的环境一致。
- 传输层复用现有的 **stdin/stdout JSON-RPC 2.0** 协议，agent 源码主体不用改，只在 `main()` 外多一个 `//export` 入口 + 一个 C shim。
- 父进程用 `socketpair`（`UnixStream::pair()`）+ fdList 传 fd → 双向通道；不用管道，因为 appspawn 子进程不继承父进程 stdio。
- 子进程在 `Main()` 返回后由系统回收；关闭 socket 使 agent 的 stdin 读到 EOF → 自行退出（oracle agent 的 `runStdioAgent()` 会在 `scanner.Scan()` 结束后返回）。

> Go c-shared 在 **musl** 上还有两处必须打的运行时补丁（initial-exec TLS + `_rt0_arm64_lib` 拿不到 argc/argv），否则连 `dlopen` 都过不去。补丁由 `harmony/tools/go_ohos_overlay.py` 生成 overlay，不碰全局 GOROOT；详见 `docs/ohos-agent-exec-denied.md` §14。

---

## 5. 本轮代码改动

### 5.1 新增：OHOS native child process 传输层

| 文件 | 改动 |
|---|---|
| `crates/dbx-core/src/db/agent_ncp.rs`（新增） | `#[link(name="child_process")]` 调 `OH_Ability_StartNativeChildProcess` / `OH_Ability_KillChildProcess`；建 `socketpair`、把子端放进 `fdList`；`NcpChild` 实现 `id/kill/wait/try_wait`（appspawn 子进程不是本进程的 POSIX 子进程，用 `shutdown` + `KillChildProcess` 而不是 `waitpid`） |
| `crates/dbx-core/src/db/mod.rs` | 注册 `pub mod agent_ncp;` |
| `crates/dbx-core/src/db/agent_driver.rs` | 新增 `AgentProcess`（`Child` / `Ncp`）与 `SpawnedAgent`；把 `AgentRuntimeClient` 与 `AgentDriverClient` 的 `child`/`stdin`/`stdout` 从具体 `Child*` 类型改成枚举 + `Box<dyn Read/Write + Send>`；新增 `spawn_agent_io()`（OHOS 上优先走 NCP，其余平台完全走原路径）；`AgentLaunchSpec` 加 `ncp_entry` 字段与 `AgentLaunchSpec::ncp()` |
| `crates/dbx-core/src/agent_manager.rs` | OHOS 专属 `ohos_bundled_agent_launch(driver_key)`：把 `oracle` 映射到 `libdbx_agent_oracle.so:Main`，在 `resolve_agent_launch_spec_with_extra_args()` 最前面短路返回 |

设计上**不影响非 OHOS 目标**：所有 NCP 代码都在 `#[cfg(target_env = "ohos")]` 里，桌面/服务器仍走原来的 `Child` + 管道。

### 5.2 已有的 agent 侧脚手架（上轮留下，本轮复用）

- `agents/drivers/oracle-go/main.go`：`main()` → `runStdioAgent()`。
- `agents/drivers/oracle-go/ohos_ncp.go`（`//go:build ohos_ncp`）：`//export dbxAgentRun`。
- `agents/drivers/oracle-go/ohos_ncp_shim.c`：导出 `Main(NativeChildProcess_Args)`，把 fdList 的 fd `dup2` 到 0/1；同时提供 musl emutls 的 `dbxLoadG/dbxSaveG`。
- `harmony/tools/build_agent_cshared.sh` + `go_ohos_overlay.py`：一键把 agent 编成 OHOS c-shared `.so` 放进 `entry/libs/arm64-v8a/`。

### 5.3 构建产物

```
harmony/dbxohos/entry/libs/arm64-v8a/libdbx_agent_oracle.so   28,360,272 B
    ├─ NEEDED: libc.so（只有 musl libc，无 glibc 依赖）
    ├─ 无 R_AARCH64_TLS_* 重定位（overlay 补丁生效）
    └─ 导出 Main / dbxAgentRun / dbxLoadG / dbxSaveG
harmony/dbxohos/entry/libs/arm64-v8a/libdbx_ohos.so           46,507,712 B
    └─ NEEDED 里出现 libchild_process.so；UND OH_Ability_StartNativeChildProcess
```

HAP：`entry-default-signed.hap` = 90,147,161 B（`libs/` 里两个 `.so`，agent 压缩后 20,924,088 B）。

---

## 6. 真机实测（同一台设备、同一接口，只差一次安装）

安装新 HAP（`hdc install -r`，1.4s）→ 启动应用 → 同一个请求：

### 6.1 修复前

```json
{"code":"DBX-LEGACY-0001","source":"legacyBackend",
 "detail":"Failed to spawn agent process /data/storage/el2/base/haps/entry/files/dbx-data/agents/drivers/oracle/agent: Permission denied (os error 13)"}
```

### 6.2 修复后

```json
{"code":"DBX-JDBC-9001","source":"jdbcAgentLegacy",
 "detail":"dial tcp 127.0.0.1:1521: connect: connection refused"}
```

耗时 **0.228s**（子进程起来 → ready → handshake → open_session → go-ora 拨号 → 失败返回）。

这条 `connection refused` 是**好消息**：它说明
1. appspawn 成功 `dlopen` 并运行了 `libdbx_agent_oracle.so`；
2. agent 输出了 `{"ready":true}`；
3. multi-session v2 **handshake 通过**；
4. `open_session` 把连接参数交给了 go-ora，go-ora 真的去 dial `127.0.0.1:1521`（本机没有 Oracle 监听，所以被拒）。
   换句话说：**除了"没有数据库可连"，整条驱动链路已经通了。**

### 6.3 旁证

进程列表（父子都是应用身份 `20020235`）：

```
20020235  48048  ...  io.github.getz110.dbx
20020235  48527  48013 ... io.github.getz110.dbx:Native_libdbx_agent_oracle0
```

子进程的沙箱是按本应用挂载的（hilog，tag 即子进程名）：

```
E C02C11/bx:Native_libdbx_agent_oracle0/APPSPAWN: [sandbox_core.cpp:737]mkdir /data/service/el1/public/... failed, errno 13
W C02C11/bx:Native_libdbx_agent_oracle0/APPSPAWN: errno:13 bind mount /data/app/el1/bundle/100/hnp/io.github.getz110.dbx to /mnt/sandbox/100/io.github.getz110.dbx/data/app
E C05A06/bx:Native_libdbx_agent_oracle0/CODE_SIGN: [XpmIoctl]:Ioctl cmd 40407808 failed: Permission denied (ignore)
E C05A06/bx:Native_libdbx_agent_oracle0/CODE_SIGN: [XpmIoctl]:Ioctl cmd 40087803 failed: Permission denied (ignore)
```

> `CODE_SIGN` 那两条是 BinSec 在子进程里尝试 ioctl 被拒，**被系统标为 `(ignore)`**，不影响运行（否则我们拿不到 `connection refused`）。这也说明：即使绕开 `execve`，代码内存保护仍在，但 `dlopen` 一条路是放行的。

失败后运行时自动回收：`GET /api/agents/runtime` 显示 `agent:oracle status=stopped`，子进程已退出，**没有残留/僵尸**。

### 6.4 启动回归（已补验：12/12 PASS）

- 设备锁屏期间 `aa start` 会报 `10106102 The device screen is locked during the application launch`，无法拉起 Ability；**解锁后补跑成功**。
- `./harmony/tools/startup_smoke.sh --mode warm`（hvigor + `libdbx_ohos.so` + 28MB agent `.so` 全在包内）：

  ```
  PASS fingerprint copy                          skipped 25ms
  PASS Local service ready                       121ms        < 200ms
  PASS server ready (health)                     attempt 2    N ≤ 3
  PASS server 绑回环                              127.0.0.1
  PASS frontend modules loaded                   359ms        warm ≤ 400ms
  PASS PageFirstContentfulPaint                  1216ms       warm ≤ 1300ms
  PASS Succeeded in loading                      1 次
  PASS Index about to appear                     1 次
  PASS 禁止: transformCallback                   0 条
  PASS 禁止: Failed to apply UI scale            0 条
  PASS 禁止: Cannot read properties of undefined  0 条
  PASS vue mounted                               出现
  → 结果: 全部通过（EXIT=0）
  ```

- 解锁后重跑 Oracle 请求仍是 `dial tcp 127.0.0.1:1521: connect: connection refused`，子进程 `io.github.getz110.dbx:Native_libdbx_agent_oracle0`（pid 49794，uid 20020235）稳定复现。
  （注：装机后**第一次** warm 冒烟曾出现 `modules loaded` 1020ms / FCP 未抓到，紧接着重跑即 368ms / 1177ms 全过 —— 属装机后首启的系统抖动，不是回归。）

### 6.5 驱动运行时的显式启停（第二次补验：`AgentDriverClient` 也已接入 NCP）

第一次测 `/api/agents/runtime/restart` 时暴露了一个缺口：**驱动管理器的"运行/重启"按钮走的是另一条 spawn 路径**（`AgentDriverClient`，即 `spawn_client_for_key`），当时还没接入 NCP，返回：

```
Failed to spawn agent process libdbx_agent_oracle.so:Main: No such file or directory (os error 2)
```

把 `AgentDriverClient` 也改成用 `spawn_agent_io()` 后（`AgentProcess` 抽象对两套客户端都生效），重新打包验证：

| 步骤 | 结果 |
|---|---|
| `POST /api/agents/runtime/restart {"runtimeId":"agent:oracle"}` | `{"ok":true}` |
| `GET /api/agents/runtime` | `running_count=1`，`agent:oracle running pid=53176` |
| `ps` | `io.github.getz110.dbx:Native_libdbx_agent_oracle0`（pid 53176，父 53175，uid 20020235） |
| `POST /api/agents/runtime/stop {"runtimeId":"agent:oracle"}` | `{"ok":true}` |
| `GET /api/agents/runtime` / `ps` | `stopped`，pid=None，**子进程已退出、无残留** |

即 `NcpChild::kill()`（`shutdown` socket + `OH_Ability_KillChildProcess`）与 reaper 语义在真机上成立。

---

## 7. 官方文档依据

- **native child process（C/C++）开发指导**：入口 `Main(NativeChildProcess_Args)`、`entryParams` + `fdList` 传参、**"入口函数返回后子进程自动退出"** —— [Creating Native Child Processes (C/C++)](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/capi_nativechildprocess_development_guideline)、[子进程开发指导（C/C++）](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/capi-nativechildprocess-development-guideline)。
- **API 头文件**（本机 NDK `AbilityKit/native_child_process.h`，即最权威的本地副本）：
  - `OH_Ability_StartNativeChildProcess(entry, args, options, &pid)`，since 13；错误码含 `NCP_ERR_NOT_SUPPORTED` / `NCP_ERR_ALREADY_IN_CHILD` / `NCP_ERR_MAX_CHILD_PROCESSES_REACHED`。
  - `OH_Ability_KillChildProcess(pid)`，since 22（本机 API 23 可用）。
  - `OH_Ability_RegisterNativeChildProcessExitCallback`：**只有这三条 API 启动的子进程退出时才会触发**，回调查独立线程执行。
- **受限权限（JIT/代码内存）**：`ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`、`ALLOW_EXECUTABLE_FORT_MEMORY`、`DISABLE_CODE_MEMORY_PROTECTION`，均为 `system_basic` + `provisionEnable`，调试期可由 **DevEco 自动签名代申请**；但声明了权限而 profile 没有 ACL 会**直接装不上**（`9568289`）。见 [FAQ：受限权限审批前调试方法](https://developer.huawei.com/consumer/cn/doc/harmonyos-faqs/faqs-appgallery-78)、[自动签名](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing-auto)。

---

## 8. 结论与建议

1. **Oracle 已可在 HarmonyOS 上连**（方案 D）。从"下载驱动 → 点连接"这条产品路径看，剩下的只是把传输层接进产品 UI：内置驱动应显示"已安装（内置）+ 版本"，并禁用"卸载/升级"。
2. **成本主要在 `.so` 重建**（LTO release 一次约 46 分钟）与 **HAP 体积**（每个 agent +20~28MB 压缩前）。建议：
   - 短期只内置 **oracle**（HAP 69 → 90MB）；
   - 其余 13 个 Go agent 机械铺开（`hive` 一个产物覆盖 hive/kyuubi/impala），但先评估体积，或走 **feature HAP 按需安装**；
   - `duckdb`/`tdengine` 是 Rust agent，可做 cdylib 导出 `Main`，没有 Go 的 TLS/argv 问题。
3. **JDBC/JRE 类驱动仍不可行**（沙箱 `.so` 不能 `dlopen` + glibc JRE + JIT 受限）；要做得先有 OHOS/musl 版 OpenJDK，属于长期项。
4. **上游同步成本**：改动集中在 `dbx-core` 的 `agent_driver.rs` / `agent_manager.rs`（上游高频改动区），已尽量用 `#[cfg(target_env = "ohos")]` 隔离与短路；同步时按 AGENTS.md 的「保住本地补丁」清单核对。

---

## 9. 复现步骤（下次直接跑）

```bash
# 0) 前置：设备在线
hdc list targets                     # 本机有设备就直接用，不要再 tconn

# 1) 编译 oracle agent c-shared（几秒）
./harmony/tools/build_agent_cshared.sh oracle-go libdbx_agent_oracle.so
#    自检：无 TLS 重定位、导出 Main
NDK=/storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_1/native
$NDK/llvm/bin/llvm-readelf -r harmony/dbxohos/entry/libs/arm64-v8a/libdbx_agent_oracle.so | grep -i TLS   # 应为空

# 2) 重建 Rust .so（约 46 分钟）
cd upstream/dbx
OHOS_NDK_HOME=$NDK cargo build --release -p dbx-ohos
cp target/release/libdbx_ohos.so ../../harmony/dbxohos/entry/libs/arm64-v8a/

# 3) 打包 + 装机
export DEVECO_SDK_HOME=/storage/Users/currentUser/deveco_tools/sdk
cd harmony/dbxohos
node /storage/Users/currentUser/deveco_tools/hvigor/bin/hvigorw.js \
     --mode module -p product=default --no-daemon assembleHap
hdc -t 127.0.0.1:43817 install -r \
     entry/build/default/outputs/default/entry-default-signed.hap

# 4) 驱动应用内接口验证（需要设备已解锁）
hdc shell aa force-stop io.github.getz110.dbx
hdc shell aa start -a EntryAbility -b io.github.getz110.dbx
curl -s -X POST http://127.0.0.1:4224/api/connection/test -H 'content-type: application/json' \
     -d '{"config":{"id":"t1","name":"t1","db_type":"oracle","host":"127.0.0.1","port":1521,
                    "username":"system","password":"x","database":"ORCL","connect_timeout_secs":5}}'
# 期望：detail = "dial tcp 127.0.0.1:1521: connect: connection refused"（不再是 Permission denied）
```

---

## 附录 A：本轮"失败/被证伪"路线的原始证据（摘要）

- **HNP 装不上**（§9）：`ohos_packing_tool` 的 HNP 打包要求带证书扩展的 `signMap`；本机 hvigor 插件无 hnp 代码、SDK 无 `hnpcli`；profile `allowed-acls: []`。
- **HAP `libs/` 里的 ELF 直接 exec 不行**（§12）：装后 `0644`，`execve` → `EACCES`。
- **受限 ACL 声明但 profile 没有 → 装不上**（§10/§15.2）：`code:9568289 install failed due to grant request permissions failed. PermissionName: ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`。
- **沙箱 `.so` 无法 dlopen**（§15.1）：`RTLD_NOW`/`RTLD_LAZY` 都是 `EINVAL`；同一文件放 HAP `libs/` 就 `OK`。
- **JIT 内存默认全禁**（§15.2）：`mmap(RWX)`、匿名 `mmap(RX)`、`mprotect(→RWX)`、`mprotect(→RX)` 全 `EINVAL(22)`；普通 `mmap(RW)` 正常。
- **官方 JRE 是 glibc**（§15.3）：`libjvm.so` 依赖 `libc.so.6` / `ld-linux-aarch64.so.1`，OHOS 只有 `ld-musl-aarch64.so.1`。

## 附录 B：Go c-shared 在 musl 上的两处补丁（否则方案 D 不成立）

1. **initial-exec TLS**：`runtime.load_g/save_g` 访问 `runtime.tls_g`（IE 模型），musl 只给 dlopen 模块分配动态 TLS → 重定位失败。补丁改成调 C 侧 `static __thread void *dbx_go_g`（emutls）。
2. **`_rt0_arm64_lib` 拿不到 argc/argv**：musl 调 `init_array` 时不传（实测 `x0=0x100000001`、`x1` 是垃圾），Go 扫垃圾 argv 直接 SIGSEGV。补丁换成 asm 自带的合法骨架 `argv=["dbx-agent",NULL] envp=[NULL] auxv=[AT_NULL,0]`；Go 的 `sysargs` 在 auxv 为空时会回退读 `/proc/self/auxv`，所以页大小/HWCAP 不丢。

落地：`harmony/tools/go_ohos_overlay.py` 生成 `-overlay`（对 `.s` 生效，不碰 GOROOT；匹配次数不为 1 就报错退出，Go 升级后能第一时间发现补丁点变了）。
