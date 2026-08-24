#!/usr/bin/env bash
# dev-run.sh — 一键构建 + 装机 + 启动 dbx-ohos 到连接的 HarmonyOS 设备
#
# 依赖 devecocli（全局 npm 包 @deveco-test/hmos-deveco-code v0.3.1）
#   bin: /storage/Users/currentUser/.npm-global/bin/devecocli
# 工具链根: /storage/Users/currentUser/deveco_tools（CLT 布局，需 DEVECO_CLI_CLT_PATH）
#
# 用法:
#   ./dev-run.sh              # 构建 + 部署(debug)
#   ./dev-run.sh --skip-build # 只部署现有产物
#   ./dev-run.sh -h           # 更多参数直接透传给 devecocli run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/harmony/dbxohos" && pwd)"

export PATH="/storage/Users/currentUser/.npm-global/bin:/storage/Users/currentUser/.harmonybrew/bin:${PATH:-}"
export DEVECO_CLI_CLT_PATH="/storage/Users/currentUser/deveco_tools"
export DEVECO_SDK_HOME="/storage/Users/currentUser/deveco_tools/sdk"

cd "${PROJECT_DIR}"
echo "==> devecocli run (cwd: ${PWD})"
exec devecocli run "$@"