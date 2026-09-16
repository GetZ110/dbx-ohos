#!/usr/bin/env bash
# 把一个原生 agent 编成 OHOS native child process 用的 c-shared .so。
#
# 用法：
#   harmony/tools/build_agent_cshared.sh [oracle-go] [libdbx_agent_oracle.so]
#
# 产物直接放到 HAP 的 entry/libs/arm64-v8a/ 下；子进程由
# childProcessManager.startNativeChildProcess("<产物名>:Main", …) 启动。
#
# 注意：
#  - OHOS clang 用 Harmonybrew 那份 NDK（deveco_tools 里的 clang 不可执行）。
#  - agent 侧必须带 `ohos_ncp` build tag（入口 Main + fd→0/1 复用 stdio 协议）。
#  - 必须带 Go 运行时补丁 overlay（见 go_ohos_overlay.py）：musl 上 dlopen 的 Go 库
#    会撞 initial-exec TLS 与 argc/argv 两堵墙，不打补丁连 dlopen 都过不去。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NDK="${OHOS_NDK_HOME:-/storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_1/native}"
CC="$NDK/llvm/bin/aarch64-unknown-linux-ohos-clang"
SYSROOT="$NDK/sysroot"
PKG="${1:-oracle-go}"
OUT_NAME="${2:-libdbx_agent_oracle.so}"
SRC="$ROOT/upstream/dbx/agents/drivers/$PKG"
OUT="$ROOT/harmony/dbxohos/entry/libs/arm64-v8a/$OUT_NAME"

[ -x "$CC" ] || { echo "找不到可执行的 OHOS clang: $CC" >&2; exit 1; }
[ -d "$SRC" ] || { echo "找不到 agent 源码目录: $SRC" >&2; exit 1; }

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

# Go 运行时补丁（musl 上 dlopen 需要）：生成 overlay 并传给 go build
OVERLAY_DIR="${DBX_GO_OVERLAY_DIR:-$ROOT/.tmp/go-ohos-overlay}"
python3 "$ROOT/harmony/tools/go_ohos_overlay.py" --out "$OVERLAY_DIR" >/dev/null
OVERLAY="$OVERLAY_DIR/overlay.json"
[ -f "$OVERLAY" ] || { echo "overlay 生成失败: $OVERLAY" >&2; exit 1; }

cd "$SRC"
go build -buildmode=c-shared -tags ohos_ncp -overlay="$OVERLAY" -trimpath -o "$OUT" .
# c-shared 构建会在 .so 旁边生成同名 .h（cgo 导出头）；HAP 只需要 .so，清掉免得污染 libs/
rm -f "${OUT%.so}.h"
echo "built: $OUT"
ls -l "$OUT"
