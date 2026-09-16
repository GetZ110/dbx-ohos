#!/usr/bin/env python3
"""为 OHOS/musl 生成 Go 运行时的两处补丁 overlay（不改全局 GOROOT）。

背景（完整证据链见 docs/ohos-agent-exec-denied.md §13.3）：
Go 的 c-shared 库在 OHOS 上由 appspawn 用 dlopen 加载，会在 musl 上撞两堵墙：

1. **initial-exec TLS**：linux/arm64 的 `runtime.load_g`/`save_g` 用 IE 模型访问
   `runtime.tls_g`，而 musl 只给 dlopen 进来的模块分配"动态 TLS"，解析不了 IE
   重定位 —— `dlopen` 直接失败：
   `Error relocating libX.so: initial-exec TLS resolves to dynamic definition`。
   补丁：`runtime/tls_arm64.s` 的 load_g/save_g 改调 C 侧 `dbxLoadG`/`dbxSaveG`
   （`__thread`，走 dynamic TLS）。C 侧实现见 agent 目录下的 ohos_ncp_shim.c。

2. **argc/argv 是垃圾**：`_rt0_arm64_lib` 假设加载器按 C ABI 把 argc/argv 放在
   R0/R1；musl 调 init_array 时不传（实测 x0=0x100000001），`runtime.args` 会去
   扫垃圾指针 → SIGSEGV（崩在 runtime.sysargs/IndexByteString）。
   补丁：`runtime/asm_arm64.s` 里改成用自带的一块合法骨架
   `argv=["dbx-agent",NULL] envp=[NULL] auxv=[AT_NULL]`；Go 的 sysargs 发现
   auxv 为空会自动回退读 /proc/self/auxv，因此真实 auxv（页大小/HWCAP）不丢。

用法：
    python3 harmony/tools/go_ohos_overlay.py [--out DIR]
输出：
    DIR/asm_arm64.patched.s, DIR/tls_arm64.patched.s, DIR/overlay.json
（DIR 默认 .tmp/go-ohos-overlay）
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys

TLS_OLD_LOAD = """\tMRS_TPIDR_R0
#ifdef TLS_darwin
\t// Darwin sometimes returns unaligned pointers
\tAND\t$0xfffffffffffffff8, R0
#endif
\tMOVD\truntime·tls_g(SB), R27
\tMOVD\t(R0)(R27), g
"""

TLS_NEW_LOAD = """#ifdef GOOS_linux
\t// OHOS/musl 补丁：改成 dynamic TLS（C 侧 __thread）。musl 不会给 dlopen 的
\t// 模块分配静态 TLS，initial-exec 重定位会直接让 dlopen 失败。
\tBL\tdbxLoadG(SB)
\tMOVD\tR0, g
#else
\tMRS_TPIDR_R0
#ifdef TLS_darwin
\t// Darwin sometimes returns unaligned pointers
\tAND\t$0xfffffffffffffff8, R0
#endif
\tMOVD\truntime·tls_g(SB), R27
\tMOVD\t(R0)(R27), g
#endif
"""

TLS_OLD_SAVE = """\tMRS_TPIDR_R0
#ifdef TLS_darwin
\t// Darwin sometimes returns unaligned pointers
\tAND\t$0xfffffffffffffff8, R0
#endif
\tMOVD\truntime·tls_g(SB), R27
\tMOVD\tg, (R0)(R27)
"""

TLS_NEW_SAVE = """#ifdef GOOS_linux
\tMOVD\tg, R0
\tBL\tdbxSaveG(SB)
#else
\tMRS_TPIDR_R0
#ifdef TLS_darwin
\t// Darwin sometimes returns unaligned pointers
\tAND\t$0xfffffffffffffff8, R0
#endif
\tMOVD\truntime·tls_g(SB), R27
\tMOVD\tg, (R0)(R27)
#endif
"""

# GOOS_linux 上不再需要 TLSBSS 的 tls_g（所有引用都被上面的补丁替换掉了）
TLS_OLD_GLOBL = """#else
GLOBL runtime·tls_g+0(SB), TLSBSS, $8
#endif"""

TLS_NEW_GLOBL = """#else
#ifndef GOOS_linux
GLOBL runtime·tls_g+0(SB), TLSBSS, $8
#endif
#endif"""

RT0_OLD_ARGS = """\tMOVD\tR0, _rt0_arm64_lib_argc<>(SB)
\tMOVD\tR1, _rt0_arm64_lib_argv<>(SB)
"""

RT0_NEW_ARGS = """#ifdef GOOS_linux
\t// OHOS/musl 补丁：musl 调 init_array 时不传 argc/argv（R0/R1 是垃圾值，
\t// 会让 runtime.args/sysargs 扫垃圾指针而崩）。这里给一块合法骨架：
\t//   argv = ["dbx-agent", NULL], envp = [NULL], auxv = [AT_NULL, 0]
\t// auxv 为空时 sysargs 会自己回退读 /proc/self/auxv，拿到真实 auxv。
\tMOVD\t$dbx_lib_args<>(SB), R1
\tMOVD\t$dbx_lib_arg0<>(SB), R2
\tMOVD\tR2, 0(R1)\t// argv[0]
\tMOVD\tZR, 8(R1)\t// argv[1] = NULL
\tMOVD\tZR, 16(R1)\t// envp[0] = NULL
\tMOVD\tZR, 24(R1)\t// auxv[0].tag = AT_NULL
\tMOVD\tZR, 32(R1)\t// auxv[0].val
\tMOVD\t$1, R0\t\t// argc
#endif
\tMOVD\tR0, _rt0_arm64_lib_argc<>(SB)
\tMOVD\tR1, _rt0_arm64_lib_argv<>(SB)
"""

RT0_OLD_DATA = """DATA _rt0_arm64_lib_argv<>(SB)/8, $0
GLOBL _rt0_arm64_lib_argv<>(SB),NOPTR, $8
"""

RT0_NEW_DATA = RT0_OLD_DATA + """
#ifdef GOOS_linux
DATA dbx_lib_arg0<>+0(SB)/16, $"dbx-agent"
GLOBL dbx_lib_arg0<>(SB), RODATA, $16
GLOBL dbx_lib_args<>(SB), NOPTR, $40
#endif
"""


def go_env(name: str) -> str:
    return subprocess.check_output(["go", "env", name], text=True).strip()


def patch(path: pathlib.Path, replacements: list[tuple[str, str]]) -> str:
    text = path.read_text()
    for old, new in replacements:
        count = text.count(old)
        if count != 1:
            raise SystemExit(
                f"{path}: 期望匹配 1 次，实际 {count} 次。"
                "Go 版本可能变了，请对照本脚本顶部的说明重新确认补丁点。"
            )
        text = text.replace(old, new)
    return text


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=None, help="输出目录（默认 <repo>/.tmp/go-ohos-overlay）")
    parser.add_argument("--goroot", default=None, help="GOROOT（默认取 go env GOROOT）")
    args = parser.parse_args()

    repo = pathlib.Path(__file__).resolve().parents[2]
    out = pathlib.Path(args.out) if args.out else repo / ".tmp" / "go-ohos-overlay"
    out.mkdir(parents=True, exist_ok=True)

    goroot = pathlib.Path(args.goroot or go_env("GOROOT"))
    runtime_dir = goroot / "src" / "runtime"
    if not runtime_dir.is_dir():
        raise SystemExit(f"找不到 Go 运行时源码目录：{runtime_dir}")

    tls_src = runtime_dir / "tls_arm64.s"
    asm_src = runtime_dir / "asm_arm64.s"

    tls_out = out / "tls_arm64.patched.s"
    asm_out = out / "asm_arm64.patched.s"

    tls_out.write_text(
        patch(
            tls_src,
            [
                (TLS_OLD_LOAD, TLS_NEW_LOAD),
                (TLS_OLD_SAVE, TLS_NEW_SAVE),
                (TLS_OLD_GLOBL, TLS_NEW_GLOBL),
            ],
        )
    )
    asm_out.write_text(
        patch(
            asm_src,
            [
                (RT0_OLD_ARGS, RT0_NEW_ARGS),
                (RT0_OLD_DATA, RT0_NEW_DATA),
            ],
        )
    )

    overlay = out / "overlay.json"
    overlay.write_text(
        json.dumps(
            {
                "Replace": {
                    str(tls_src): str(tls_out),
                    str(asm_src): str(asm_out),
                }
            },
            indent=2,
        )
        + "\n"
    )

    print(f"go={go_env('GOVERSION')} goroot={goroot}")
    print(f"overlay: {overlay}")
    print(f"  {tls_out}")
    print(f"  {asm_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
