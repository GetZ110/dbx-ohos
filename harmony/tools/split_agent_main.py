#!/usr/bin/env python3
"""把 Go agent 的 `func main()` 拆成 `main()` + `runStdioAgent()`。

OHOS 走 native child process 时，`Main`（ohos_ncp_shim.c）不能直接调用 Go 的
`main()`，所以每个 driver 都按 oracle-go 的方式拆一次：`main()` 只做转发，
原来的 stdio JSON-RPC 循环体改名成 `runStdioAgent()`。

用法：
    python3 harmony/tools/split_agent_main.py [--check] <driver> [<driver> ...]
    python3 harmony/tools/split_agent_main.py --all
"""

from __future__ import annotations

import argparse
import pathlib
import sys

DRIVERS = [
    "argo-go",
    "cassandra-go",
    "etcd-go",
    "etcd2-go",
    "hive-go",
    "iotdb",
    "kingbase-go",
    "neo4j-go",
    "rabbitmq",
    "rocketmq",
    "vastbase-go",
    "xugu",
    "zookeeper",
]

OLD = "func main() {\n"
NEW = """// main 是普通可执行入口（stdio 版 agent）。
func main() {
\trunStdioAgent()
}

// runStdioAgent 跑 stdin/stdout 的 JSON-RPC 循环。
// OHOS 的 native child process 版本会先把传入的 fd dup2 到 0/1 再调用它。
func runStdioAgent() {
"""


def transform(text: str) -> str:
    if "func runStdioAgent()" in text:
        return text
    if text.count(OLD) != 1:
        raise SystemExit(f"期望恰好一个 `func main() {{`，实际 {text.count(OLD)} 个")
    return text.replace(OLD, NEW, 1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("drivers", nargs="*")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--check", action="store_true", help="只检查，不写回")
    args = parser.parse_args()

    repo = pathlib.Path(__file__).resolve().parents[2]
    base = repo / "upstream" / "dbx" / "agents" / "drivers"
    targets = DRIVERS if args.all else args.drivers
    if not targets:
        parser.error("需要 driver 名或 --all")

    for name in targets:
        path = base / name / "main.go"
        if not path.is_file():
            raise SystemExit(f"找不到 {path}")
        text = path.read_text()
        updated = transform(text)
        state = "已经是拆分后的形态" if updated == text else "需要拆分"
        print(f"{name:<14} {state}")
        if updated != text and not args.check:
            path.write_text(updated)
    return 0


if __name__ == "__main__":
    sys.exit(main())
