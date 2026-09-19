# HarmonyOS JIT 权限（受限 ACL）：申请流程与真机实测

> 记录时间：2026-09-19；设备 HUAWEI MateBook Pro（HarmonyOS 6，targetSdk 6.1.0(23)），
> **主机与设备为同一台机器**（`hdc tconn 127.0.0.1:43817`）。dbx-ohos 1.4.1 / 上游 dbx 0.6.9。
>
> 上下文：这是 `docs/ohos-agent-exec-denied.md` 里 JDBC「进程内 JVM」方案（E 方案）的第 ② 号卡点。
> 第 ①（沙箱 `.so` 不能 dlopen）和第 ③（dbx 下载的 JRE 是 glibc）**在本轮没有解决**，见 §6。
>
> 同类先例：[VintagePomeloPro](https://github.com/yifengling0/VintagePomeloPro)（Wine + Box64 移植到 HarmonyOS）
> 在 `entry/src/main/module.json5` 里声明了同一条权限，并在
> [`docs/OHOS_MMAP_ANALYSIS.md`](https://github.com/yifengling0/VintagePomeloPro/blob/main/docs/OHOS_MMAP_ANALYSIS.md)
> 里给出了 app 沙箱的 mmap 对照表。

## 0. 结论（TL;DR）

- **权限名**：`ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`（`system_grant` + `system_basic` + `isKernelEffect`，since API 14）。
- **获取方式不是代码技巧**：走官方「受限开放权限（ACL）」申请，把权限写进**签名 profile 的 `acls.allowed-acls`**。
  只在 `module.json5` 声明、profile 里没有 ACL → 装机直接 `9568289 install failed due to grant request permissions failed`。
- **2026-09-19 已拿到**（AGC「ACL权限申请」→ 试用调试 Profile），真机实测：
  **匿名 RWX / `mprotect`→RWX / 写入机器码并 `mprotect`→RX 后真的执行成功（返回 42）**，见 §4。
- **官方限制**：这条权限只对 **tablet / 2-in-1** 开放；软件包 `deviceTypes` 超出该范围会导致**安装失败**。
  本仓库 `entry/src/main/module.json5` 现在是 `["tablet","2in1"]` ✅（**别为了手机往里加 `phone`**）。
- **E 方案现状**：② 已解决；① 沙箱 `dlopen` 仍被拒；③ 仍缺 musl/aarch64 的 JRE。

## 1. 三条 kernel 权限与规则

| 权限 | grantMode | level | since | 用途 |
|---|---|---|---|---|
| `kernel.ALLOW_WRITABLE_CODE_MEMORY` | system_grant | system_basic | 14 | 申请可写可执行匿名内存（**通用 JIT / JVM 要的就是它**） |
| `kernel.DISABLE_CODE_MEMORY_PROTECTION` | system_grant | system_basic | 14 | 关闭运行时代码完整性保护（跨平台框架） |
| `kernel.ALLOW_EXECUTABLE_FORT_MEMORY` | system_grant | system_basic | 14 | 系统 JS 引擎申请 `MAP_FORT` 匿名可执行内存 |
| `kernel.ALLOW_USE_JITFORT_INTERFACE` | — | — | 16 | 新的 JITFort 接口，**不在自动签名代申请列表**，须 AGC 人工申请 |

申请规则（官方 + 实操记录）：

- 一次最多勾选 **30 条**权限；**本批审核结束前不能提交新申请**；每条审批约 **3 个工作日**；
- 海外仅**亚太 / 欧洲**地区开放；
- 审核期可用 **试用调试 Profile** 提前试用（见 §2.4）；
- 申请受限权限时**务必在申请发布 Profile 的「添加Profile页面」一并勾选**，否则上架审核会被驳回。

## 2. AGC 申请流程

### 2.1 入口（**不是「证书」页**）

```
AGC → 开发与服务 → 选中项目/应用 → 项目设置 → 「ACL权限」页签
  → 勾「我已知晓」→ 勾选权限 → 申请 → 填使用场景/申请原因（+可选附件）→ 提交
```

> ⚠️ 若**找不到「ACL权限」页签**，官方要求**重新创建新的 HarmonyOS 应用/元服务**。
> 这也是本项目早期在 AGC 里"没有 ACL 自助入口"的原因。

### 2.2 申请文案（可直接复用）

应用 = DBX，包名 `io.github.getz110.dbx`。

**① `ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`**（四个字段都要填）：

```
使用场景：DBX 是数据库客户端，应用内嵌 JVM 运行时以加载并执行 Oracle、达梦、DB2 等基于 JDBC 的
数据库驱动，运行期需对热点字节码做 JIT 即时编译。
申请原因：JVM 的 JIT 必须在运行期申请可写可执行（RWX / RW→RX）匿名内存来存放编译后的机器码，
这是 JVM 的基本运行机制；无该权限 JIT 无法分配可执行内存，该类数据库驱动无法运行，且无替代方案。
个人邮箱：<你的真实邮箱>
承诺内容：承诺在申请权限后，不会用于应用内热更新，不会用于增加任意未经应用市场审核的新功能。
如若违反上述规则，华为有权无条件撤销对应权限，且无需承担任何责任，本人/单位承担全部责任。
```

（若 256 字超限，把"申请原因"压成一句：`JVM 的 JIT 运行期必须在可写可执行匿名内存中生成机器码，无该权限 JIT 无法工作，无替代方案。`）

**② `ohos.permission.kernel.DISABLE_CODE_MEMORY_PROTECTION`**（可选，非 JVM 刚需）：

```
申请原因：应用内嵌跨平台 JVM 运行时，该运行时在启动与运行期会自行生成、加载并执行代码页
（JIT 代码缓存及运行时自身代码），其保护对象与系统代码完整性校验不同；需关闭应用运行时代码
完整性保护，避免跨平台运行时在执行自生成代码时被系统代码保护机制拦截，保证 JVM 正常运行。
```

### 2.3 证书怎么选

- 「证书」页的「新增证书」**不是 ACL 入口**，它只是签名链的第一步；
- **证书类型**：`调试证书`（本机真机调试，需先在「设备」页注册 UDID，最多 100 台）或 `发布证书`（上架，不需要设备）；
- **关键**：申请 Profile 时选的证书必须和你**本机拥有配套 `.p12` 密钥库**的那张一致。
  本项目用 DevEco 自动签名生成的那张：**`auto_debug_30086000681415814`**
  （`developer-id = 30086000681415814`，本机 `~/Documents/ohos/config/default_dbxohos*.p12`，`keyAlias = debugKey`）。
  **别选别的项目的证书（如 `hokit_debug`）**——没有配套密钥，签不了。

### 2.4 试用调试 Profile

- **创建入口只有提交 ACL 申请后的那个弹窗**（关掉就没了；若没弹，检查账号角色是否有"访问调试类证书"权限）；
- 类型固定 `试用调试`；**有效期 5 天**；每应用最多 **5 个**；**只能选调试证书**；最多绑 **100 台**调试设备；
- **"申请中 + 已获取"的 ACL 会全部写入 Profile**（不能手动挑）；
- Profile 名称用 **ASCII**（如 `dbx-jit-trial`）。签名工具会把中文名变成 `??????`，报 `11012002 File not exist`；
- 建完点「下载」拿 `.p7b`。**ACL 有变化必须重新创建 Profile**。

### 2.5 设备

- 「设备」页注册 UDID（`hdc shell bm get --udid`）；
- **已绑定 Profile 的设备不能直接删**（提示"部分设备已被 HarmonyAppProvision使用，无法删除"），
  要先去 Profile「编辑设备」解绑；删除后 **一年内会置灰且仍占设备名额**，满一年才自动清除。
  → **纯粹为了把类型从"手机"改对，不值得删**；Profile 只按 UDID 绑定，类型是展示字段。

## 3. 校验下载的 `.p7b`

`p7b` 是 PKCS#7，里面嵌了明文 JSON（profile 内容）。用下面脚本核对：

```python
# 用法: python3 check_p7b.py <profile.p7b>
import json, sys, subprocess, datetime
d = open(sys.argv[1], 'rb').read()
i = d.find(b'{"version-name"'); depth = 0
for j in range(i, len(d)):
    if d[j:j+1] == b'{': depth += 1
    elif d[j:j+1] == b'}':
        depth -= 1
        if depth == 0: js = json.loads(d[i:j+1].decode()); break
bi = js['bundle-info']
print('bundle-name :', bi.get('bundle-name'))
print('developer-id:', bi.get('developer-id'))
print('type        :', js.get('type'), '| issuer:', js.get('issuer'))
print('device-ids  :', js.get('debug-info', {}).get('device-ids'))
print('allowed-acls:', js.get('acls', {}).get('allowed-acls'))
v = js['validity']
print('valid until :', datetime.datetime.fromtimestamp(v['not-after'], datetime.UTC))
open('_c.cer', 'w').write(bi.get('development-certificate', ''))
print(subprocess.run(['openssl','x509','-in','_c.cer','-noout','-subject','-fingerprint','-sha256'],
                     capture_output=True, text=True).stdout.strip())
```

**校验清单**：`bundle-name` 与 `AppScope/app.json5` 一致 → `developer-id` 对应你选的那张证书 →
`development-certificate` 指纹与本机 `.p12` 一致（否则覆盖安装会 `9568332 install sign info inconsistent`）→
`device-ids` 含目标设备 → `allowed-acls` 含目标权限。

**2026-09-19 本次实测值**（文件：`/storage/Users/currentUser/Documents/证书/dbx-jit-trialDebug.p7b`）：

```
bundle-name : io.github.getz110.dbx
developer-id: 30086000681415814
type        : debug | issuer: app_gallery
device-ids  : [9152E396…D2D2C, 46C348C0…298506]
allowed-acls: ['ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY']
valid until : 2026-09-24 14:46 UTC   （创建后 5 天）
development-certificate SHA-256: 8B:5A:29:B2:39:D5:11:71:D9:48:29:EE:1A:BF:9E:F7:BC:DD:F0:8F:7A:66:EE:48:FE:97:F7:04:47:18:4E:2C
```

> 注：这份试用 Profile 的 `allowed-acls` **没有** `READ_WRITE_DOCUMENTS_DIRECTORY`，这是正常的：
> 该权限是 `user_grant` + **normal** 级（见 SDK `PermissionDefinitions.json`），**不需要 ACL**，
> 靠运行时 `requestPermissionsFromUser` 授权（`FilePickerBridge` 已实现），不会触发 `9568289`。

## 4. 真机 JIT 探针实测

### 4.1 方法：把探针伪装成"内置 agent"

`agent_manager::ohos_bundled_agent_library(key)` 会去探测 HAP `libs/` 里的 `libdbx_agent_<key>.so`，
且 `driver_runtime::restart_driver_runtime` **不校验 key 是否在驱动商店里**。所以：

1. 把探针编成 **`libdbx_agent_jvmprobe.so`**（源码 `harmony/tools/ncp_probe/jvm_probe.c`，导出 `Main`）；
2. 丢进 `entry/libs/arm64-v8a/`，`assembleHap` + 装机；
3. `POST /api/agents/runtime/restart {"runtimeId":"agent:jvmprobe"}` → appspawn 以**应用身份**拉起它；
4. 探针结果既写回 fd（会出现在 API 的 `detail` 里），也打 hilog `JVM_PROBE ...`。

**好处：不需要重建 46MB 的 `libdbx_ohos.so`**，只花一次 ~21s 的 `assembleHap`。

### 4.2 复现步骤

```bash
# 1) 编探针（NDK 用 Harmonybrew 那份，deveco_tools 里的 clang 不可执行）
NDK=/storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_1/native
$NDK/llvm/bin/aarch64-unknown-linux-ohos-clang --target=aarch64-linux-ohos \
  --sysroot=$NDK/sysroot -shared -fPIC -O2 -I$NDK/sysroot/usr/include \
  -o harmony/dbxohos/entry/libs/arm64-v8a/libdbx_agent_jvmprobe.so \
  harmony/tools/ncp_probe/jvm_probe.c \
  -L$NDK/sysroot/usr/lib/aarch64-linux-ohos -lhilog_ndk.z
$NDK/llvm/bin/llvm-nm -D --defined-only <产物> | grep -w Main   # 必须看到 Main

# 2) 临时改两处（见 §6 的清单），assembleHap + 装机
export DEVECO_SDK_HOME=/storage/Users/currentUser/deveco_tools/sdk
cd harmony/dbxohos && node $DEVECO_SDK_HOME/../hvigor/bin/hvigorw.js \
  --mode module -p product=default --no-daemon assembleHap
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap

# 3) 启动 app 后直接打本机 4224（不要 fport，见 §5.1）
hdc shell "aa force-stop io.github.getz110.dbx"
hdc shell "aa start -a EntryAbility -b io.github.getz110.dbx"
sleep 10
curl -s -X POST http://127.0.0.1:4224/api/agents/runtime/restart \
  -H 'Content-Type: application/json' -d '{"runtimeId":"agent:jvmprobe"}'
```

### 4.3 结果（2026-09-19，原始 JSON）

```json
{
  "bundle_dlopen": "OK",
  "bundle_path": "/data/storage/el1/bundle/libs/arm64/libdbx_agent_jvmprobe.so",
  "sandbox_dlopen": "FAIL", "sandbox_symbol": false,
  "exec_mmap_bundle": "mmap exec FAIL errno=13",
  "mmap_rwx": "OK", "mmap_rx_anon": "OK",
  "mprotect_rwx": "OK", "mmap_rw": "OK", "mprotect_rx": "OK",
  "exec_result": 42,
  "libjvm": "skipped", "sandbox_file": "skipped",
  "done": true
}
```

| 字段 | 结果 | 含义 |
|---|---|---|
| `mmap_rwx` | **OK** | 匿名 RWX 可申请（ACL 生效） |
| `mmap_rx_anon` | **OK** | 匿名 RX 也可 |
| `mprotect_rwx` | **OK** | RW → RWX 不再被拦 |
| `mprotect_rx` + `exec_result=42` | **OK** | 先 RW 写入 `mov w0,#42; ret`，`mprotect` 成 RX 后**真的跳进去执行，返回 42** → JIT 全链路可用 |
| `exec_mmap_bundle` | **FAIL errno=13** | 文件映射 + `PROT_EXEC` 仍 EACCES（与 VintagePomeloPro 的 mmap 报告一致） |
| `sandbox_dlopen` | **FAIL** | 沙箱里的 `.so` 依旧不能 dlopen（① 号卡点未变） |
| `bundle_dlopen` | **OK** | HAP `libs/` 里的 `.so` 可以 dlopen → NCP 路径可行 |

`libjvm` / `sandbox_file` 为 `skipped` 是因为本轮没传 `entryParams`（只测 JIT，符合预期）。

### 4.4 结论

- **② JIT 卡点解决**：拿到 ACL 后，应用进程（含 NCP 子进程）可以正常做 JIT。
- ①③ 仍未解决，见 §6。

## 5. 两个操作坑

### 5.1 `hdc fport tcp:4224 tcp:4224` 在这台机器上会自环

设备就是本机，host / device 共用 loopback。设置 `tcp:4224 → tcp:4224` 转发后，
转发器自己占住 `127.0.0.1:4224`，app 绑不上、`curl` 连上却永远收不到响应
（`/proc/net/tcp` 里会堆几百上千条 TIME_WAIT）。

**正确做法：撤掉转发，直接 `curl http://127.0.0.1:4224/...`。**

```bash
hdc fport rm tcp:4224 tcp:4224
curl -s http://127.0.0.1:4224/api/health           # -> ok
# 确认监听者是 app uid（不是 hdc 转发器）：
hdc shell "cat /proc/net/tcp /proc/net/tcp6 | awk '\$4==\"0A\"' | grep -i ':1080'"
```

> 注：`ohos_cdp.sh` 用的是 `fport tcp:<port> localabstract:<sock>`（unix socket），不受影响。

### 5.2 探针 `.so` 的命名约定

必须叫 `libdbx_agent_<key>.so` 才会被 `ohos_bundled_agent_library()` 探测到，
并且**导出 `Main`**（`llvm-nm -D` 验证）。验证脚本：`harmony/tools/verify_agent_libs.sh`（只认官方 16 个 key）。

## 6. 拿到正式 ACL 之后的后续工作

**换 profile 时必须三处联动，缺一处就出问题：**

| 位置 | 动作 | 不做的后果 |
|---|---|---|
| `harmony/dbxohos/build-profile.json5` → `app.signingConfigs[0].material.profile` | 指向**正式** debug/release Profile（含 ACL） | 试用 Profile 5 天到期后应用起不来 |
| `harmony/dbxohos/entry/src/main/module.json5` → `requestPermissions` | 加回 `ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY` | 权限不生效（没声明就没有） |
| 签名用的 `.p12` / 证书 | 与 Profile 里的 `development-certificate` 同源 | 覆盖安装报 `9568332 install sign info inconsistent` |

> **顺序**：先确认（或申请）Profile 里已含该 ACL，再把权限加回 `module.json5`。
> 反了会 `9568289`。

Checklist：

- [ ] AGC「项目设置 → ACL权限」里 `ALLOW_WRITABLE_CODE_MEMORY` 状态 = **已通过**；
- [ ] 申请**正式** Profile（发布 Profile 的「添加Profile页面」也要勾该受限权限，否则上架驳回）；
- [ ] 下载 `.p7b`，用 §3 脚本核对 `allowed-acls` / `device-ids` / 证书指纹；
- [ ] 替换 `build-profile.json5` 的 `profile` 字段；**保留一份旧 profile 备份**；
- [ ] `module.json5` 加回权限 → `assembleHap` → `hdc install -r` → `curl /api/health` 正常；
- [ ] 用 §4 的探针复验 `mmap_rwx = OK` / `exec_result = 42`；
- [ ] 然后才谈 ①③：

**① 沙箱 `.so` 不能 dlopen** —— 探针已再次确认 `sandbox_dlopen = FAIL`。
  可行路线：把 `libjvm.so` 及其依赖放进 HAP `libs/arm64-v8a/`，由 NCP 子进程 dlopen
  （与 `libdbx_agent_*.so`、VintagePomeloPro 的 `box64.so` 同一套路）。代价是 HAP 体积。

**③ JRE 是 glibc、OHOS 只有 musl** —— 需要一个 **aarch64 + musl** 的 JVM 构建；
  `exec_mmap_bundle = errno 13` 说明**不能**靠"文件映射成可执行页"绕过 dlopen 限制。

## 7. 参考

- 华为：[受限开放权限](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/restricted-permissions)、
  [申请受限权限 / ACL 声明](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/declare-permissions-in-acl.md)、
  [删除设备](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/agc-help-delete-device-0000002248111074)
- 实操记录（AGC 页面/规则/试用 Profile 细节）：[申请ACL权限](https://blog.csdn.net/wangsen927/article/details/164194033)、
  [设备删除](https://harmonyosdev.csdn.net/6a8cc97010ee7a33f29e61c2.html)
- 先例：[VintagePomeloPro](https://github.com/yifengling0/VintagePomeloPro) 的
  [module.json5](https://github.com/yifengling0/VintagePomeloPro/blob/main/entry/src/main/module.json5)、
  [OHOS_MMAP_ANALYSIS.md](https://github.com/yifengling0/VintagePomeloPro/blob/main/docs/OHOS_MMAP_ANALYSIS.md)
- 本仓库：`docs/ohos-agent-exec-denied.md`（§15 JDBC、§17 NCP 生产化）、
  `harmony/tools/ncp_probe/jvm_probe.c`、`harmony/tools/build_jvm_probe.sh`、
  `harmony/tools/verify_agent_libs.sh`、`AGENTS.md`「JIT / 可执行内存权限」
