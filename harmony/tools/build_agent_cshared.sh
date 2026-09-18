#!/usr/bin/env bash
# 把一个原生 Go agent 编成 OHOS native child process 用的 c-shared .so。
#
# 用法：
#   harmony/tools/build_agent_cshared.sh <pkg> [out-name]
#   harmony/tools/build_agent_cshared.sh oracle-go
#   harmony/tools/build_agent_cshared.sh etcd2-go libdbx_agent_etcd2.so
#
# 产物直接放到 HAP 的 entry/libs/arm64-v8a/ 下；子进程由
# OH_Ability_StartNativeChildProcess("<产物名>:Main", …) 启动（见 crates/dbx-core/src/db/agent_ncp.rs）。
#
# 注意：
#  - OHOS clang 用 Harmonybrew 那份 NDK（deveco_tools 里的 clang 不可执行）。
#  - agent 侧必须带 `ohos_ncp` build tag（入口 Main + fd→0/1 复用 stdio 协议）。
#  - 必须带 Go 运行时补丁 overlay（见 go_ohos_overlay.py）：musl 上 dlopen 的 Go 库
#    会撞 initial-exec TLS 与 argc/argv 两堵墙，不打补丁连 dlopen 都过不去。
#  - NCP 入口的两个文件（ohos_ncp.go / ohos_ncp_shim.c）由 overlay 从
#    harmony/tools/agent_ncp/ 虚拟注入，不在 driver 目录里留副本。
#  - driver 的 main.go 必须已拆成 `func main() { runStdioAgent() }` +
#    `func runStdioAgent() { …原 main 体… }`（见 harmony/tools/build_all_agents.sh 的说明）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NDK="${OHOS_NDK_HOME:-/storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_1/native}"
CC="$NDK/llvm/bin/aarch64-unknown-linux-ohos-clang"
SYSROOT="$NDK/sysroot"
PKG="${1:?用法: build_agent_cshared.sh <pkg> [out-name]}"
# 默认库名去掉 -go 后缀：oracle-go → libdbx_agent_oracle.so、etcd2-go → libdbx_agent_etcd2.so
KEY="${PKG%-go}"
OUT_NAME="${2:-libdbx_agent_${KEY}.so}"
SRC="$ROOT/upstream/dbx/agents/drivers/$PKG"
OUT="$ROOT/harmony/dbxohos/entry/libs/arm64-v8a/$OUT_NAME"

[ -x "$CC" ] || { echo "找不到可执行的 OHOS clang: $CC" >&2; exit 1; }
[ -d "$SRC" ] || { echo "找不到 agent 源码目录: $SRC" >&2; exit 1; }
if ! grep -q "func runStdioAgent()" "$SRC/main.go"; then
  echo "错误: $SRC/main.go 还没有 runStdioAgent()，先按 oracle-go 的方式拆 main()" >&2
  exit 1
fi

export GOOS=linux
export GOARCH=arm64
export CGO_ENABLED=1
export CC
export CGO_CFLAGS="--sysroot=$SYSROOT -I$SYSROOT/usr/include"
export CGO_LDFLAGS="--sysroot=$SYSROOT -L$SYSROOT/usr/lib/aarch64-linux-ohos"
export GOFLAGS="${GOFLAGS:-} -mod=mod"
# TMPDIR 必须指向沙箱 cache 目录（Go 自己默认也用它）：
#  - /tmp 在本机是只读的 → cgo 写 /tmp/cgo-gcc-input-* 会失败；
#  - 指到工作区（/storage/...）反而会让链接器 mmap 输出文件失败（EACCES）。
export TMPDIR="${DBX_GO_TMPDIR:-/data/storage/el2/base/cache}"
mkdir -p "$TMPDIR"

# Go 运行时补丁 + NCP 入口注入：生成 overlay 并传给 go build。
# 每个 driver 用独立 overlay 目录，避免并行构建时 overlay.json 互相覆盖。
OVERLAY_DIR="${DBX_GO_OVERLAY_DIR:-$ROOT/.tmp/go-ohos-overlay}/$PKG"
python3 "$ROOT/harmony/tools/go_ohos_overlay.py" \
  --out "$OVERLAY_DIR" \
  --inject-driver "$SRC" >/dev/null
OVERLAY="$OVERLAY_DIR/overlay.json"
[ -f "$OVERLAY" ] || { echo "overlay 生成失败: $OVERLAY" >&2; exit 1; }

cd "$SRC"
go build -buildmode=c-shared -tags ohos_ncp -overlay="$OVERLAY" -trimpath -o "$OUT" .
# c-shared 构建会在 .so 旁边生成同名 .h（cgo 导出头）；HAP 只需要 .so，清掉免得污染 libs/
rm -f "${OUT%.so}.h"

# 冒烟断言：系统靠 dlsym("Main") 找入口，缺了会在运行时才报 NCP_ERR_LIB_LOADING_FAILED
NM="$NDK/llvm/bin/llvm-nm"
if [ -x "$NM" ]; then
  # 注意不要用 `nm | grep -q`：grep 提前退出会让 nm 吃 SIGPIPE，
  # 在 `set -o pipefail` 下整个管道变成失败，断言会误报。
  exported="$("$NM" -D --defined-only "$OUT" 2>/dev/null | grep -w Main || true)"
  if [ -z "$exported" ]; then
    echo "错误: $OUT 没有导出 Main 符号" >&2
    exit 1
  fi
fi

echo "built: $OUT"
ls -l "$OUT"
