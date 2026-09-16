#!/usr/bin/env bash
# 把 native child process 的 spike 子进程库编成 HAP libs 里的 .so。
#
# 注意：本机 deveco_tools 里的 ohos-sdk llvm/clang 是"实体文件"形态、无法执行
# （EPERM，符号链接 clang -> clang-15 被复制成了普通文件导致代码签名失效），
# 所以默认用 Harmonybrew 装的那份 ohos-sdk。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NDK="${OHOS_NDK_HOME:-/storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_1/native}"
CC="$NDK/llvm/bin/aarch64-unknown-linux-ohos-clang"
SYSROOT="$NDK/sysroot"
SRC="$ROOT/harmony/tools/ncp_spike/ncp_spike.c"
OUT="$ROOT/harmony/dbxohos/entry/libs/arm64-v8a/libdbx_ncpspike.so"

[ -x "$CC" ] || { echo "找不到可执行的 OHOS clang: $CC" >&2; exit 1; }

"$CC" --target=aarch64-linux-ohos --sysroot="$SYSROOT" -shared -fPIC -O2 \
    -I"$SYSROOT/usr/include" \
    -o "$OUT" "$SRC" \
    -L"$SYSROOT/usr/lib/aarch64-linux-ohos" -lhilog_ndk.z

echo "built: $OUT"
ls -l "$OUT"
