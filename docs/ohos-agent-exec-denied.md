# Oracle（及所有 agent 类驱动）在 HarmonyOS 上无法启动：BinSec 代码签名强制

> 记录时间：2026-09-14；设备 HUAWEI MateBook Pro（HarmonyOS 6，HongMeng Kernel 1.13.0，targetSdk 6.1.0(23)），
> 主机与设备为同一台机器（`hdc tconn 127.0.0.1:43817`）。dbx-ohos 1.3.3 / 上游 dbx 0.6.9。
>
> 签名方法/已知限制的原始出处：[hu60 论坛《使用 CodeArts IDE 或 DevBox 的 binary-sign-tool 命令为任意 ELF 签名》](https://hu60.cn/q.php/bbs.topic.107186.html)；
> 自签名开源实现（0BSD，可与官方工具换用）：[`SwimmingTiger/ohos-bst-light`](https://github.com/SwimmingTiger/ohos-bst-light)（原 `hqzing/ohos-bst-light`）。

## 1. 现象

连接 Oracle 时失败：

```
Failed to spawn agent process
  /data/storage/el2/base/haps/entry/files/dbx-data/agents/drivers/oracle/agent:
  Permission denied (os error 13)
```

`Permission denied (EACCES)` 来自 `dbx-core/src/db/agent_driver.rs` 的 `spawn_agent_process()`。
驱动文件本身已按 `DriverArtifactKind::Native` 落盘为 `0o755`，所以**不是文件权限位的问题**。

## 2. 根因：HarmonyOS 6 强制 ELF 代码签名（BinSec / code_protect）

HarmonyOS 6 起，可执行 ELF 必须带合法**代码签名**（`.codesign` section，配合 fs-verity/owner 校验）才能 `execve`。
dbx 的 agent 是**运行时下载**到应用沙箱的第三方 ELF，没有签名 → 内核/`code_protect` 拒绝执行。
hilog 里可直接看到判定节点：

```
C05610/code_protect/BSS: [BinSec][svc:node_task][ExecuteTemplate]:node based task failed. node: CheckSigned, ret: 1017604106
C05610/code_protect/BSS: [BinSec][svc:bin_common][FillElfModuleJson]:empty module.json buf. maybe the permission section is empty
```

## 3. 在真机上验证到的事实链

| # | 实验 | 结果 |
|---|---|---|
| 1 | 把上游 `dbx-agent-oracle-0.1.61-linux-aarch64`（静态 Go ELF，18,677,912 B）放到 `/data/local/tmp` 执行 | `exec: Permission denied`，exit 126 |
| 2 | 用 `binary-sign-tool sign -inFile X -outFile X -selfSign 1` 自签名后再执行 | 仍 `Permission denied`（hdcd/shell 域，`u:r:sh:s0`） |
| 3 | **同一条已签名 ELF 由普通用户域执行**（host uid 20020102，Harmonybrew 域） | **成功**：`{"ready":true}`（第一行是 agent 的 ready 帧） |
| 4 | 用 `/api/agents/import-driver` 把**已自签名**的 agent 装进 dbx 沙箱，再 `POST /api/agents/runtime/restart {"runtimeId":"agent:oracle"}` | 错误从 `Permission denied (os error 13)` 变为 **`Operation not permitted (os error 1)`** |

结论：

* 未签名 ELF = `EACCES`（第 1 步）；自签名可让"普通用户/开发终端"域执行（第 3 步）。
* 但**应用沙箱不允许执行自签名 ELF**：dbx 进程（uid 20020222，hap 域）拿到的是 `EPERM`（第 4 步）。
  也就是说签名只解决 `code_protect` 的 `CheckSigned`，应用域还有一层"只允许运行随 HAP 安装、由应用证书授权的原生代码"的策略。
* 这也解释了平台为何提供 **native child process / HNP**：应用进程本身不是"任意 exec"的沙箱。

### 3.1 常见误解："下载后自行签名再安装不就行了？"

**不行，第 4 步就是这个实验**（而且是"在同一台机器上签好名再装进沙箱"，不是跨机预签）。两处澄清：

* **不是"机器不对"**：早先流传"自签名绑定机器"，但该说法已被原始出处评论区更正（2026-08-19），且可核对：公开实现 `selfsign.rs`/`selfsign.c` 的签名只由 ELF 内容推导（SHA-256 + 按页 Merkle root + descriptor），**不读取任何机器信息**（无 `/proc`、无 env、无时间/随机数）。本次失败也发生在**同一台机器**上。~~真正的瓶颈是签名身份：自签名的 `.codesign` 是"自洽占位"，不携带应用身份；应用进程只信任随 HAP 安装、由应用证书授权的代码。~~ **2026-09-17 更正：不是签名身份的问题。** 见 §18 —— 用**应用自己的证书**（华为签发的开发证书 + profile，`binary-sign-tool` localSign 模式）重新签名后，应用域**仍然 `EPERM`**，拒绝点是 BinSec 的 `LoadBinCtrlAndManage`（二进制管控），与证书链/ownerId 无关。
* **应用侧没有"运行时签名"的正规入口**：`SignLocalCode` / `EnforceCodeSignForFile` / `InitLocalCertificate` 只存在于 OpenHarmony `security_code_signature` 的 **inner API**（服务层，供 AOT 编译产物等系统场景使用）。本机 SDK 里没有对应的公开接口：`ets/api/` 无 sign/verify 模块，`native/` sysroot 也没有 `code_sign*` 头文件。应用也拿不到自己的签名私钥（在构建侧的证书/keystore 里）。

所以"自行签名"不是方案 A 之外的新路，它**就是方案 B 的核心步骤**，缺的另一半是 `DISABLE_CODE_MEMORY_PROTECTION`（关掉应用域的代码内存保护检查）；加权限后是否接受自签名仍未验证，见 B3 的最小实验。若失败（即 EPERM 来自 SELinux exec 标签而非代码保护检查），则只剩 A（HNP）或 C。

### 3.2 常见误解："把签名后的驱动放到普通用户域里用不就行了？"

不行：

* **安全域跟"执行者进程"走，不跟文件位置走**。`execve` 出来的子进程继承调用者的 uid + SELinux/hap 域；把已签名 ELF 放在用户会话目录（或任何位置），**由 app 去 spawn**，子进程仍是 app 域 → 还是 `EPERM`。反向证据更强：我们已经把签名文件直接装进 app 沙箱（比"放用户目录"更贴近调用者），照样 `EPERM`；同一文件在用户会话里能跑，只是因为执行者是那个会话的进程。
* **应用也没有"让别的域替它执行"的公开 API**。SDK 里唯一沾边的是测试框架的 `AbilityDelegator.executeShellCommand`（`aa test` 场景，生产包不可用），而且它走 shell 域——shell 域执行自签名 ELF 同样失败（§3 第 2 行）。

想利用"用户域能执行"这个事实，只能做成**外部 agent 端点**（开发者模式 / 方案 C+）：

* 现状不支持：协议固定 stdin/stdout JSON-RPC 2.0（`agents/README.md` 架构图），`AgentLaunchSpec` 只有 `program/args/working_dir`（`db/agent_driver.rs`），oracle-go 的 `main()` 就是扫 `os.Stdin`，没有 `--serve/--port`。
* 要做得改三处：① 上游 agent 加监听模式（或用 `socat TCP-LISTEN:… EXEC:agent` 在用户域把 stdio 桥到 TCP）；② dbx-core 加传输抽象（child / TCP / unix socket）与端点配置；③ 用 UI 或环境变量暴露端点。
* 价值：这是**不改 HAP、不碰受限权限就能验证 agent 二进制在 HarmonyOS 上本身是否正常**的唯一通道（把"能不能执行"与"agent 逻辑对不对"解耦），适合诊断与高阶用户；但需要用户手工在终端签名并启动，不是"普通用户点一下就能连 Oracle"的产品方案。

## 4. 平台侧的正确机制（参考实现在设备上）

* **HNP（HarmonyOS Native Package）**：`hnp.json` + `bin/` + `lib/` 打成的 zip；在 `module.json5` 用
  `"hnpPackages": [{"package": "x.hnp", "type": "private"}]` 声明，随 HAP 安装，由系统安装并授权其中的 ELF。
  - private → `/data/app/<包名>.org/<name>_<version>/`；public → `/data/service/hnp/<name>.org/<name>_<version>/`（并软链到 `/data/service/hnp/bin`）。
  - 设备上的实证：`bm dump -n com.develop.opensource.devbox` / `com.huawei.codearts` 均带大量 `hnpPackages`；
    Termony（终端模拟器）把 busybox/bash 打进 HNP 后直接 `execl("/data/app/base.org/base_1.0/bin/bash")` 执行成功。
* **`ohos.permission.kernel.DISABLE_CODE_MEMORY_PROTECTION` / `ALLOW_WRITABLE_CODE_MEMORY` / `CUSTOM_SANDBOX`**：
  本机 SDK `PermissionDefinitions.json` 里均为 `availableLevel: system_basic`、`provisionEnable: true`、`isKernelEffect: true`。
  HiShell（`com.huawei.hmos.hishell`）就申请了 `CUSTOM_SANDBOX`——它是系统级终端应用。
  自签名 ELF 能在 Harmonybrew/DevBox 域跑，正是这类"动态沙箱/关闭代码内存保护"的效果。
* **native child process**（`OH_Ability_StartNativeChildProcess` / `childProcessManager`）：子进程入口必须是 HAP `libs/` 里的 `.so`。

## 5. 影响面

* **受影响**：所有走 agent 子进程的驱动
  - 原生 agent：oracle、cassandra、xugu、vastbase、kingbase(原生版)、duckdb、iotdb、etcd、kafka、rocketmq、rabbitmq、zookeeper…
  - Java agent：达梦、hive、highgo、uxdb、databend、saphana…（JRE 的 `java` 同样是沙箱内未签名的下载 ELF，且其 `.so` 依赖也要签名）
  - 注意：本机 `jre_installed: true`，但 JRE 也位于沙箱内，同样起不来。
* **不受影响**：Rust 进程内实现的驱动（MySQL/PostgreSQL/SQLite/MongoDB/Redis/ClickHouse…），它们由 `libdbx_ohos.so` 直接完成，不 fork 子进程。

## 6. 处理方案（2026-09-14 记录，**暂不实施**，留待排期）

> 现状结论：A / B 都只是方案，未动代码。想动手时按下面步骤走，先做「A 的 Oracle 最小验证」最省事。

### 方案 A：把 agent 打成 HNP 随 HAP 分发（推荐，平台正路）

用平台认可的方式让 ELF「随 HAP 安装、由应用证书授权」，不依赖任何受限权限。

**A1. 生成 HNP 包（一次性 / 构建期）**
- 取上游产物：`https://github.com/t8y2/dbx/releases/download/agents-v0.2.109/dbx-agent-oracle-0.1.61-linux-aarch64.tar.zst`
  （平台清单看 `.../releases/download/agents-latest/agent-registry.json` 的 `drivers.oracle.native.linux-aarch64`）。
- 暂存目录：

  ```
  stage/dbx-agents/
    hnp.json
    bin/agent-oracle        # 0o755 的静态 ELF，原样放入，不要自己签名
  ```

  ```json
  { "type": "hnp-config", "name": "dbx-agents", "version": "1.0.0",
    "install": { "links": [ { "source": "bin/agent-oracle", "target": "dbx-agent-oracle" } ] } }
  ```

- 打成 `dbx-agents.hnp`：HNP 就是 zip。本机 SDK **没有 `hnpcli`**（`find deveco_tools -iname '*hnp*'` 只有 hnp.json），两条路：
  a) python `zipfile` 直接生成（保留 ELF 的 0755 权限位）；
  b) 从 `openharmony/startup_appspawn` 的 `service/hnp/pack` 编 `hnpcli`（依赖 cJSON / libboundscheck / zlib_static）。
- 产物放 `harmony/dbxohos/entry/hnp/arm64-v8a/dbx-agents.hnp`。
- **不要**用 `binary-sign-tool -selfSign 1` 预签（解决不了应用域那一层；注意自签名本身并不绑定机器，见 §3.1）。

**A2. `module.json5` 声明**

```json5
"hnpPackages": [ { "package": "dbx-agents.hnp", "type": "private" } ]
```

- `private` → `/data/app/<hhp org>/<name>_<version>/`，仅本应用；`public` → `/data/service/hnp/<org>/<name>_<version>/`，软链到 `/data/service/hnp/bin`，所有应用可见。
- 具体 `<org>` 命名需真机装一次后确认（Termony 的 private 路径是 `/data/app/base.org/base_1.0/bin/bash`，其 bundleName 是 `je.jia.termony`，所以目录名并非 bundleName）。

**A3. 打进 HAP**
- 本仓库用的 `hvigor-ohos-plugin`（`deveco_tools/hvigor/`）**不含 hnp 逻辑**（`grep -ri hnp` 无命中），但同目录 `ohos_packing_tool` 有 `hnp-path`（`strings` 可见 `HapPackager::isArgsValidInHapMode hnp-path is invalid.`）。
- 两条路：
  a) 升级 hvigor 插件到支持 `hnpPackages` 的版本（DevEco Studio 6 自带的支持），重新 `assembleHap`；
  b) 不动插件：在 `harmony/tools/` 加后处理脚本，向 hvigor 产出的 HAP 里注入 `hnp/arm64-v8a/dbx-agents.hnp` **并在签名之前**；发布用的未签名 HAP 也走同一脚本，保证 `module.json` 的 `hnpPackages` 与实际内容一致。
- 验证：`unzip -l <hap> | grep hnp`、`unzip -p <hap> module.json | grep -A3 hnpPackages`。

**A4. 运行时改 spawn 路径（需要重建 `.so`）**
- HNP 里的 ELF 路径与 `driver_native_path()`（沙箱内）不同，需要让 agent 启动优先走 HNP：
  - 最小改法：`upstream/dbx/crates/dbx-core/src/agent_manager.rs` 的 `driver_native_path()` 在 OHOS 上返回 HNP 路径（或新增 `driver_native_hnp_path()` 并让 `agent_driver.rs` 的 launch 组装优先取它）；
  - 回退：HNP 文件不存在时仍用沙箱路径，保持桌面/其他平台行为不变。
- 改动集中在 `agent_manager.rs` / `db/agent_driver.rs`，建议用 `#[cfg(target_env = "ohos")]` 或运行时「文件存在即优先」的探针，避免影响上游同步（这两个文件是上游高频改动区）。
- 重建：`cargo build --release -p dbx-ohos`（13–31 分钟，见 AGENTS.md「构建命令」），再打包 HAP。

**A5. 验证不变量**
- `POST /api/agents/runtime/restart {"runtimeId":"agent:oracle"}` 返回 ok，`GET /api/agents/runtime` 中 oracle `status=running`、`pid≠null`；
- 真机连一个 Oracle 跑 `SELECT 1 FROM dual`；
- 驱动列表里 oracle 的版本要能对应到 HNP 内置版本（HNP 版本号与 registry 版本号是两套，需要映射并在 UI 上说明）。

**A6. 代价 / 风险**
- 内置驱动**不能运行时升级**，「检查更新/升级」对它失效 → UI 需提示"随应用更新"。
- HAP 体积：oracle 压缩 ~2.4MB（安装后 /data/app 解出 ~17.8MB）。
- 每个要支持的驱动都得打一份；Java 类驱动还需把整棵 JRE 放进 HNP（几十 MB），单独评估。
- 许可：上游 dbx 为 Apache-2.0，随包分发 agent 需在 release notes 注明。

**A7. 体积评估（2026-09-14，数据取自 `agents-latest/agent-registry.json`）**

关键区分：**只有 ELF 需要进 HNP（要签名才能 exec）；jar 是数据，被 `java -jar` 读取，不需要签名**。所以体积由「可执行代码」决定，而不是驱动数量。

| 类别 | 数量 | HAP 内增量（压缩） | 装机后 `/data/app`（估算） |
|---|---|---|---|
| 现有 HAP 基线 | — | 68.6 MB | — |
| 原生 agent（必须进 HNP） | 17 个 | **37.7 MB**（oracle 仅 2.3） | ~250–290 MB（按 oracle 实测 2.43MB→18.68MB，约 7.7×） |
| JRE 21（解锁全部 JDBC 驱动） | 1 份 | **36.1 MB** | ~130–180 MB |
| JDBC 驱动 jar | 35 个 / 370.1 MB | **0**（继续按需下载） | 0（下载到沙箱） |

- 原生 agent 明细（压缩 MB）：duckdb 6.1、etcd 3.6、hive 2.7、argo 2.7、cassandra 2.5、oracle 2.3、vastbase 2.0、iotdb 1.9、etcd2 1.9、rabbitmq 1.9、neo4j 1.8、zookeeper 1.8、rocketmq 1.6、kingbase 1.6、sqlite-worker 1.2、tdengine 1.2、xugu 1.1。
- 最重的 jar（如果不改按需下载就会白涨体积）：snowflake 67.9、spanner 54.8、spark 35.6、databricks 32.9、kafka 21.5。
- 组合结论：
  - **只修 Oracle**：+2.3 MB，HAP ≈ 71 MB（推荐的第一步）。
  - **全部原生 agent**：+37.7 MB，HAP ≈ 106 MB，装机 +~280 MB。
  - **全部 JDBC（走 JRE-HNP）**：+36.1 MB，HAP ≈ 105 MB，装机 +~150 MB；jar 仍按需下载。
  - 两类都做：HAP ≈ 143 MB、装机 +400 MB 量级。**不建议一把全塞**。
- 把体积移出主包的正规手段：多 HAP（app bundle 的 feature HAP）——主包不带 HNP，另出一个可选的「drivers HAP」装 HNP，用户按需安装（AppGallery 支持按需下发；GitHub 分发可挂多个 hap 文件）。
- JRE-HNP 的两个待验证点：① JVM 的 JIT 需要 W+X 代码内存，而原始出处明确「**自签名 ELF 没有 JIT 权限，想要 JIT 权限得打包成 public hnp 塞到 hap 里安装**」→ JRE 那个 HNP 应该用 `type: public`（装到 `/data/service/hnp/<name>.org/<name>_<ver>/`，并软链进 `/data/service/hnp/bin`），而不是 private；否则只能 `-Xint` 纯解释执行（慢；dbx 现有 java 参数里已有 `-XX:TieredStopAtLevel=1`）。② `java`/`libjli.so` 等整棵 JRE 树的 ELF 都在同一个 HNP 里，需要把 `agent_manager` 的 JRE 路径解析改到 HNP 路径（与 A4 同一处改动）；另外 **HNP 里的 `.so` 必须是实体文件**，不能是符号链接（见 B2 最后一条）。

### 方案 B：受限权限 + 运行时自签名（保留"按需下载"）

**B1. 权限**
- `module.json5` 增加：
  - `ohos.permission.kernel.DISABLE_CODE_MEMORY_PROTECTION` —— 核心（`isKernelEffect: true`，即关闭 BinSec 对 mmap/exec 的强制）；
  - 可选 `ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`（JIT 用，原生 agent 不需要，JRE 可能需要）。
- 两者在 SDK `toolchains/lib/PermissionDefinitions.json` 中为 `availableLevel: system_basic`、`provisionEnable: true`、`availableType: NORMAL`。
- 必须同时在**签名 profile 的 ACL**（`acls.allowed-acls`）里放行（DevEco 自动签名 / Huawei 审批链路先确认）；用户用自签名 profile 安装时也要带 ACL，否则装不上或权限不生效。

**B2. 运行时自签名**
- 内嵌 `hqzing/ohos-bst-light` 的 `selfsign.rs`（22KB / 647 行；0BSD，纯 std 自带 SHA-256，零依赖，与官方 `binary-sign-tool -selfSign 1` 字节一致，`LICENSE` 明确允许无署名内嵌）。
- 放到 dbx-core 新模块（如 `agent_sign.rs`），仅 `target_env = "ohos"` 编译。
- 触发点（建议两处都做）：
  1. 安装后：`agent_service.rs` 的 `install_driver_from_tar_zstd_package()` / `import_agent_driver()` 落盘后签名；
  2. spawn 前兜底：扩展 `agent_driver.rs` 的 `repair_native_agent_execute_permission()`（现在只补 0o100 再重试）为「EACCES → 补签名（+补执行位）→ 重试」，这样老装机的驱动也能自愈。
- JRE 路径：解包后遍历 `jdk-21/**` 给 `bin/java` 和 `lib/*.so` 全部签名。
- 幂等：先检查 ELF 是否已有 `.codesign` 段，有则跳过。
- **签名与机器无关**：自签名只由 ELF 内容推导（帖主已更正早先「签名绑定机器」的说法；本仓库也核对过 `selfsign.rs` 无任何机器输入），所以"在哪签"不是限制；B 需要在设备上现签只是因为驱动是运行时下载的。
- **但自签名没有 JIT 权限**（原始出处明确：「想要 JIT 权限还是得打包成 public hnp 塞到 hap 里安装」）→ **JRE/JDBC 类驱动基本不能用 B 路线**，除非 `-Xint` 纯解释执行能跑通。
- **自签名动态库不能用符号连接**：鸿蒙动态链接器无法正确处理自签名 `.so` 的 symlink，依赖库必须是实体文件（JRE 目录里符号链接很多；dbx 现在解压时跳过 symlink，会直接缺库——这与 AGENTS.md 里「JRE 解压跳过 symlink」那条正好撞上）。

**B3. 关键未知项（动手第一步就该验的最小实验，不需要重建 `.so`）**
- 应用域在放开 `DISABLE_CODE_MEMORY_PROTECTION` 后，是否接受自签名 ELF。
- 做法：加权限 + 改 profile ACL → 重装 HAP（`.so`/ArkTS 不用改）→ 用现在已经装在沙箱里的自签名 oracle 触发 `restart`；若成功则 B 成立，原生 agent 可按需下载；JRE 类另说（见上一条 JIT 限制）。
- 之所以能这么验：本次排查已把自签名 oracle 装进沙箱（见 §7 说明）。

**B4. 风险**
- 依赖受限权限：上架审批 + 用户签名 profile 摩擦都可能让方案不落地。
- 关闭代码内存保护会降低应用安全基线，需要产品上明确权衡（可考虑做成可选开关）。
- 上游同步成本：`agent_service.rs` / `agent_driver.rs` 是上游高频改动区，补丁要小且集中。

### 方案 C（备选）：暂不支持，明确记录限制

在 README / 发布说明写明「HarmonyOS 上 agent 类驱动不可用」，引导用户使用进程内驱动（MySQL/PostgreSQL/SQLite/MongoDB/Redis/ClickHouse…），等 A 或 B 排期。

## 7. 复现/验证命令（下次直接跑）

```bash
H="hdc -t 127.0.0.1:43817"
B=http://127.0.0.1:14224

# ── 1) 取上游未签名 agent（2026-09-14 实测的固定版本）────────────────
mkdir -p .tmp/oracle && cd .tmp/oracle
curl -sSL -o agent.tar.zst \
  https://github.com/t8y2/dbx/releases/download/agents-v0.2.109/dbx-agent-oracle-0.1.61-linux-aarch64.tar.zst
tar --zstd -xf agent.tar.zst
cp drivers/dbx-agent-oracle-0.1.61-linux-aarch64 agent-unsigned   # 18,677,912 B
cp agent-unsigned agent-signed
sha256sum agent-unsigned    # 1512ce1d36fe0cc8a07b9a0aa12082a52cca7be4d59b33ee717013a7bc5885f3

# ── 2) 自签名（官方工具；Harmonybrew 装 / CodeArts IDE SDK / DevBox 里都有）──
export PATH=$PATH:/storage/Users/currentUser/.harmonybrew/bin   # binary-sign-tool
binary-sign-tool sign -inFile agent-signed -outFile agent-signed -selfSign 1
# → add codesign section success / write code sign data success
#   18,682,816 B（+4,904），sha256 ea6c040e39797a0da18d9de39b879d2b672409639c7d3d6a999682aab446f254
binary-sign-tool display-sign -inFile agent-signed
# → permission is not found / code signature is self-sign
llvm-readelf -S agent-signed | grep codesign     # → [14] .codesign PROGBITS ... 0x1000  align 4096

# ── 3) 三个域对照 ───────────────────────────────────────────────
# 3a. hdc shell 域（uid 2000, u:r:sh:s0）→ 仍 EACCES
$H file send agent-signed /data/local/tmp/agent-signed
$H shell "chmod +x /data/local/tmp/agent-signed; \
  echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}' | timeout 5 /data/local/tmp/agent-signed"
# 3b. 本机用户会话域（uid 20020102）→ 成功，agent 回 ready 帧
timeout 5 ./agent-signed <<< '{"jsonrpc":"2.0","id":1,"method":"ping"}'   # → {"ready":true}
# 3c. dbx 应用域 → EPERM（先装进去再启动）
$H fport tcp:14224 tcp:4224
curl -sS -X POST $B/api/agents/import-driver -F dbType=oracle -F "file=@agent-signed;filename=agent"
curl -sS -X POST $B/api/agents/runtime/restart -H 'Content-Type: application/json' \
     -d '{"runtimeId":"agent:oracle"}'      # → Operation not permitted (os error 1)

# ── 4) 判定日志 ─────────────────────────────────────────────────
$H shell "hilog -x | grep -E 'code_protect|BinSec' | tail -20"
```

> 工具备注：`binary-sign-tool sign -inFile`/`-outFile` 传同一路径即**就地签名**；重复签名会报 `.codesign section already exists`，需先 `llvm-objcopy --remove-section .codesign <elf>`（或改用 `hqzing/ohos-bst-light` 的 selfsign 工具，支持 `--force` / `--strip`）。本次用的是 Harmonybrew 里的官方 `binary-sign-tool`，与 CodeArts IDE SDK 自带的是同一套。

> 说明：排查过程中已通过 `/api/agents/import-driver` 把**自签名**的 oracle 0.1.61 装进沙箱（`installed_version` 显示为 `0.1.0-local`）。
> 这不改变任何可用性（仍然 EPERM）；需要还原时在 UI 里重新安装/更新该驱动即可。

## 8. HNP 打包清单（哪些驱动要打包、打什么）

判定依据（按权威程度排序）：
1. `crates/dbx-core/src/connection.rs` 的 `agent_connection_pool_database_type!()`——**真正决定是否 fork agent 的地方，43 个连接类型**；
2. 额外 agent 路径：`mongodb-legacy`、`external_driver_pool("jdbc")`（PrestoSQL / 通用 JDBC）、`duckdb_worker_process`（sidecar）、`sqlite-worker`（SSH 远程）；
3. `agents-latest/agent-registry.json` 的产物类型——注意**很多 native 驱动的 `jar` 是 `size=0` 的 legacy 占位，不算可用 jar**（用错会把 17 个 native 误判成 "native+jar"）；
4. `assets/database-drivers.manifest.json` 的 `runtimeMode` 只作参考：它与实现有两处不符（见 8.1 的 mongodb / influxdb）。

### 8.1 不需要 HNP（进程内 Rust，现在就能用）

- 31 个 `runtimeMode=native`：mysql、postgres、rqlite、turso、cloudflare-d1、redis、clickhouse、sqlserver（默认）、dynamodb、elasticsearch、easysearch、meilisearch、hbase、qdrant、chromadb、milvus、weaviate、doris、starrocks、manticoresearch、redshift、gaussdb、kwdb、opengauss、questdb、nacos、consul、mqtt、influxdb3、victoriametrics、mongodb（默认）
- `file` 模式：sqlite（本地文件）
- **两处与 manifest 不符**：`mongodb` manifest 标 `runtimeMode=agent`，但 core 默认走进程内 Rust（只有显式选 `mongodb-legacy` profile 才 spawn agent）；`influxdb`（v1/v2）manifest 标 agent 且 registry 里没有该产物，core 走进程内 `influxdb_driver`。

### 8.2 需要 HNP：原生 ELF（13 个文件 / 约 27.1 MB 压缩，覆盖 14 个连接类型）

| HNP 里的 ELF（registry key） | 覆盖的连接类型 | 压缩 |
|---|---|---|
| `oracle` | Oracle | 2.3 MB |
| `kingbase` | 金仓 KingbaseES | 1.6 MB |
| `vastbase` | 海量 Vastbase | 2.0 MB |
| `hive` | Apache Hive、Apache Kyuubi、Apache Impala | 2.7 MB |
| `argo` | 星环 Argo | 2.7 MB |
| `neo4j` | Neo4j | 1.8 MB |
| `cassandra` | Apache Cassandra | 2.5 MB |
| `iotdb` | Apache IoTDB | 1.9 MB |
| `tdengine` | TDengine | 1.2 MB |
| `xugu` | 虚谷 XuguDB | 1.1 MB |
| `etcd` | etcd（默认） | 3.6 MB |
| `etcd2` | etcd（`etcd-v2` profile） | 1.9 MB |
| `zookeeper` | Apache ZooKeeper | 1.8 MB |

### 8.3 需要 HNP：JRE（1 份 / 36.1 MB，覆盖 29 个连接类型）

一个 JRE 就能解锁全部 JDBC 驱动，**jar 本身不必进 HNP**（它是数据，被 `java -jar` 读取，可继续按需下载）。29 个连接类型：
达梦、瀚高 HighGo、优炫 UXDB、金篆 GoldenDB、Databend、崖山 YashanDB、Databricks SQL、SAP HANA、Teradata、Vertica、Firebird、Exasol、OceanBase Oracle Mode、GBase 8a/8s、Microsoft Access、H2、Snowflake、Trino、Apache Spark、IBM DB2、IBM Informix、Google BigQuery、Google Cloud Spanner、Apache Kylin、Apache Ignite、Apache Ignite 3、科蓝 SUNDB、神通 OSCAR、InterSystems IRIS(+Cache)。

- 按原始出处，JRE 的 HNP 要用 **`type: public`**（自签名没有 JIT 权限；public HNP 才有），并保证 `.so` 都是实体文件（不能是符号链接）。

### 8.4 默认不需要、但用到就必须有的

| 场景 | 需要的产物 |
|---|---|
| **本地 DuckDB**（OHOS 构建 `duckdb-sidecar` 已启用，走 `DBX_DUCKDB_DRIVER_PATH` 子进程） | `duckdb` ELF，6.1 MB |
| SQLite over SSH（远程 worker） | `sqlite-worker` ELF，1.2 MB |
| MQ 面板：Kafka / RocketMQ / RabbitMQ | `kafka` jar（JRE）/ `rocketmq` ELF（1.6 MB）/ `rabbitmq` ELF（1.9 MB） |
| MongoDB legacy profile / SQL Server legacy profile | 各自 jar（JRE） |
| PrestoSQL / 通用 JDBC（用户自备 jar） | JRE + 用户 jar |

### 8.5 体积合计（HAP 内增量，基线 68.6 MB）

- 只做 Oracle：**+2.3 MB** → ≈ 71 MB
- 12 个原生 agent 覆盖 14 个连接类型（含 etcd2 共 13 个 ELF）：**+27.1 MB** → ≈ 96 MB
- 全部原生（再加 duckdb/sqlite-worker/rocketmq/rabbitmq）：+10.8 MB → ≈ 107 MB
- 全部 JDBC（JRE public HNP）：**+36.1 MB** → ≈ 105 MB（jar 仍按需下载）
- 原生 + JDBC 全包：≈ **132 MB**（装机 `/data/app` 合计 +400 MB 量级）


## 9. 方案 A（HNP）实测结论：当前签名材料 + 本机工具链**装不上**（2026-09-15）

结论先行：**HNP 打包本身能打通，但装不进去**。安装 HNP 需要两个当前拿不到的前置条件，因此「把 agent/JRE 打进 HNP 随 HAP 分发」在本项目"未签名 HAP + 用户自签 debug 证书"的分发模型下**不可行**。

### 9.1 失败链与对照实验

| 步骤 | 结果 |
|---|---|
| HAP 内放 `hnp/arm64-v8a/dbx-agent-oracle.hnp` + `module.json5` 声明 `hnpPackages`（private），`hdc install -r` | ❌ `error: failed to install bundle. code:9568407 Failed to install the HAP because installing the native package failed.` |
| 同上，但把 HNP 里的 ELF 先用 `binary-sign-tool -selfSign 1` 签名 | ❌ 同样失败（签名不是这里的问题） |
| **去掉 `hnpPackages` 与 `entry/hnp/`，同一个 HAP 重装** | ✅ `install bundle successfully.`（应用启动正常，`/api/health` = ok） |

设备侧日志：

```
E C05A06/installs/CODE_SIGN: CheckCertHasBinaryCertExtension: Binary cert extension not found in certificate
E C05A06/hnp/CODE_SIGN: [ParseNativeLibSignInfo]:Libs signature not found: signMap_ size:0, signMapPreSize:0
E installd_operator.cpp:ProcessBundleInstallNative:978 Native package installation failed with error code: 8393475   # 0x801303
```

`0x801303` 按官方 [hnp 错误码文档](https://github.com/openharmony/startup_appspawn/blob/master/service/hnp/installer/errorcode-hnp.md) = 「获取安装实际路径失败」。

### 9.2 两个硬门槛

1. **HAP 的签名证书必须带华为"二进制证书扩展"**，OID `1.3.6.1.4.1.2011.2.376.1.8`：
   - 判定代码在 OpenHarmony `security_code_signature`：`services/key_enable/utils/src/key_utils.cpp:107 CheckCertHasBinaryCertExtension()`，遍历 X.509 扩展找该 OID，找不到就报上面那行错误。
   - 本机签名证书链（3 张：`Huawei CBG Root CA G2` → `Huawei CBG Developer Relations CA G2` → 开发证书）逐张用 `openssl x509 -text` 核过，**都没有该 OID**。该扩展是华为签发的"可签名原生代码"证书才有的，普通开发者 debug/release 证书没有；DevBox/CodeArts/Termony 这类附带 HNP 的应用才具备。
2. **HAP 签名里必须带 HNP 内各文件的 signMap**（`signMap_ size:0` 就是缺它）：本机 `toolchains/lib/hap-sign-tool` 是 musl 原生二进制、`strings | grep -i hnp` 无任何命中；`hvigor-ohos-plugin`（6/25 版）也完全没有 HNP 逻辑。也就是说**即使塞进 HAP，本地工具链也签不出 HNP 的文件签名表**。

另外，本机 SDK 的 `module.json5` schema **只接受 `hnpPackages[].type = "private"`**；写 `"public"` 直接 `00303038 Schema validate failed`——进一步说明这套工具链早于 HNP 支持。要满足 JIT 得用 public（见 §8.4），在本地工具链上连声明都过不了。

### 9.3 已经被打通、可复用的部分（下次不用重做）

- **HNP 打包**：`harmony/tools/build_hnp.py`（zip = `hnp.json` + `bin/agent`（0o755），并可对 HNP 内 ELF 调 `binary-sign-tool -selfSign 1`；下载走 `.tmp/hnp-dl/` 缓存、校验 sha256）。`python3 harmony/tools/build_hnp.py --only oracle|--all-native [--jre]`。
- **hvigor 注入 --hnp-path**：本地插件补丁（两个文件，均有 `.dsh-bak-20260915-200019` 备份）：
  - `src/builder/inner-java-command-builder/packing-tool-options.js`：新增 `addHnpPath(t)` → `--hnp-path`
  - `src/tasks/base/base-pack-hap-task.js`：`generateCommand()` 里检测 `<module>/hnp` 存在则调用
  - 效果已验证：构建产物 HAP 内出现 `hnp/arm64-v8a/dbx-agent-oracle.hnp`（`unzip -l` 可见），且 `module.json` 的 `hnpPackages` 声明会保留（在 `module` 字段下，注意不是顶层）。
  - 该补丁**无 hnp 目录时不生效**，可安全留着；要回滚就用备份文件覆盖。
- **真机安装路径**（官方 `service/hnp/README_zh.md` 规格）：public → `/data/service/hnp/<name>.org/<name>_<version>/`；private → `/data/app/<bundleName>/<name>.org/<name>_<version>/`；物理路径在 `/data/app/el1/bundle/<userid>/{hnp,hnppublic}/`（userid 默认 100），安装后会被 bind-mount 进应用沙箱。
- **运行时路径探测**：`harmony/dbxohos/entry/src/main/ets/services/BundledDrivers.ets`（读 rawfile `bundled-drivers.json` → 逐个候选路径 `fs.accessSync` + hilog `DBX_HNP`）。没有 manifest 时完全惰性，不影响启动。

### 9.4 要让方案 A 成立，需要什么

1. **华为签发的"二进制证书"**（证书里带 `1.3.6.1.4.1.2011.2.376.1.8`），并用它签 HAP——普通开发者证书/自签 profile 都不行。
2. **支持 HNP 签名的工具链**（DevEco Studio 6 自带的 hvigor + hap-sign-tool；本机 CLT 26.0.0.18 这套不够），它会在签名时把 HNP 内文件写进 signMap。
3. 因为 1 的存在，**用户自签/未签名分发模型与 HNP 互斥**：只要 HAP 由用户证书签名，就装不了 HNP。

→ 因此 agent 类驱动在 HarmonyOS 上的自包含方案回到 **B（受限权限 + 运行时自签名，见 §6 方案 B）**，否则只能 **C（记为限制）**。A 仅适合"维护者拿得到华为二进制证书并集中签名分发"的场景。

## 10. 方案 B 实测：受限权限要 profile ACL，否则**连装都装不上**（2026-09-15）

- 在 `module.json5` 申请 `ohos.permission.kernel.DISABLE_CODE_MEMORY_PROTECTION`（system_basic，带 `reason` + `usedScene`），构建通过。
- `hdc install -r` 直接失败：

  ```
  code:9568289 error: install failed due to grant request permissions failed.
  PermissionName: ohos.permission.kernel.DISABLE_CODE_MEMORY_PROTECTION
  ```

- 原因：本项目签名 profile（DevEco 自动签名生成的 Huawei debug profile）里 `"acls":{"allowed-acls":[]}` 是**空的**；受限权限必须在 profile 的 ACL 里放行，这要经过 **AGC 申请 / 华为审批**。自己造 profile 也不行——Huawei 设备只信任 Huawei profile CA 签的 profile。
- **结论：B 和 A 一样卡在华为侧授权**（A 要"二进制证书"，B 要"ACL"），都不是改代码能过的门槛。
- 已还原：权限声明与 `reason_*` 字符串已移除，应用恢复可安装（`install bundle successfully` / `/api/health` = ok）。

## 11. 剩下的自包含候选：agent 直接放进 HAP 的 `libs/`（**待验证**，可能不需要任何华为授权）

思路：不走 HNP，把 agent ELF 当作原生库随 HAP 分发（例如 `entry/libs/arm64-v8a/libdbx_agent_oracle.so`），运行时从 bundle libs 路径 spawn。

为什么可能成立：

- HAP 的 `libs/**` 在安装时由系统按**应用证书**做代码签名/完整性标记；`libdbx_ohos.so` 就是从那里被 dlopen 成功的，而 `dlopen` 本身要求对该文件有 execute 权限 → 说明应用域对 bundle libs 文件允许执行。
- 之前拿到的 `EACCES`（未签名）与 `EPERM`（自签名）都发生在**沙箱内**的文件；bundle libs 里的文件是"应用证书授权"的代码，正是 `CheckSigned` 期望的身份。
- 不需要 HNP、不需要受限权限/ACL、不需要二进制证书。

代价与限制：

- `libs/` 在 HAP 内是 **STORED（不压缩）**：每个 agent 让 HAP **+18MB** 左右（oracle ELF 实测 18,677,912 B；HNP 压缩后只需 4.3MB）。因此只适合精选少量驱动（例如仅 Oracle），不适合"17 个全带"。
- 需要三处改动：① ArkTS 把 `<context.bundleCodeDir>/libs/arm64` 传给 `NativeBridge.startServer()`；② Rust（`dbx-ohos`/`dbx-core`）把内置驱动的 `driver_native_path()` 指到该目录；③ 重建 `.so`（13–31 分钟）后真机验证 spawn。
- 待验证的关键点：bundle libs 目录里的 ELF **execve** 是否被应用域允许（`dlopen` 能过是强证据，但不完全等价——两者都要 `execute` 权限，区别在 exec 钩子）。

验证方式（最小）：只放 oracle 一个 ELF + 上述改动 → `POST /api/agents/runtime/restart {"runtimeId":"agent:oracle"}` 看是否 `running`。

## 12. 方案 A′ 实测：bundle libs 里的 ELF 同样执行不了（2026-09-15）

做法：把 oracle agent（静态 Go ELF，18.7MB）复制成 `entry/libs/arm64-v8a/libdbx_agent_oracle.so`，Rust 侧让 `driver_native_path("oracle")` 在该文件存在时优先返回它（用 `/proc/self/maps` 找 `libdbx_ohos.so` 所在目录，避免改 NAPI 签名）。

| 观察（均为真机实测） | 结论 |
|---|---|
| HAP 内出现 `libs/arm64-v8a/libdbx_agent_oracle.so`（18,676,584 B，STORED）；安装成功 | 打包/安装没问题 |
| 应用内 `statSync('<bundleCodeDir>/libs/arm64/libdbx_agent_oracle.so')` 成功；应用内 `listFileSync` 列出 `libdbx_ohos.so,libdbx_agent_oracle.so` | 额外 lib 确实解到了 bundle libs |
| 首次 spawn：`Failed to spawn agent process …/libdbx_agent_oracle.so: No such file or directory (os error 2)` | **不是文件不存在**：这是 `working_dir`（`<dataDir>/agents/drivers/oracle`）不存在导致 `Command::current_dir` 失败的表现（沙箱里那个目录当时确实没了） |
| 由 ArkTS 建出该目录后重试：错误变成 `Permission denied (os error 13)` | execve 真正被拒 |
| 应用内 `statSync`：`libdbx_ohos.so` 与 `libdbx_agent_oracle.so` **均为 mode=644**（uid/gid 3060） | **bundle libs 安装后没有 x 位**；`execve` 需要执行位 → EACCES |
| 对比：`libdbx_ohos.so` 同为 0644 却能 dlopen | `dlopen` 只要可读（mmap 的 execute 由 LSM 管），不需要文件 x 位；`execve` 需要 |
| 应用不是属主（uid 3060）、bundle 目录只读 | 无法 `chmod` |

结合 §3 的两次结果（沙箱内：未签名 + x 位 → `EACCES`；自签名 + x 位 → `EPERM`）可以看出，应用域执行外部 ELF 需要**同时**满足：① 有 x 位；② 代码带**应用身份**签名。bundle libs 的文件满足 ② 但缺 ①；沙箱里应用能 chmod 出 ① 却永远满足不了 ②。

→ **A′ 也不通**。至此 A（HNP）、B（受限权限）、A′（libs）三条"改代码就能过"的路全部证伪。

### 12.1 唯一剩下的技术路线：native child process（数周级，需上游配合）

- `OH_Ability_StartNativeChildProcess("libxxx.so:Main", args, options, &pid)`（C API，链 `libchild_process.so`）或 ArkTS `childProcessManager`：由 appspawn 以**应用身份**创建子进程，入口是 HAP `libs/` 里 .so 的**导出函数**——走 dlopen，不需要文件 x 位；`NativeChildProcess_Args` 支持 `fdList` 传 fd。
- 需要的改造：① 上游 agent 以 `-buildmode=c-shared` 编成带导出入口的 `.so`（Go c-shared 需要目标平台 C 工具链，ohos 目标可编）；② dbx-core 的 agent 传输从"子进程 stdin/stdout 管道"改为 socketpair/fd 通道；③ ArkTS 负责 `startNativeChildProcess` 并把 fd 交给 Rust。
- JDBC/JRE 还要加一层：子进程入口 `.so` 内 `dlopen(libjvm.so)` + `JNI_CreateJavaVM` 在进程内起 JVM（同样绕开 exec）。
- 代价：数周级改造 + 上游分叉；收益：**不需要华为任何证书/ACL**。记录为"以后真要做"的路线，本轮不实施。

## 13. 方案 D 可行性 spike：native child process —— **验证通过**（2026-09-15）

做法：写一个最小子进程库 `libdbx_ncpspike.so`（源码 `harmony/tools/ncp_spike/ncp_spike.c`，导出 `void Main(NativeChildProcess_Args)`），用 OHOS clang 编成 arm64 .so 放进 `entry/libs/arm64-v8a/`；ArkTS 侧调用：

```ts
childProcessManager.startNativeChildProcess('libdbx_ncpspike.so:Main',
    { entryParams: markerPath, fds: { test: file.fd } })
```

真机日志（关键行）：

```
DBX_ABILITY: NCP spike started pid=53128
DBX_NCP(x.ohos:Native_libdbx_ncpspike0): NCP_CHILD start params=.../ncp-child-marker.txt
DBX_NCP: NCP_CHILD fd[1] name=test fd=20 written=30
DBX_NCP: NCP_CHILD marker written=10
DBX_ABILITY: NCP spike fd-file=[{"ready":true,"from":"child"}|] marker=[child-ran|]
```

结论（逐条，都是实测）：

| 事实 | 意义 |
|---|---|
| 子进程能从 HAP `libs/` 的 .so 启动 | appspawn **用 dlopen 加载**，不需要文件 x 位（libs 装后是 0644，见 §12）→ 绕开了 A/B/A′ 的死结 |
| 子进程以**应用身份**运行（写进了应用沙箱），`entryParams` 到手 | 与 agent 需要的 uid/沙箱一致 |
| **fdList 可用**：父进程传入 fd（子进程里 fd=20），子进程用同一 fd 回写，父进程读到 JSON | 这就是 agent JSON-RPC 需要的双向通道（正式实现改用 `socketpair`） |
| 可同时起**多个**子进程（实测 2 个：pid 55593/55626，tag `Native_libdbx_ncpspike0/1`） | 文档里"只允许 1 个"只针对 IPC 版 `OH_Ability_CreateNativeChildProcess`；`startNativeChildProcess` 不受此限（超限错误码 16000062） |
| 全程不需要任何华为证书 / ACL / 受限权限 | 这是唯一不被华为侧授权卡住的路线 |

保留的 spike 产物：`harmony/tools/ncp_spike/ncp_spike.c` + `harmony/tools/build_ncp_spike.sh`（验证完已从 HAP 移除，应用恢复原状、启动冒烟 12/12）。

### 13.1 正式实现改造清单（下一步）

1. **启动方**：优先由 Rust 直接调 C API `OH_Ability_StartNativeChildProcess(entry, args, options, &pid)`（链 `libchild_process.so`），由它创建 `socketpair` 并把一端放进 `fdList`，ArkTS 不用参与每次启动；若 C API 在 NAPI 上下文不可用，退化为 ArkTS 转调（已证可行）。
2. **传输层**：`AgentDriverClient` 目前绑定 `Child` + stdin/stdout（`AgentLaunchSpec{program,args,working_dir}`），需加 transport 抽象 `{ ChildStdio, UnixStream }`，JSON-RPC 读写走 fd。
3. **agent 侧**：上游原生 agent 用 `-buildmode=c-shared` 编成 .so 并导出 `Main`（Go：`//export Main` + 从 `fdList` 取 fd 后跑现有 JSON-RPC 循环；go-ora 纯 Go，交叉编译可行，需 ohos clang 当 CC）。hive 一个产物覆盖 hive/kyuubi/impala；etcd/etcd2 等逐个来。
4. **HAP 体积**：`libs/` 目前 STORED 不压缩（每 agent ≈ +18MB）；打包工具有 `compressNativeLibs`（`GetStageCompressNativeLibs`），开了以后增量≈压缩体积（≈4.4MB/agent），需验证压缩 HAP 解出的 libs 仍可 dlopen。
5. **JDBC/JRE**：子进程入口 .so 内 `dlopen(libjvm.so)` + `JNI_CreateJavaVM` 内嵌 JVM，再加载 agent jar；JIT 是否需要 `kernel.ALLOW_WRITABLE_CODE_MEMORY`（若需要又撞 ACL，可用 `-Xint` 规避）待验证。
6. **驱动管理 UI**：内置驱动（libs 里的 .so）显示"已安装 + 版本"并把卸载置灰——到这一步才有意义：后端加 `bundled: bool`，前端（fork CI 重建 dist）据此禁用按钮。

### 13.2 本机工具链注意事项（本轮踩到的）

- `deveco_tools/sdk/default/openharmony/native/llvm/bin/clang` 与 `clang-15` 是**无法执行的实体文件**（`EPERM`；原本应是 `clang -> clang-15` 符号链接，被复制成普通文件后代码签名失效）。编译原生代码请用 **Harmonybrew 那份**：`OHOS_NDK_HOME=/storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_1/native`（`build_ncp_spike.sh` 已默认用它）。
- 写 C 代码时注意 `AbilityKit/native_child_process.h` 自身没 include `<stdbool.h>`，会报 `unknown type name 'bool'`——在包含它之前先 `#include <stdbool.h>`。

## 14. 方案 D 打通 oracle 端到端：Go c-shared 在 musl 上的两处运行时补丁（2026-09-15 **已真机验证**）

目标：把 oracle agent（Go，`agents/drivers/oracle-go`）编成 `-buildmode=c-shared`，交给 native child process dlopen，用传入的 fd 跑原来的 stdin/stdout JSON-RPC。**结果：真机跑通**——子进程写出 `{"ready":true}` 并正确回应了 `handshake`：

```
DBX_NCP: NCP oracle probe: child started pid=32531
DBX_NCP: NCP oracle probe: out=[{"ready":true}|{"jsonrpc":"2.0","id":1,"result":
  {"agentProtocolVersion":2,"capabilities":["connect","test_connection","metadata","query",
   "transaction","ddl","multi_session"],"protocolVersion":2}}|]
```

但这一路并不只是"编个 c-shared"。Go 的 c-shared 库在 **musl** 上有两处硬伤，两处都必须打补丁，否则连 `dlopen` 都过不去（宿主就是 musl，可在宿主上秒级复现，不必反复装机）：

### 14.1 阻塞点 1：initial-exec TLS（`dlopen` 直接失败）

```
Load lib file <private> failed, err Error relocating
  /data/storage/el1/bundle/libs/arm64/libdbx_agent_oracle.so:
  initial-exec TLS resolves to dynamic definition in ...libdbx_agent_oracle.so
```

根因链（逐条实测）：
- 产物里 `PT_TLS` 16 字节（`.tbss` 里 `runtime.tls_g` 8 字节 + `runtime.tlsg` 8 字节）+ **恰好 1 条 `R_AARCH64_TLS_TPREL64`**（TLS 的 IE 模型 GOT 槽）。
- linux/arm64 上 Go 把 g 存在 TLS：`runtime/tls_arm64.s` 的 `load_g`/`save_g` 里 `MOVD runtime·tls_g(SB), R27; MOVD (R0)(R27), g`（Android 走 `TLSG_IS_VARIABLE` 特例，把 `tls_g` 变成普通全局变量指向 bionic 的固定 slot，所以 Android 没这个问题）。
- musl 只给 dlopen 进来的模块分配**动态 TLS**（dtv），解析不了 IE 重定位 → `dlopen` 失败。musl 作者 [在 go#54805 里确认](https://github.com/golang/go/issues/54805)：IE 模型按定义只能用于进程启动时就存在的 TLS，Go 当时还没实现 dynamic 模型。该 issue 至今 open（上游有 CL 644975「Add dynamic TLS model for ARM64」、CL 696635，但本地 go1.27.1 **尚未包含**：`cmd/internal/objabi/reloctype.go` 里 arm64 只有 `R_ARM64_TLS_LE`/`R_ARM64_TLS_IE`，没有 GD）。
- 换用 `-fno-emulated-tls`（原生 TLS）**不行**：clang 生成 `R_AARCH64_TLSDESC_*`，Go 的**内部链接器**写坏它（产物里只剩一条残缺的 `R_AARCH64_TLSDESC`，`dlopen` 后崩在 `ld-musl` 里）；改成 `-linkmode=external` 让 ld.lld 处理**也一样崩**——因为 **OHOS 的 musl 不支持 TLSDESC**。这也解释了为什么 OHOS 的 clang **默认就是 emulated TLS**（`-femulated-tls`）：平台自己知道 dlopen 场景下只有 emutls 可用。

补丁做法：`runtime/tls_arm64.s` 的 `load_g`/`save_g` 在 `GOOS_linux` 下改调 C 侧的
`dbxLoadG()` / `dbxSaveG()`，用一个 `static __thread void *dbx_go_g;`（即 emutls，走 compiler-rt 的 `__emutls_get_address` + pthread key）保存 g。

### 14.2 阻塞点 2：argc/argv 是垃圾（扫垃圾指针 SIGSEGV）

补掉 TLS 之后 `dlopen` 成功，但立刻崩在 `runtime.sysargs`/`IndexByteString`：

```
FAULT addr=0x73656d616e2d60 pc=... runtime.sysargs+0x24  lr=... runtime.args
```

根因：`runtime/asm_arm64.s` 的 `_rt0_arm64_lib` 注释写着"We expect argc and argv to be passed in the usual C ABI registers R0 and R1"，但 **musl 调 init_array 时不传**（实测宿主上 C 构造函数拿到 `x0=0x100000001`、`x1=0x5a91154560`）。Go 拿着垃圾 argc 去扫 argv 指针 → 崩。glibc/bionic 会传，所以只有 musl 上炸（Go 侧同一问题见 CL 610837「fix segfault due to missing argv on musl-linux c-archive」）。

补丁做法：`_rt0_arm64_lib` 在 `GOOS_linux` 下改用 asm 里自带的一块合法骨架：

```
argv = ["dbx-agent", NULL]   envp = [NULL]   auxv = [AT_NULL, 0]
```

关键点：Go 的 `sysargs`（`runtime/os_linux.go:251`）在 **auxv 为空时会自动回退去读 `/proc/self/auxv`**（注释里明确说是为 "loaded as a library on Android" 准备的），所以真实 auxv（页大小 / HWCAP）不会丢。实测库里 `os.Args == ["dbx-agent"]`、`/proc/self/auxv` 读到 481 字节、`physPageSize` 正常、GC/大块分配正常。

### 14.3 补丁怎么落地（不碰全局 GOROOT）

- 生成器：`harmony/tools/go_ohos_overlay.py` —— 读当前 `GOROOT` 的 `tls_arm64.s` / `asm_arm64.s`，按精确文本做替换（**匹配次数不为 1 就报错退出**，Go 升级后能第一时间发现补丁点变了），输出 patched 副本 + `overlay.json`。
- 生效方式：`go build -overlay=overlay.json`（实测 `-overlay` **对 `.s` 文件同样生效**，改坏它构建会立刻报错）。
- 构建脚本：`harmony/tools/build_agent_cshared.sh` 已内置（先生成 overlay 再 `go build -buildmode=c-shared -tags ohos_ncp -overlay=...`）。
- C 侧两个函数在 agent 的 `ohos_ncp_shim.c` 里（`//go:build ohos_ncp`）。
- 产物自检（应为空）：`llvm-readelf -r libdbx_agent_oracle.so | grep TLS` 无 `R_AARCH64_TLS_*`。

### 14.4 宿主就是 musl，验证不必上机

宿主（本机 HarmonyOS PC）的 `/lib/ld-musl-aarch64.so.1` + `clang 15 (aarch64-unknown-linux-ohos)` 与设备同源，因此上面所有结论都能在宿主上用「一个 trivial c-shared + 一个 `dlopen` 的 C driver」秒级复现/回归验证，包括：并发多线程调用、**外来 C 线程回调 Go**（走 `needm` + `load_g`）、`SIGURG` 抢占信号、GC、`os.Args`。补丁后的库在宿主上 26 次回调 + 6 线程并发全部通过。

### 14.5 Rust 侧也打通了：socketpair + C API 起子进程 + JSON-RPC（真机验证）

`crates/dbx-ohos/src/ncp_probe.rs`（`#[cfg(target_env = "ohos")]`，非 OHOS 目标给 stub 以保住 `cargo check`）做了父进程的完整半边：

1. `std::os::unix::net::UnixStream::pair()` 建 socketpair（std 自带，不需要额外依赖）；
2. `#[link(name = "child_process")]` + `extern "C" OH_Ability_StartNativeChildProcess(entry, args, options, &pid)` 起子进程，把 socketpair 的一端按 `{fdName:"agent", fd, next}` 塞进 `fdList`；
3. 读 `{"ready":true}` → 写一条 JSON-RPC 请求 → 读回响应（读超时 3s，探测会阻塞 ArkTS 主线程，别超过系统 6s 看门狗）。

真机日志（`AppConstants.ENABLE_NCP_PROBE=true` 时，ArkTS 转调 `NativeBridge.probeNativeAgent`）：

```
DBX_NATIVE: ncp probe: pid=47197 ready={"ready":true}
  response={"jsonrpc":"2.0","id":2,"result":{"agentProtocolVersion":2,
  "capabilities":["connect","test_connection","metadata","query","transaction","ddl","multi_session"],
  "protocolVersion":2}}
```

构建产物自检：`llvm-readelf -d libdbx_ohos.so | grep NEEDED` 里出现 `libchild_process.so`（NDK sysroot 自带，`-lchild_process` 直接可解析）。
调用线程：头文件只对**回调**版 API 提示"独立线程"，`OH_Ability_StartNativeChildProcess` 本身没有主线程要求 —— 本次是在 ArkTS 主线程经 NAPI 同步调用的；正式传输层若在 tokio 线程里起子进程，这一点仍需实测确认。

### 14.6 还没做的（离"真的能连 Oracle"还差的部分）

1. **传输层接进 `AgentRuntimeClient`**：现在 `AgentRuntimeClient::spawn` 固定用 `spawn_agent_process()` 拿 `std::process::Child` + stdin/stdout 管道（`AgentLaunchSpec{program,args,working_dir}`）。需要把它抽象成 `{ ChildStdio, NcpStream }`：ncp 分支用 `UnixStream`（读写 + 关闭即结束），`kill()` 目前是 `Child::kill`，ncp 下要么用 pid + 信号、要么关 socket 让 agent 自己退。这是下一步主体工作，**每次迭代要重建 46MB `libdbx_ohos.so`（12–31 分钟）**。
2. **其余 agent 铺开**：13 个 Go agent 的 `main()` 结构完全一致（`main.go` 里 `newRuntimeServer()` + `json.NewEncoder(os.Stdout)` 那套），转换是机械的：`main()` 改名为 `runStdioAgent()` + 加一个 `//go:build ohos_ncp` 的 `//export dbxAgentRun` 文件 + 共用 `ohos_ncp_shim.c`。清单：`argo-go cassandra-go etcd-go etcd2-go hive-go iotdb kingbase-go neo4j-go oracle-go rabbitmq rocketmq vastbase-go xugu zookeeper`（hive-go 一个产物覆盖 hive/kyuubi/impala）。另有 `duckdb`/`tdengine` 是 **Rust** agent（`Cargo.toml`），可以做成 cdylib 导出 `Main`，没有 Go 的 TLS/argv 问题。
3. **JDBC/JRE：见 §15（真机测过，三个独立阻塞点 + JIT 权限门）。**
4. **HAP 体积**：`libs/` 现在不压缩，oracle 一个 agent 就 +28MB（→21MB 压缩后）、HAP 已到 90MB；`compressNativeLibs` 是否影响 dlopen 待验证。
5. 探测代码（`ncp_probe.rs` + `NcpProbe.ets`）是诊断用，默认关（`AppConstants.ENABLE_NCP_PROBE=false`）；传输层落地后删掉。

## 15. JDBC「进程内 JVM」可行性：真机测了，**当前不可行**（2026-09-15）

探针：`harmony/tools/ncp_probe/jvm_probe.c`（native child process 入口）+ `sandbox_probe.c`（对照小库）+ `harmony/tools/build_jvm_probe.sh`；ArkTS 侧 `NcpProbe.runJvmProbe()`。结果一行 JSON（真机原文）：

```json
{"sandbox_file":"ELF_OK","sandbox_file_size":8960,
 "bundle_dlopen":"OK","bundle_path":"/data/storage/el1/bundle/libs/arm64/libdbx_jvmprobe.so",
 "sandbox_dlopen_lazy":"FAIL","sandbox_dlopen":"FAIL","sandbox_symbol":false,
 "exec_mmap_sandbox":"mmap exec FAIL errno=13","exec_mmap_bundle":"mmap exec FAIL errno=13",
 "bundle_glibc_libjli_ok":false,
 "mmap_rwx":"FAIL errno=22","mmap_rx_anon":"FAIL errno=22","mprotect_rwx":"FAIL errno=22",
 "mmap_rw":"OK","mprotect_rx":"FAIL errno=22",
 "libjvm":"FAIL Error loading shared library …/jre-21/lib/server/libjvm.so: Invalid argument"}
```

三个独立阻塞点，各有实测证据：

### 15.1 沙箱里的 .so **dlopen 不了**（EINVAL）——与 JIT 权限无关

- 应用把 rawfile 里的 8960 字节小库写进自己的沙箱，子进程再读出来自检：`sandbox_file: ELF_OK, size 8960`（**拷贝是逐字节正确的**，不是我们写坏了文件）。
- 同一进程里 dlopen **bundle** 路径（`/data/storage/el1/bundle/libs/arm64/libdbx_jvmprobe.so`）`OK`；dlopen **沙箱**里那份**内容完全相同**的文件 → `FAIL ... Invalid argument`（`RTLD_NOW`/`RTLD_LAZY` 都一样）。
- 附带量到的一个细节：对文件直接 `mmap(PROT_READ|PROT_EXEC)` 即使对 **bundle 里的库**也返回 `EACCES(13)`（HAP libs 装出来是 0644、没有 x 位，见 §12），而 dlopen 仍成功——说明 OHOS 的加载器走的是"先映射再等平台放行"的路径，不是普通 mmap。
- **含义**：`libjvm.so` 这类"下载/解包进沙箱的 .so"在应用域**根本没机会被加载**。这也是 §12「A′ 方案」在 dlopen 维度上的对应结论：**能 dlopen 的位置只有 bundle libs**。

### 15.2 JIT：默认被禁，但有**正式的权限门**（这是可以申请的正路）

未申请权限时，子进程里所有"造可执行内存"的尝试都被拒：`mmap(RWX)`/匿名 `mmap(RX)`/`mprotect(→RWX)`/`mprotect(→RX)` 全是 `EINVAL(22)`，而普通 `mmap(RW)` 正常。

但鸿蒙把 JIT 做成了受控能力，SDK 里能查到（`toolchains/lib/PermissionDefinitions.json`，均为 `system_grant` + **`system_basic`** + `provisionEnable`）：

| 权限 | since | 用途 |
|---|---|---|
| `ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY` | 14 | 允许申请**可写可执行**内存（通用 JIT） |
| `ohos.permission.kernel.ALLOW_EXECUTABLE_FORT_MEMORY` | 14 | 允许系统 JS 引擎申请 `MAP_FORT` 标识的**匿名可执行内存** |
| `ohos.permission.kernel.ALLOW_USE_JITFORT_INTERFACE` | 16 | 允许使用新的 **JITFort 接口**（设备 API 23，够用） |
| `ohos.permission.kernel.DISABLE_CODE_MEMORY_PROTECTION` | 14 | 关闭系统代码内存保护（路线 B 试过） |

**实测：申请也装不上。** 在 `module.json5` 里加 `ALLOW_WRITABLE_CODE_MEMORY` 后：

```
error: failed to install bundle. code:9568289
error: install failed due to grant request permissions failed.
PermissionName: ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY
```

和 §10 那次 `DISABLE_CODE_MEMORY_PROTECTION` 同一个失败码 —— 因为本项目签名 profile 的 `"acls":{"allowed-acls":[]}` 是空的。

**但这个权限在调试阶段可以"自动申请"——官方有两条明路（2026-09-16 补正，原文见下）**：

1. **DevEco Studio 自动签名代申请**（推荐）：在 `module.json5` 的 `requestPermissions` 里声明该 ACL 权限 → 连真机 → `File > Project Structure > Project > Signing Configs` → 勾 **"Automatically generate signature"/"Associate with registered application"**（需先 Sign In）——**由 DevEco Studio 完成向 AGC 申请受限权限的步骤，开发者可直接使用**（[FAQ：受限权限审批前调试方法](https://developer.huawei.com/consumer/cn/doc/harmonyos-faqs/faqs-appgallery-78)、[自动签名](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing-auto)）。
   - **这三个 JIT 相关权限都在"自动签名支持的 ACL 权限列表"里**（`ide-signing-auto.md`，5.0.3 Release 起）：`ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`、`ohos.permission.kernel.ALLOW_EXECUTABLE_FORT_MEMORY`、`ohos.permission.kernel.DISABLE_CODE_MEMORY_PROTECTION`。
   - 前置条件：DevEco Studio + 已登录的华为开发者账号 + **应用已在 AGC 注册且 bundle name 一致** + 连真机（或将真机注册到 AGC）；"关联注册应用的自动签名"要 DevEco Studio ≥ 6.0.0 Beta5（6.1.1 Beta1 起全球可用）；本机时间要与北京时间一致。
2. **AGC 试用调试 Profile**（权限不在自动签名列表里时用）：提交 ACL 申请后，在审核等待期可创建试用调试 Profile（**有效期 5 天**、每应用最多 5 个），把 ACL 权限加进 Profile、下载后手动签名。

**为什么本机还是装不上**：我们这台是 **纯 CLI（hvigor + 一份已生成的 debug profile，`allowed-acls: []`）**，没有 DevEco Studio GUI、也没有登录的开发者账号，所以自动签名代申请这条路在本机跑不了 —— 必须有人在 DevEco 里点一次自动签名（或从 AGC 下载带 ACL 的 profile 替换 `~/Documents/ohos/config/*.p7b`）才可能装上。

**另外两条硬约束（原文明确）**：
- 声明了权限但没有对应权限证书 → **安装直接失败**（正是我们实测的 `9568289`，[JSVM-API 申请JIT权限指导](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/jsvm-apply-jit-profile) 的"适配注意事项"）。
- **坚盾守护模式开启期间，系统全局禁用 JIT，包括已拿到 ACL 权限的特权应用**。所以"能 JIT"= ACL 权限 + 设备不在坚盾守护模式。
- 部分 ACL 权限**只对受邀应用开放**，非受邀应用在 AGC 上申请不到（同 FAQ）。

结论修正：JIT **不是什么"华为侧审批死路"**，调试阶段有明确的快速通道（自动签名代申请）；真正卡 JDBC 的还是 §15.1 的沙箱 dlopen 与 §15.3 的 glibc JRE —— 这两条与 JIT 权限无关。


### 15.3 就算权限到手，JRE 本身也用不了：dbx 下载的 JRE 是 **glibc** 的

- 官方注册表（`.../agents-latest/agent-registry.json`）里 JRE 21 只有 `linux-aarch64 / linux-x64 / macos-* / windows-*`，**没有 OHOS/musl 平台**。
- 把 `linux-aarch64` 那份（36,074,543B，sha256 与注册表一致）解出来看：`libjvm.so`/`bin/java` 依赖 `libc.so.6`、`libdl.so.2`、`libpthread.so.0`、`librt.so.1`、**`ld-linux-aarch64.so.1`** —— 全是 glibc；而 OHOS 上 `/lib` 只有 `ld-musl-aarch64.so.1`，**没有任何 glibc**。
- 真机复现（把 JRE 的 `lib/libjli.so` 放进 bundle libs 再 dlopen，避开 15.1 的沙箱限制）：
  ```
  JVM_PROBE bundle_glibc_libjli: FAIL
    Error loading shared library ld-linux-aarch64.so.1: (needed by …/libdbx_jli.so)
  ```
- 另外顺带确认：应用自己的"安装 JRE"流程是好的 —— 用 `POST /api/agents/install {"dbType":"dameng"}` 装达梦（Java 驱动）成功，`jre_installed=true`，JRE 落在 `<filesDir>/dbx-data/agents/jre-21/`（`libjvm.so` 在 `lib/server/`）。**下载/解包没问题，问题在加载。**

### 15.4 结论（JDBC 走进程内 JVM）

要让它成立，必须同时满足 **① 有 OHOS/musl 构建的 JRE 21**（现在没有，等于要自己移植/编译 OpenJDK for OHOS）、**② 该 JRE 放进 HAP `libs/`**（沙箱里的 dlopen 被拒；可 `libjvm.so` 25MB + jimage 等 ~96MB，HAP 会暴涨）、**③ 想要性能还得拿到 AGC 的 JIT 受限 ACL 权限**（否则只能 `-Xint` 纯解释执行）。

三条都成立才"能用"，其中 ①③ 都不在应用侧可控范围内。**所以 JDBC 驱动在 OHOS 上当前没有可行路线**（既不能 exec 子进程、也不能进程内 JVM），这一点比 §10 的结论更硬：不是权限单点，而是权限 + libc + 加载位置三重卡死。

**没有白测的部分**：§15.1 反过来把方案 D 的边界钉死了 —— 「agent 产物必须打进 HAP `libs/`」是硬约束（这解释了为什么 §14 的 oracle 能跑：它是随 HAP 装进去的）；§15.2 给出了 JIT 的正规申请入口（如果将来真要做原生 JIT 类功能，先走 AGC 申请）。


## 16. 现状：应用侧已还原，只留研究记录与脚手架（2026-09-15）

决定：**先把本次改动还原，驱动适配留到以后再做**。当前仓库状态如下（后续会话照这个继续）。

### 16.1 已还原（回到 1.3.3 发布基线，应用行为与发布版一致）

- ArkTS：`Constants.ets`（`ENABLE_NCP_PROBE` 开关）、`entryability/EntryAbility.ets`（探针调用）、`native/NativeBridge.ets`（`probeNativeAgent`）、`services/NcpProbe.ets`（整个文件删掉）。
- `entry/src/main/module.json5`：申请 JIT 权限的实验已撤回，应用可正常安装（此前加 `ALLOW_WRITABLE_CODE_MEMORY` 会导致 `9568289` 装不上）。
- `entry/libs/arm64-v8a/`：只留 `libdbx_ohos.so`，且已 checkout 回提交版本（**不再含** `probeNativeAgent`，`DT_NEEDED` 里**不再有** `libchild_process.so`）；删除 `libdbx_agent_oracle.so`(28MB)、`libdbx_jvmprobe.so`。
- `entry/src/main/resources/rawfile/ncp-probe/`（沙箱对照组小库）删除 → HAP 体积回到 ~69MB。
- submodule `crates/dbx-ohos/src/lib.rs`：撤掉 NAPI 导出（`mod ncp_probe;` + `probe_native_agent`）。

### 16.2 保留（研究记录 + 可复现脚手架，**均不参与应用构建**）

| 文件 | 作用 |
|---|---|
| `docs/ohos-agent-exec-denied.md` §13–§15 | 全部结论与真机证据 |
| `AGENTS.md` P0′ 更新 ④/⑤ | 速查结论（含"别再从头试"的清单） |
| `harmony/tools/ncp_spike/` + `build_ncp_spike.sh` | native child process 可行性 spike（§13） |
| `harmony/tools/build_agent_cshared.sh` + `go_ohos_overlay.py` | Go agent → c-shared，含两处 musl 运行时补丁（§14） |
| `harmony/tools/ncp_probe/{jvm_probe.c,sandbox_probe.c}` + `build_jvm_probe.sh` | JDBC/进程内 JVM 可行性探针（§15） |
| `harmony/tools/build_hnp.py` | HNP 打包器（§9 已证伪，留档） |
| submodule `agents/drivers/oracle-go/{main.go,ohos_ncp.go,ohos_ncp_shim.c}` | oracle agent 的 c-shared 入口（`main()` 拆出 `runStdioAgent()`）+ `Main`/fd→0,1/TLS helper |
| submodule `crates/dbx-ohos/src/ncp_probe.rs` | Rust 侧 socketpair + `OH_Ability_StartNativeChildProcess` + JSON-RPC 往返（**未被 `lib.rs` 引用，不参与编译**） |

### 16.3 下次继续的第一步（§14.6 的 1–3）

1. `AgentRuntimeClient` 加传输抽象 `{ ChildStdio, NcpStream }`（含 `kill()` 语义）；
2. OHOS 上原生 agent 的 `AgentLaunchSpec` 从沙箱可执行文件路径改成 **`libdbx_agent_oracle.so:Main`**（产物要重新 `./harmony/tools/build_agent_cshared.sh oracle-go` 编回 libs）；
3. 驱动管理把内置驱动显示成"已安装 + 内置版本"（别再走下载/签名流程）；
4. 之后用一个真的 Oracle 实例验完整连接（起子进程 + handshake 不需要数据库）。

**注意**：第 1 步要重建 46MB 的 `libdbx_ohos.so`（12–31 分钟/次），建议 1–3 一起改完再编。

## 17. 方案 D 生产化：oracle 已在应用内跑通（2026-09-17）

§16.3 的 1–2 已实施并真机验证。**同一个 `/api/connection/test` 请求，从 `Permission denied (os error 13)` 变成了 `dial tcp 127.0.0.1:1521: connect: connection refused`** —— 后者说明 appspawn 子进程起来了、`ready` + `handshake` 通过、go-ora 真的去拨号了（本机没有 Oracle 监听）。完整报告见 `docs/ohos-oracle-driver-report.md`。

改动（与 §16.3 的设想略有不同，更小）：

1. **新增 `crates/dbx-core/src/db/agent_ncp.rs`**：`#[link(name="child_process")]` 调 `OH_Ability_StartNativeChildProcess` / `OH_Ability_KillChildProcess`，建 `socketpair` 并把子端放进 `fdList`。`NcpChild::kill()` 用 `shutdown` + `KillChildProcess`（appspawn 子进程不是本进程的 POSIX 子进程，不能 `waitpid`），`wait()` 直接返回（关闭 socket 即让 agent 读到 EOF 自行退出）。
2. **`db/agent_driver.rs`**：新增 `AgentProcess { Child, Ncp }` 与 `SpawnedAgent { process, stdin: Box<dyn Write+Send>, stdout/stderr: Box<dyn Read+Send> }`；`AgentRuntimeClient` 与 `AgentDriverClient` **都**改用 `spawn_agent_io()`（前者是连接路径，后者是驱动管理器"运行/重启"的 daemon 路径）。`AgentLaunchSpec` 加 `ncp_entry: Option<String>` + `AgentLaunchSpec::ncp()`。
3. **`agent_manager.rs` + `agent_service.rs`**：`ohos_bundled_agent_library(driver_key)` 识别内置驱动（已知列表 + 从 `/proc/self/maps` 推导 HAP `libs/` 目录后探测），在 `resolve_agent_launch_spec_with_extra_args()` 最前面短路成 `AgentLaunchSpec::ncp("libdbx_agent_X.so:Main")`；`is_driver_installed()` 与 `build_agent_list()` 把内置驱动报成"已安装 / bundled"，`uninstall_agent_driver()` 拒绝卸载内置驱动。**通用探测意味着以后加驱动不用重建 Rust `.so`**（已用假 `.so` 验证：见报告 §6.6）。
4. 非 OHOS 目标零影响：NCP 代码全在 `#[cfg(target_env = "ohos")]` 内。

实测数据：
- `libdbx_agent_oracle.so` 28,360,272 B（`NEEDED` 只有 `libc.so`，无 TLS 重定位，导出 `Main`）；
- `libdbx_ohos.so` 46,507,712 B（`NEEDED` 含 `libchild_process.so`）；release 构建 **45m42s**（比 §16 估的 12–31 分钟更久，首次全量 LTO）；
- signed HAP 90,147,161 B（agent 压缩后 20.9MB）；
- 子进程 `io.github.getz110.dbx:Native_libdbx_agent_oracle0`，uid 与应用相同；hilog 里 `CODE_SIGN [XpmIoctl] … Permission denied (ignore)` 是 BinSec 的非致命日志；
- 失败后运行时自动 `status=stopped`，子进程退出，无残留。

**未做**：① 其余 13 个 Go agent 铺开（有了通用探测后，加驱动只需重建 HAP、不用重建 Rust `.so`；每个 agent 压缩后 +20~28MB）；② 前端 dist 未重建，UI 里内置驱动会显示"已安装"但没有单独的"内置"标签（后端已上报 `bundled:true`，前端旧版本忽略该字段）；③ 完整 Oracle 实例的 `SELECT 1 FROM dual`（本机没有数据库）。

**已补验**（解锁设备后，2026-09-17）：`startup_smoke.sh --mode warm` **12/12 PASS**（`modules loaded` 359ms / FCP 1216ms，`Local service ready` 121ms）；重启应用后重跑 Oracle 请求仍是 `dial tcp 127.0.0.1:1521: connect: connection refused`，子进程 `Native_libdbx_agent_oracle0` 稳定复现。**启动与连接链路都无回归。**

**驱动运行时启停也已验证**（第二次 rebuild 把 `AgentDriverClient` 一并接入 NCP；此前 `restart` 报 `Failed to spawn agent process libdbx_agent_oracle.so:Main: No such file or directory`）：`POST /api/agents/runtime/restart {"runtimeId":"agent:oracle"}` → `{"ok":true}`，`running_count=1`、`pid=53176`、`ps` 见子进程；`POST …/runtime/stop` → `{"ok":true}`，`stopped`、pid=None、**子进程退出无残留**（`NcpChild::kill()` + reaper 语义成立）。

**内置驱动识别已通用化**（第三次 rebuild）：驱动列表把内置驱动报成 `installed=true / bundled=true / update_available=false`，卸载返回"随应用分发"的明确错误；探测目录从 `/proc/self/maps` 推导，**以后加驱动只需把 `.so` 放进 `entry/libs` 重建 HAP，不用重建 Rust `.so`**。用假 `libdbx_agent_cassandra.so`（14B）验证过探测生效（报告 §6.6）。

## 18. 自签名 / 应用证书签名到底行不行：真机 A/B/C 对照（2026-09-17）

针对"是不是自己签名就行、是不是要 DevEco 签名、还要不要别的权限"这个问题，做了一次**同一槽位的三级对照实验**：把三种版本的同一个 oracle agent 依次通过 `/api/agents/import-driver` 导入成 **`cassandra`**（非内置驱动 → 必然走沙箱 `execve` 路径），再 `POST /api/connection/test` 触发 spawn。

| 版本 | 怎么来的 | `spawn_agent_process` 结果 |
|---|---|---|
| 未签名 | 上游 release 原始 ELF | `Permission denied (os error 13)` = **EACCES** |
| 自签名 | `binary-sign-tool sign -selfSign 1`（§7 的命令） | `Operation not permitted (os error 1)` = **EPERM** |
| **应用证书签名** | `binary-sign-tool sign`（localSign：`-appCertFile <本应用 .cer> -keystoreFile <本应用 .p12> -profileFile <本应用 .p7b> -keyAlias debugKey`）；`display-sign` 显示的是 **Huawei CBG Developer Relations CA G2 签发的开发证书**，不再是 "self-sign" | `Operation not permitted (os error 1)` = **EPERM**（与自签名完全一样） |

关键 hilog（应用证书签名那次，`hdc hilog | grep code_protect`）：

```
W C05610/code_protect/BSS: [BinSec][svc:node_task][ExecuteTemplate]:node based task failed. node: CheckSigned, ret: 1017604106
W C05610/code_protect/BSS: [BinSec][svc:bin_common][FillPermissionSection]:permission section not exist
W C05610/code_protect/BSS: [BinSec][svc:bin_common][FillElfModuleJson]:empty module.json buf. maybe the permission section is empty
E C05610/code_protect/BSS: [BinSec][svc:BL][LoadBinCtrlAndManage]:
    parent process cannot load this binary. binaryType: 5, isCustomSandbox: 0, isAllowExt: 0
W C05610/code_protect/BSS: [BinSec][svc:node_task][ExecuteTemplate]:node based task failed. node: LoadBinCtrlAndManage, ret: 1017604138
```

结论（推翻/修正 §3.1 的旧假设）：

1. **签名确实生效了**：未签名 `EACCES` → 签名后 `EPERM`，说明 `CheckSigned` 那一关过了；换成**应用自己的证书**也是一样。
2. **但拒绝点不是签名身份，而是 BinSec 的二进制管控 `LoadBinCtrlAndManage`**：`parent process cannot load this binary`，字段 `binaryType: 5, isCustomSandbox: 0, isAllowExt: 0`。也就是说：只要 ELF 落在应用数据目录、由应用进程 `execve`，普通应用就会被"二进制管控"拒绝——**签谁的名字都一样**。
3. 所以"自己给驱动签名"这条路（无论自签名还是应用证书）**不成立**；"需要 DevEco 签名"的说法也不准确——DevEco/AGC 能给的是**权限（ACL）或 HNP 授权**，不是"签一下 ELF 就能跑"。

**真正可能解锁的两条路**（都还没验证）：

| 路线 | 依据 | 门槛 |
|---|---|---|
| **HNP**（把 ELF 打成 HNP 随 HAP 安装） | 系统把 HNP 内容登记进允许列表；Termony / DevBox / CodeArts 都用它跑 `bash`/`busybox` | 需要能产出合法 HNP 的签名链路（华为二进制证书扩展 + `signMap`）；本机 hvigor 插件不含 hnp 逻辑，已证伪（§9） |
| **`ohos.permission.CUSTOM_SANDBOX`** | 官方描述："允许应用将沙箱类型改为动态沙箱"，`system_basic` / `availableType: NORMAL` / **`provisionEnable: true`** / since 18；日志里的 `isCustomSandbox: 0` 正好对应这个开关；华为自家终端 HiShell 就申请了它 | 需要 AGC 在签名 profile 的 `allowed-acls` 里放行（DevEco 自动签名可代申请）。**能否批、批了能否解锁 `LoadBinCtrlAndManage`，均未验证** |

顺带排除的两条：
- `ohos.permission.kernel.DISABLE_CODE_MEMORY_PROTECTION` 管的是**运行时代码完整性保护（XPM 写污点 / 可执行内存）**，不是二进制管控；本次拒绝发生在 `LoadBinCtrlAndManage` 节点，**大概率不解决**（未验证，但证据方向明确）。它和 `ALLOW_WRITABLE_CODE_MEMORY` 只对 JIT 有意义。
- **`atm perm -g` 绕不过去**：设备上实测 `Error: Permission '…' is not requested by the application.` —— 权限必须先在 `module.json5` 里声明，而声明了没有 profile ACL 又会装机失败（`9568289`）。所以"不重签名、运行时授权"行不通。

补充记录：`binary-sign-tool` 的 localSign 模式**需要 keystore 明文口令**，而 DevEco 把 `build-profile.json5` 里的口令加密成 `00000020…`；本次是用 hvigor 自带的 `hvigor-ohos-plugin/src/utils/decipher-util.js`（`DecipherUtil.decryptPwd` + `~/Documents/ohos/config/material/{fd,ce,ac}`）在本地 Node 进程里解密后传入签名工具的（口令不打印、不落盘）。这说明"用应用证书签 ELF"在开发机上是**可复现的**——只是复现出来也没用。

### 18.1 `CUSTOM_SANDBOX` 这条路也走不通（2026-09-17 实测 + 设备旁证）

顺着 `LoadBinCtrlAndManage` 日志里的 `isCustomSandbox: 0` / `isAllowExt: 0`，试了官方可能解锁它的受限权限 `ohos.permission.CUSTOM_SANDBOX`（"允许应用将沙箱类型改为动态沙箱"，system_basic / availableType NORMAL / **provisionEnable: true** / since 18）。结论：**当前拿不到，而且拿到了大概率也没用。**

1. **没有 profile ACL 就是装不上**（再次确认）：`module.json5` 声明 `CUSTOM_SANDBOX` 后，用现有 profile 装机：
   `code:9568289 install failed due to grant request permissions failed. PermissionName: ohos.permission.CUSTOM_SANDBOX`（失败不会破坏已装版本，重新 `aa start` 即可恢复）。
2. **`atm perm -g` 绕不过**：设备实测 `Error: Permission '…' is not requested by the application.` —— 必须先声明；而"声明 + 无 ACL" = 上面那条安装失败。死循环。
3. **DevEco Studio 5.1.7 不会代申请它**：点 `Signing Configs → 生成签名文件` 只重写了 `build-profile.json5`（两个密码密文变了），**`.p7b` mtime 不变、`allowed-acls` 仍只有 `READ_WRITE_DOCUMENTS_DIRECTORY`**。官方文档也写明：用 ACL 权限的场景要走**手动签名**（先在 AGC 申请 ACL，再申请带该 ACL 的 Profile）。
4. **AGC 自助入口在本机账号上不存在**：该账号「APP 与元服务」为空（0 个应用），没有「项目设置 → ACL权限」可进；ACL 申请需要先注册应用/走审批，成本陡增。
5. **最关键的旁证：能跑原生二进制的应用靠的是 HNP，不是沙箱 exec**。设备上 `atm dump -t -p ohos.permission.CUSTOM_SANDBOX` 列出 7 个持有者，其中非华为的第三方应用（`com.mikannqaq.mkcode`、`com.develop.opensource.ohpcd.bitfun`、`com.tencent.workbuddy`）**`bm dump` 里全都有 `hnpPackages`**；`com.mikannqaq.mkcode` 还是 `appPrivilegeLevel: normal`：
   ```json
   "hnpPackages": {"electron": [
     {"independentSign": true,  "package": "electron.hnp",     "type": "private"},
     {"independentSign": true,  "package": "rg.hnp",           "type": "private"},
     {"independentSign": false, "package": "unzip.hnp",        "type": "private"},
     {"independentSign": true,  "package": "mkcode-agent.hnp", "type": "private"}]}
   ```
   而 HNP 对我们被 §9 的两个硬门槛卡死（HAP 签名证书缺华为二进制证书扩展 OID `1.3.6.1.4.1.2011.2.376.1.8`；签名里缺 `signMap`，本机 hap-sign-tool/hvigor 无 HNP 逻辑）。所以 `CUSTOM_SANDBOX` 更像是**配合 HNP 的动态沙箱**，单独批下来也未必能过 `LoadBinCtrlAndManage`。

**最终结论（三次实验 + 设备旁证后）**：应用**直接 `execve` 沙箱里的 ELF 这条路在 HarmonyOS 6 上对普通应用是封死的**——未签名 `EACCES`、自签名/应用证书签名 `EPERM`、受限 ACL 拿不到（且大概率无效）。能跑原生代码的只有两条：**HNP**（需要华为"二进制证书"与支持 HNP 的签名工具链）和 **native child process**（本仓库采用，appspawn `dlopen` HAP `libs/` 的 `.so`，不需要任何授权）。
