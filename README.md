# dbx-ohos

DBX 数据库客户端在 HarmonyOS 上的移植工程。

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

## 移植说明

- 上游 fork：`git@github.com:GetZ110/dbx.git`，分支 `harmonyos-port`
- Rust 侧新增 `crates/dbx-ohos`（NAPI 导出 `startServer` / `stopServer` / MCP）
- `dbx-web` 新增 `/api/health` 就绪路由，并复用 `AppState` 避免二次打开 SQLite
- 鸿蒙壳使用 ArkWeb 加载本地 `dbx-web` 服务；主题/外观偏好通过原生 Preferences 持久化
