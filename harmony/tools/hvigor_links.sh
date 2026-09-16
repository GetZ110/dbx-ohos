#!/usr/bin/env bash
# 在「命令行构建」与「DevEco Studio」两种环境间切换 hvigor 依赖的挂接方式。
#
# 背景（2026-09-16 实测）：
#   - 本机命令行构建（deveco_tools 里的 hvigorw.js）**必须**有
#       node_modules/@ohos/hvigor        -> $DEVECO_TOOLS/hvigor/hvigor
#       node_modules/@ohos/hvigor-ohos-plugin -> $DEVECO_TOOLS/hvigor/hvigor-ohos-plugin
#     这两个符号链接，否则报 "Cannot find module '@ohos/hvigor-ohos-plugin'"
#     （NODE_PATH 不管用，hvigor 用自己的解析逻辑）。
#   - DevEco Studio 是 OHOS 应用、跑在自己的 HNP 沙箱里（日志里的
#       /data/app/hvigor.org/hvigor_1.0.0/bin/hvigorw.js），它自带一份 hvigor +
#     插件；此时项目里指向项目外（deveco_tools）的符号链接会出问题：
#       hvigor ERROR: 00302013 Script Error
#       The root node is not yet available for build.
#     现象是 app 插件没注册出根节点（读不到插件 / 版本与它自带的 hvigor 不匹配）。
#
# 用法：
#   harmony/tools/hvigor_links.sh off     # 用 DevEco 之前跑（删链接 + 清 .hvigor 缓存）
#   harmony/tools/hvigor_links.sh on      # 回到命令行构建（重建链接）
#   harmony/tools/hvigor_links.sh status
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJ="$ROOT/harmony/dbxohos"
TOOLS="${DEVECO_TOOLS:-/storage/Users/currentUser/deveco_tools}"
LINKS=("hvigor" "hvigor-ohos-plugin")

links_on() {
    mkdir -p "$PROJ/node_modules/@ohos"
    for name in "${LINKS[@]}"; do
        if [ ! -d "$TOOLS/hvigor/$name" ]; then
            echo "找不到 $TOOLS/hvigor/$name" >&2
            exit 1
        fi
        ln -sfn "$TOOLS/hvigor/$name" "$PROJ/node_modules/@ohos/$name"
        echo "link: node_modules/@ohos/$name -> $TOOLS/hvigor/$name"
    done
}

links_off() {
    for name in "${LINKS[@]}"; do
        if [ -L "$PROJ/node_modules/@ohos/$name" ]; then
            rm -f "$PROJ/node_modules/@ohos/$name"     # 只删符号链接，不动外部目录
            echo "unlink: node_modules/@ohos/$name"
        elif [ -e "$PROJ/node_modules/@ohos/$name" ]; then
            echo "警告：node_modules/@ohos/$name 不是符号链接（是实体目录），未改动" >&2
        fi
    done
    # 两种 hvigor 版本的缓存别混用：清掉，让 DevEco 自己重建
    rm -rf "$PROJ/.hvigor/cache" "$PROJ/.hvigor/outputs"
    echo "cleaned: .hvigor/cache .hvigor/outputs"
}

status() {
    for name in "${LINKS[@]}"; do
        printf '%-24s ' "$name"
        if [ -L "$PROJ/node_modules/@ohos/$name" ]; then
            echo "symlink -> $(readlink "$PROJ/node_modules/@ohos/$name")"
        elif [ -d "$PROJ/node_modules/@ohos/$name" ]; then
            echo "real dir"
        else
            echo "missing"
        fi
    done
}

case "${1:-}" in
    on)     links_on ;;
    off)    links_off ;;
    status) status ;;
    *)      echo "用法: $0 {on|off|status}" >&2; exit 2 ;;
esac
