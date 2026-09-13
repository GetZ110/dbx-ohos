#!/usr/bin/env bash
# startup_smoke.sh — DBX HarmonyOS 启动冒烟测试
#
# 目的：把「启动链路错了会静默退化」的那些点变成一条命令的退出码。
#   - 指纹判断错        → 用户一直用旧前端（copy 行变 "copied from rawfile"）
#   - 缓存头丢          → 冷启动退回 3.8s（modules loaded 变长）
#   - 启动页隐藏逻辑错  → 闪白 / 多 Web 实例（Index about to appear 出现多次）
#   - gzip 门控失效     → 白烧 1s CPU（FCP 变慢）
#   - isTauriRuntime 守卫丢失 → transformCallback / Cannot read properties of undefined
#
# 用法：
#   ./harmony/tools/startup_smoke.sh                     # 连设备跑一次（auto 模式）
#   ./harmony/tools/startup_smoke.sh --mode warm         # 稳态，严格阈值
#   ./harmony/tools/startup_smoke.sh --mode cold         # bm clean -c 之后
#   ./harmony/tools/startup_smoke.sh --serial 127.0.0.1:43817
#   ./harmony/tools/startup_smoke.sh --log .tmp/xxx.log  # 只对已有日志做断言（不需要设备）
#
# 冷缓存场景制造（只清缓存、不动已保存的连接）：
#   hdc shell "bm clean -c -n com.dbx.ohos"
#
# 退出码：0 = 全部通过；1 = 有断言失败；2 = 环境/参数错误。

set -uo pipefail

BUNDLE="com.dbx.ohos"
ABILITY="EntryAbility"
DEFAULT_SERIAL="127.0.0.1:43817"

MODE="auto"
LOG=""
TIMEOUT=25
SERIAL="${HDC_TARGET:-$DEFAULT_SERIAL}"
ASSERT_ONLY=0
KEEP=0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$ROOT/.tmp"

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)    MODE="${2:-}"; shift 2 ;;
    --mode=*)  MODE="${1#*=}"; shift ;;
    --log)     LOG="${2:-}"; shift 2 ;;
    --log=*)   LOG="${1#*=}"; shift ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --timeout=*) TIMEOUT="${1#*=}"; shift ;;
    --serial)  SERIAL="${2:-}"; shift 2 ;;
    --serial=*) SERIAL="${1#*=}"; shift ;;
    --keep)    KEEP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$MODE" in auto|warm|cold) ;; *) echo "--mode 只能是 auto|warm|cold" >&2; exit 2 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) echo "--timeout 必须是整数秒" >&2; exit 2 ;; esac

# ---------------------------------------------------------------- 阈值
# 稳态基线：modules loaded 283–338ms，FCP ~1.04s（真机 HUAWEI MateBook Pro / HAD-W32）
# 冷缓存基线：modules loaded 1456–1589ms，FCP ~2.57s
# 回归红线取基线留余量后的上限；优化前基线为 1730ms / 3.09s。
MODULES_WARM_MAX=400
MODULES_COLD_MAX=1700
FCP_WARM_MAX=1300
FCP_COLD_MAX=3000
READY_MAX=200
ATTEMPT_MAX=3

# ---------------------------------------------------------------- 工具
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
if [ ! -t 1 ]; then c_red=""; c_grn=""; c_ylw=""; c_dim=""; c_off=""; fi

FAILED=0
declare -a ROWS=()

record() { # record <状态:ok|warn|fail> <名称> <实测> <期望>
  local st="$1" name="$2" got="$3" want="$4"
  local tag
  case "$st" in
    ok)   tag="${c_grn}PASS${c_off}" ;;
    warn) tag="${c_ylw}WARN${c_off}" ;;
    *)    tag="${c_red}FAIL${c_off}"; FAILED=1 ;;
  esac
  ROWS+=("$(printf '%-4s %-42s %-26s %s' "$tag" "$name" "$got" "$want")")
}

# 从 "MM-DD HH:MM:SS.mmm" 取毫秒（月按 31 天粗算；单次运行内足够单调）
ts_to_ms() {
  awk -v t="$1" 'BEGIN{
    if (split(t,a," ") < 2) { print ""; exit }
    split(a[1],d,"-"); split(a[2],c,":"); split(c[3],s,".");
    printf "%d", ((((d[1]*31+d[2])*24+c[1])*60+c[2])*60+s[1])*1000+s[2];
  }'
}

# 取某模式第一次出现的整行
first_line() { grep -aE "$1" "$LOG" 2>/dev/null | head -1; }
last_line()  { grep -aE "$1" "$LOG" 2>/dev/null | tail -1; }
count_of()   { local n; n=$(grep -acE "$1" "$LOG" 2>/dev/null); echo "${n:-0}"; }

# 取一行的时间戳（前两个字段）
line_ts() { echo "$1" | awk '{print $1" "$2}'; }

# ---------------------------------------------------------------- 采集
if [ -n "$LOG" ]; then
  [ -f "$LOG" ] || { echo "日志不存在: $LOG" >&2; exit 2; }
  ASSERT_ONLY=1
  echo "${c_dim}[smoke] 只断言已有日志: $LOG${c_off}"
else
  HDC="$(command -v hdc || true)"
  if [ -z "$HDC" ]; then
    for cand in /storage/Users/currentUser/.harmonybrew/bin/hdc \
                /storage/Users/currentUser/deveco_tools/sdk/default/openharmony/toolchains/hdc; do
      [ -x "$cand" ] && HDC="$cand" && break
    done
  fi
  [ -n "$HDC" ] || { echo "找不到 hdc，请把 hdc 放进 PATH" >&2; exit 2; }

  echo "${c_dim}[smoke] hdc = $HDC${c_off}"
  if ! "$HDC" list targets 2>/dev/null | grep -qv '^\[Empty\]$'; then
    echo "[smoke] 设备列表为空，尝试连接 $SERIAL ..."
    "$HDC" tconn "$SERIAL" >/dev/null 2>&1 || true
    sleep 2
  fi
  if ! "$HDC" list targets 2>/dev/null | grep -qv '^\[Empty\]$'; then
    echo "没有可用设备。先 hdc tconn $SERIAL（或先启动模拟器）。" >&2
    exit 2
  fi

  mkdir -p "$TMP_DIR"
  LOG="$TMP_DIR/startup_smoke_$(date +%Y%m%d_%H%M%S).log"

  echo "[smoke] force-stop $BUNDLE"
  "$HDC" shell aa force-stop "$BUNDLE" >/dev/null 2>&1 || true
  sleep 1
  echo "[smoke] hilog -r"
  "$HDC" shell hilog -r >/dev/null 2>&1 || true

  echo "[smoke] 开始抓日志 (${TIMEOUT}s) -> $LOG"
  "$HDC" hilog > "$LOG" 2>/dev/null &
  HILOG_PID=$!
  sleep 2

  echo "[smoke] aa start -a $ABILITY -b $BUNDLE"
  "$HDC" shell aa start -a "$ABILITY" -b "$BUNDLE" >/dev/null 2>&1 || true

  sleep "$TIMEOUT"
  kill "$HILOG_PID" 2>/dev/null || true
  wait "$HILOG_PID" 2>/dev/null || true
  echo "${c_dim}[smoke] 采集结束，日志 $(wc -l < "$LOG") 行${c_off}"
fi

# ---------------------------------------------------------------- 断言
# 1) 复制策略：稳态必须 skipped，首次安装/换版本必须是 copied
COPY_LINE="$(last_line 'DBX_COPY:')"
if [ -z "$COPY_LINE" ]; then
  record fail "fingerprint copy 行" "缺失" "应有 DBX_COPY: 日志"
elif echo "$COPY_LINE" | grep -q 'skipped copy'; then
  record ok "fingerprint copy" "skipped $(echo "$COPY_LINE" | grep -oE 'in [0-9]+ms' | awk '{print $2}')" "稳态: skipped"
elif echo "$COPY_LINE" | grep -q 'frontend copied from rawfile'; then
  record ok "fingerprint copy" "copied" "首次安装/换版本: copied"
else
  record fail "fingerprint copy 行" "$(echo "$COPY_LINE" | cut -c1-60)" "未识别的 DBX_COPY 文案"
fi

# 2) 本地服务就绪耗时
READY_MS="$(last_line 'Local service ready in' | grep -oE 'in [0-9]+ms' | grep -oE '[0-9]+' || true)"
if [ -z "$READY_MS" ]; then
  record fail "Local service ready" "缺失" "< ${READY_MAX}ms"
elif [ "$READY_MS" -lt "$READY_MAX" ]; then
  record ok "Local service ready" "${READY_MS}ms" "< ${READY_MAX}ms"
else
  record fail "Local service ready" "${READY_MS}ms" "< ${READY_MAX}ms"
fi

# 3) /api/health 轮询次数与端口回环绑定
HEALTH_LINE="$(last_line 'server ready:.*/api/health')"
ATTEMPT="$(echo "$HEALTH_LINE" | grep -oE 'attempt [0-9]+' | grep -oE '[0-9]+' || true)"
if [ -z "$ATTEMPT" ]; then
  record fail "server ready (health)" "缺失" "attempt N, N ≤ ${ATTEMPT_MAX}"
elif [ "$ATTEMPT" -le "$ATTEMPT_MAX" ]; then
  record ok "server ready (health)" "attempt ${ATTEMPT}" "N ≤ ${ATTEMPT_MAX}"
else
  record fail "server ready (health)" "attempt ${ATTEMPT}" "N ≤ ${ATTEMPT_MAX}"
fi
if echo "$HEALTH_LINE" | grep -q 'http://127.0.0.1:'; then
  record ok "server 绑回环" "127.0.0.1" "必须 127.0.0.1"
else
  record fail "server 绑回环" "$(echo "$HEALTH_LINE" | grep -oE 'http://[^ ]+' || echo '未知')" "必须 127.0.0.1"
fi

# 4) 启动闭包加载耗时 = modules loaded - bootstrap begin
BEGIN_LINE="$(first_line '\[STARTUP\] frontend bootstrap begin')"
MOD_LINE="$(first_line '\[STARTUP\] frontend modules loaded')"
MODULES_MS=""
if [ -n "$BEGIN_LINE" ] && [ -n "$MOD_LINE" ]; then
  b="$(ts_to_ms "$(line_ts "$BEGIN_LINE")")"; m="$(ts_to_ms "$(line_ts "$MOD_LINE")")"
  [ -n "$b" ] && [ -n "$m" ] && MODULES_MS=$((m - b))
fi
if [ -z "$MODULES_MS" ]; then
  record fail "frontend modules loaded" "缺少 bootstrap/modules 标记" "见 App 启动日志"
elif [ "$MODE" = warm ]; then
  if [ "$MODULES_MS" -le "$MODULES_WARM_MAX" ]; then
    record ok "frontend modules loaded" "${MODULES_MS}ms" "warm ≤ ${MODULES_WARM_MAX}ms"
  else
    record fail "frontend modules loaded" "${MODULES_MS}ms" "warm ≤ ${MODULES_WARM_MAX}ms"
  fi
elif [ "$MODE" = cold ]; then
  if [ "$MODULES_MS" -le "$MODULES_COLD_MAX" ]; then
    record ok "frontend modules loaded" "${MODULES_MS}ms" "cold ≤ ${MODULES_COLD_MAX}ms"
  else
    record fail "frontend modules loaded" "${MODULES_MS}ms" "cold ≤ ${MODULES_COLD_MAX}ms"
  fi
else
  # auto：按实测分档，>cold 上限才算回归
  if [ "$MODULES_MS" -le "$MODULES_WARM_MAX" ]; then
    record ok "frontend modules loaded" "${MODULES_MS}ms" "auto: warm 档"
  elif [ "$MODULES_MS" -le "$MODULES_COLD_MAX" ]; then
    record warn "frontend modules loaded" "${MODULES_MS}ms" "auto: 冷缓存/偏慢档（≤${MODULES_COLD_MAX}ms）"
  else
    record fail "frontend modules loaded" "${MODULES_MS}ms" "回归: 优化前基线 1730ms"
  fi
fi

# 5) 页内 FCP
FCP_MS="$(first_line 'PageFirstContentfulPaintInPage' | grep -oE 'FCP:[0-9]+ms' | grep -oE '[0-9]+' || true)"
if [ -z "$FCP_MS" ]; then
  record fail "PageFirstContentfulPaint" "缺失" "见 chromium WebLoadTracker"
elif [ "$MODE" = warm ]; then
  [ "$FCP_MS" -le "$FCP_WARM_MAX" ] \
    && record ok "PageFirstContentfulPaint" "${FCP_MS}ms" "warm ≤ ${FCP_WARM_MAX}ms" \
    || record fail "PageFirstContentfulPaint" "${FCP_MS}ms" "warm ≤ ${FCP_WARM_MAX}ms"
elif [ "$MODE" = cold ]; then
  [ "$FCP_MS" -le "$FCP_COLD_MAX" ] \
    && record ok "PageFirstContentfulPaint" "${FCP_MS}ms" "cold ≤ ${FCP_COLD_MAX}ms" \
    || record fail "PageFirstContentfulPaint" "${FCP_MS}ms" "cold ≤ ${FCP_COLD_MAX}ms"
else
  if [ "$FCP_MS" -le "$FCP_WARM_MAX" ]; then
    record ok "PageFirstContentfulPaint" "${FCP_MS}ms" "auto: warm 档"
  elif [ "$FCP_MS" -le "$FCP_COLD_MAX" ]; then
    record warn "PageFirstContentfulPaint" "${FCP_MS}ms" "auto: 冷缓存/偏慢档（≤${FCP_COLD_MAX}ms）"
  else
    record fail "PageFirstContentfulPaint" "${FCP_MS}ms" "回归: 优化前基线 3.09s"
  fi
fi

# 6) 页面只加载一次（防「重复 loadContent → 多 Web 实例」）
N_LOAD="$(count_of 'Succeeded in loading the content\.')"
N_APPEAR="$(count_of 'Index about to appear')"
[ "$N_LOAD" = "1" ] \
  && record ok "Succeeded in loading" "1 次" "恰好 1 次" \
  || record fail "Succeeded in loading" "${N_LOAD} 次" "恰好 1 次"
[ "$N_APPEAR" = "1" ] \
  && record ok "Index about to appear" "1 次" "恰好 1 次" \
  || record fail "Index about to appear" "${N_APPEAR} 次" "恰好 1 次"

# 7) 禁止出现的错误（零容忍）
for pat in 'transformCallback' 'Failed to apply UI scale' 'Cannot read properties of undefined'; do
  n="$(count_of "$pat")"
  [ "$n" = "0" ] \
    && record ok "禁止: ${pat}" "0 条" "0 条" \
    || record fail "禁止: ${pat}" "${n} 条" "0 条"
done

# 8) Vue 挂载（启动页隐藏的前提）
[ "$(count_of '\[STARTUP\] vue mounted')" != "0" ] \
  && record ok "vue mounted" "出现" "≥1 次" \
  || record fail "vue mounted" "缺失" "≥1 次"

# ---------------------------------------------------------------- 报告
echo
echo "==================== DBX 启动冒烟 (${MODE}) ===================="
for r in "${ROWS[@]}"; do echo "$r"; done
echo "=============================================================="
echo "日志: $LOG"
echo "${c_dim}(日志一律保留，便于回溯; --log 可对历史日志重跑断言)${c_off}"
if [ "$FAILED" = "1" ]; then
  echo "${c_red}结果: 失败${c_off}"
  exit 1
fi
echo "${c_grn}结果: 全部通过${c_off}"
exit 0
