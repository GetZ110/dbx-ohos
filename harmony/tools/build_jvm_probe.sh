#!/usr/bin/env bash
# 构建 JDBC「进程内 JVM」可行性探针：
#   1. libdbx_jvmprobe.so  —— native child process 入口，放进 HAP 的 entry/libs/
#   2. libdbx_sandboxprobe.so —— 对照组小库，放进 rawfile（运行时被拷进沙箱再 dlopen）
#
# 与 build_ncp_spike.sh 一样，OHOS clang 用 Harmonybrew 那份 NDK
# （deveco_tools 里的 clang 不可执行，见 AGENTS.md）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NDK="${OHOS_NDK_HOME:-/storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_1/native}"
CC="$NDK/llvm/bin/aarch64-unknown-linux-ohos-clang"
SYSROOT="$NDK/sysroot"
SRC_DIR="$ROOT/harmony/tools/ncp_probe"
LIBS_DIR="$ROOT/harmony/dbxohos/entry/libs/arm64-v8a"
RAWFILE_DIR="$ROOT/harmony/dbxohos/entry/src/main/resources/rawfile/ncp-probe"

[ -x "$CC" ] || { echo "找不到可执行的 OHOS clang: $CC" >&2; exit 1; }

mkdir -p "$LIBS_DIR" "$RAWFILE_DIR"

build_shared() {
    local src="$1" out="$2" extra="${3:-}"
    # shellcheck disable=SC2086
    "$CC" --target=aarch64-linux-ohos --sysroot="$SYSROOT" -shared -fPIC -O2 \
        -I"$SYSROOT/usr/include" $extra \
        -o "$out" "$src" \
        -L"$SYSROOT/usr/lib/aarch64-linux-ohos" -lhilog_ndk.z
    echo "built: $out"
}

build_shared "$SRC_DIR/jvm_probe.c" "$LIBS_DIR/libdbx_jvmprobe.so"
build_shared "$SRC_DIR/sandbox_probe.c" "$RAWFILE_DIR/libdbx_sandboxprobe.so" "-nostdlib"

ls -l "$LIBS_DIR/libdbx_jvmprobe.so" "$RAWFILE_DIR/libdbx_sandboxprobe.so"
