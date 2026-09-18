#!/usr/bin/env bash
# 校验 entry/libs/arm64-v8a/ 下的内置 agent 库：文件名是否与 driver key 对应、
# 是否导出了 NCP 需要的 Main 符号。
#
# 用法：harmony/tools/verify_agent_libs.sh [libs-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NDK="${OHOS_NDK_HOME:-/storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_1/native}"
NM="$NDK/llvm/bin/llvm-nm"
LIBS="${1:-$ROOT/harmony/dbxohos/entry/libs/arm64-v8a}"

# driver key（= ohos_bundled_agent_library() 拼出的 libdbx_agent_<key>.so）
GO_KEYS=(oracle kingbase vastbase hive argo neo4j cassandra iotdb xugu etcd etcd2 zookeeper rocketmq rabbitmq)
RUST_KEYS=(tdengine duckdb)

status=0
check() {
  local key="$1" kind="$2"
  local file="$LIBS/libdbx_agent_${key}.so"
  if [ ! -f "$file" ]; then
    echo "MISSING  [$kind] libdbx_agent_${key}.so"
    status=1
    return
  fi
  local size main
  size="$(stat -c%s "$file")"
  main="$("$NM" -D --defined-only "$file" 2>/dev/null | grep -w Main || true)"
  if [ -z "$main" ]; then
    echo "NO-MAIN  [$kind] libdbx_agent_${key}.so (${size}B)"
    status=1
    return
  fi
  printf 'OK       [%-4s] %-28s %10s B\n' "$kind" "libdbx_agent_${key}.so" "$size"
}

echo "libs dir: $LIBS"
for key in "${GO_KEYS[@]}"; do check "$key" go; done
for key in "${RUST_KEYS[@]}"; do check "$key" rust; done

# libdbx_ohos.so 是 NAPI 主库，不该有 Main
if [ -f "$LIBS/libdbx_ohos.so" ]; then
  printf 'OK       [main] %-28s %10s B\n' "libdbx_ohos.so" "$(stat -c%s "$LIBS/libdbx_ohos.so")"
fi

total=$(( ${#GO_KEYS[@]} + ${#RUST_KEYS[@]} ))
echo "---"
if [ "$status" -eq 0 ]; then
  echo "全部 $total 个内置 agent 库通过（含 Main 符号）"
else
  echo "有 agent 库缺失或缺少 Main 符号" >&2
fi
exit "$status"
