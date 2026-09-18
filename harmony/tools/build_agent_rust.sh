#!/usr/bin/env bash
# 把一个 Rust agent 编成 OHOS native child process 用的 cdylib。
#
# 用法：
#   harmony/tools/build_agent_rust.sh <crate-dir> [out-name]
#   harmony/tools/build_agent_rust.sh tdengine libdbx_agent_tdengine.so
#   harmony/tools/build_agent_rust.sh duckdb   libdbx_agent_duckdb.so
#
# crate 侧需要：
#   - Cargo.toml 的 `[lib] crate-type = ["rlib", "cdylib"]`
#   - src/ohos_ncp.rs（入口 `Main`，规范副本在 harmony/tools/agent_ncp/ohos_ncp.rs）
#   - lib.rs 里 `#[cfg(target_env = "ohos")] mod ohos_ncp;` + `run_stdio_agent()`
#
# 本机 host == aarch64-unknown-linux-ohos，所以是原生构建，不需要 --target。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NDK="${OHOS_NDK_HOME:-/storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_1/native}"
SYSROOT="$NDK/sysroot"
PKG="${1:?用法: build_agent_rust.sh <crate-dir> [out-name]}"
OUT_NAME="${2:-libdbx_agent_${PKG}.so}"
SRC="$ROOT/upstream/dbx/agents/drivers/$PKG"
OUT="$ROOT/harmony/dbxohos/entry/libs/arm64-v8a/$OUT_NAME"

[ -d "$SRC" ] || { echo "找不到 Rust agent 目录: $SRC" >&2; exit 1; }
[ -f "$SRC/Cargo.toml" ] || { echo "缺少 $SRC/Cargo.toml" >&2; exit 1; }
[ -f "$SRC/src/ohos_ncp.rs" ] || { echo "缺少 $SRC/src/ohos_ncp.rs（NCP 入口）" >&2; exit 1; }

# crate 名 → cdylib 文件名：dbx-tdengine-driver → libdbx_tdengine_driver.so
# Cargo.toml 里第一个 `name = "…"` 就是 [package] name。
LIB_STEM="$(awk -F'"' '/^name[[:space:]]*=/{print $2; exit}' "$SRC/Cargo.toml" | tr '-' '_')"
[ -n "$LIB_STEM" ] || { echo "无法从 $SRC/Cargo.toml 解析 crate 名" >&2; exit 1; }
BUILT="$SRC/target/release/lib${LIB_STEM}.so"

# OHOS clang 给 cc/cc-rs 用（duckdb 的 bundled C++ 要靠它）
export CC="$NDK/llvm/bin/aarch64-unknown-linux-ohos-clang"
export CXX="$NDK/llvm/bin/aarch64-unknown-linux-ohos-clang++"
export CFLAGS="${CFLAGS:-} --sysroot=$SYSROOT"
export CXXFLAGS="${CXXFLAGS:-} --sysroot=$SYSROOT"
# OHOS 的 C++ 运行时叫 libc++.so（不是 GNU 的 libstdc++），cc-rs 默认会链 stdc++
export CXXSTDLIB="${CXXSTDLIB:-c++}"
# Rust 链接期也要找得到 sysroot（cdylib 要链 libc++/libc）
export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=--sysroot=$SYSROOT"

echo "==> cargo build --release --lib  ($PKG)"
cd "$SRC"
cargo build --release --lib

[ -f "$BUILT" ] || { echo "构建产物不存在: $BUILT" >&2; ls -l "$SRC/target/release/" | head -20 >&2; exit 1; }
cp -f "$BUILT" "$OUT"

NM="$NDK/llvm/bin/llvm-nm"
if [ -x "$NM" ]; then
  exported="$("$NM" -D --defined-only "$OUT" 2>/dev/null | grep -w Main || true)"
  if [ -z "$exported" ]; then
    echo "错误: $OUT 没有导出 Main 符号" >&2
    exit 1
  fi
fi

# cdylib 若依赖 C++ 运行时（duckdb 的 bundled C++），必须把 libc++_shared.so 一并放进
# libs/：NCP 子进程的 linker namespace 只搜应用自己的 lib 目录，/system/lib64 里那份
# 找不到（真机实测 "load libc++_shared.so failed, namespace=moduleNs_default, errno=2"）。
READELF="$NDK/llvm/bin/llvm-readelf"
if [ -x "$READELF" ] && "$READELF" -d "$OUT" 2>/dev/null | grep -q "libc++_shared.so"; then
  LIBCXX="$NDK/llvm/lib/aarch64-linux-ohos/libc++_shared.so"
  [ -f "$LIBCXX" ] || { echo "需要 libc++_shared.so 但 NDK 里找不到: $LIBCXX" >&2; exit 1; }
  cp -f "$LIBCXX" "$(dirname "$OUT")/libc++_shared.so"
  echo "bundled C++ runtime: $(dirname "$OUT")/libc++_shared.so"
fi

echo "built: $OUT"
ls -l "$OUT"
