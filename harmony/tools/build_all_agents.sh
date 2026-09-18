#!/usr/bin/env bash
# 批量构建 HAP 内置的 native agent 库（entry/libs/arm64-v8a/）。
#
# 用法：
#   harmony/tools/build_all_agents.sh              # 全部（14 个 Go + 2 个 Rust）
#   harmony/tools/build_all_agents.sh --go         # 只构建 Go agent
#   harmony/tools/build_all_agents.sh --rust       # 只构建 Rust agent
#   harmony/tools/build_all_agents.sh --list       # 列出清单
#   JOBS=4 harmony/tools/build_all_agents.sh --go  # 并行度（默认 4）
#
# 产物与 driver key 的对应（key 由 agents/drivers 目录名去掉 -go 得到）：
#   oracle-go→oracle  kingbase-go→kingbase  vastbase-go→vastbase  hive-go→hive
#   argo-go→argo      neo4j-go→neo4j        cassandra-go→cassandra
#   iotdb→iotdb       xugu→xugu             etcd-go→etcd  etcd2-go→etcd2
#   zookeeper         rocketmq→rocketmq     rabbitmq→rabbitmq
# 其中 hive 一个产物覆盖 hive/kyuubi/impala（dbx 侧 canonical 映射已处理）。
# Rust 侧：tdengine（agent 路径）、duckdb（sidecar 路径，另见 duckdb_worker_process.rs）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JOBS="${JOBS:-4}"

GO_PKGS=(
  oracle-go kingbase-go vastbase-go hive-go argo-go neo4j-go cassandra-go
  iotdb xugu etcd-go etcd2-go zookeeper rocketmq rabbitmq
)
RUST_PKGS=(tdengine duckdb)

# Rust agent 的 cdylib 目标名（crate 名 → libdbx_agent_<key>.so）
rust_out_name() {
  case "$1" in
    tdengine) echo "libdbx_agent_tdengine.so" ;;
    duckdb) echo "libdbx_agent_duckdb.so" ;;
    *) echo "libdbx_agent_$1.so" ;;
  esac
}

MODE="all"
case "${1:-}" in
  --go) MODE="go" ;;
  --rust) MODE="rust" ;;
  --list)
    printf 'go   : %s\n' "${GO_PKGS[*]}"
    printf 'rust : %s\n' "${RUST_PKGS[*]}"
    exit 0
    ;;
  "") MODE="all" ;;
  *) echo "未知参数: $1" >&2; exit 1 ;;
esac

status=0
pids=()

build_go() {
  local pkg="$1"
  echo "[go]   $pkg"
  if ! "$ROOT/harmony/tools/build_agent_cshared.sh" "$pkg" >"$ROOT/.tmp/agent-build-$pkg.log" 2>&1; then
    echo "[go]   $pkg FAILED（日志: .tmp/agent-build-$pkg.log）" >&2
    tail -20 "$ROOT/.tmp/agent-build-$pkg.log" >&2
    return 1
  fi
}

build_rust() {
  local pkg="$1" out
  out="$(rust_out_name "$pkg")"
  echo "[rust] $pkg -> $out"
  if ! "$ROOT/harmony/tools/build_agent_rust.sh" "$pkg" "$out" >"$ROOT/.tmp/agent-build-$pkg.log" 2>&1; then
    echo "[rust] $pkg FAILED（日志: .tmp/agent-build-$pkg.log）" >&2
    tail -30 "$ROOT/.tmp/agent-build-$pkg.log" >&2
    return 1
  fi
}

mkdir -p "$ROOT/.tmp"

if [ "$MODE" = "go" ] || [ "$MODE" = "all" ]; then
  for pkg in "${GO_PKGS[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || status=1; done
    build_go "$pkg" & pids+=($!)
  done
fi

if [ "$MODE" = "rust" ] || [ "$MODE" = "all" ]; then
  for pkg in "${RUST_PKGS[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || status=1; done
    build_rust "$pkg" & pids+=($!)
  done
fi

for pid in "${pids[@]:-}"; do
  [ -n "$pid" ] || continue
  wait "$pid" || status=1
done

echo "=== entry/libs/arm64-v8a ==="
ls -l "$ROOT/harmony/dbxohos/entry/libs/arm64-v8a/"
if [ "$status" -ne 0 ]; then
  echo "有 agent 构建失败" >&2
  exit 1
fi
echo "全部构建成功"
