#!/usr/bin/env python3
"""把上游 agent 产物打成 HNP（HarmonyOS Native Package），供 HAP 内置分发。

HNP 本质是 zip：hnp.json + bin/ + lib/。
    python3 harmony/tools/build_hnp.py --only oracle          # 只打 oracle（验证用）
    python3 harmony/tools/build_hnp.py --all-native           # 17 个原生 agent 全打
    python3 harmony/tools/build_hnp.py --jre                  # 单独打 JRE 21（public）

产物：
    harmony/dbxohos/entry/hnp/arm64-v8a/dbx-agent-<key>.hnp
    harmony/dbxohos/entry/hnp/arm64-v8a/dbx-jre-21.hnp         (--jre)
    harmony/dbxohos/entry/src/main/resources/rawfile/bundled-drivers.json
        —— 应用侧读取后传给 Rust，用于报告"内置已安装"与解析执行路径。

注意：HNP 内的 ELF **不要**自己签名（自签名反而可能干扰系统按应用证书授权）。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]           # dbx-ohos/
HARMONY = ROOT / "harmony" / "dbxohos"
HNP_DIR = HARMONY / "entry" / "hnp" / "arm64-v8a"
RAWFILE = HARMONY / "entry" / "src" / "main" / "resources" / "rawfile"
MANIFEST_OUT = RAWFILE / "bundled-drivers.json"
CACHE = ROOT / ".tmp" / "hnp-dl"
REGISTRY_CACHE = ROOT / ".tmp" / "agent-registry.json"
PLATFORM = "linux-aarch64"
# 应用侧据此在候选根目录里找 HNP 安装点（见 docs/ohos-agent-exec-denied.md §8）
HNP_ORG_SUFFIX = ".org"

# 默认要打包的原生 agent（agent_connection_pool_database_type!() 里的原生那批 + 常用附加）
ALL_NATIVE = [
    "oracle", "kingbase", "vastbase", "hive", "argo", "neo4j", "cassandra",
    "iotdb", "tdengine", "xugu", "etcd", "etcd2", "zookeeper",
    "duckdb", "rocketmq", "rabbitmq", "sqlite-worker",
]
# 只有 sqlite-worker 需要区分平台目录（其余单文件即可）
PLATFORM_DIR_DRIVERS = {"sqlite-worker"}


def log(msg: str) -> None:
    print(f"[hnp] {msg}", flush=True)


def sanitize_version(version: str) -> str:
    v = re.sub(r"[^0-9A-Za-z._-]", ".", version).strip(".")
    return v or "0"


def ensure_registry() -> dict:
    if REGISTRY_CACHE.is_file() and REGISTRY_CACHE.stat().st_size > 0:
        return json.loads(REGISTRY_CACHE.read_text())
    REGISTRY_CACHE.parent.mkdir(parents=True, exist_ok=True)
    url = "https://github.com/t8y2/dbx/releases/download/agents-latest/agent-registry.json"
    log(f"下载 registry: {url}")
    subprocess.run(["curl", "-sSL", "--retry", "3", "-o", str(REGISTRY_CACHE), url], check=True)
    return json.loads(REGISTRY_CACHE.read_text())


def download(url: str, sha256: str, size: int) -> Path:
    CACHE.mkdir(parents=True, exist_ok=True)
    dest = CACHE / url.rsplit("/", 1)[-1]
    if dest.is_file() and (size == 0 or dest.stat().st_size == size):
        digest = hashlib.sha256(dest.read_bytes()).hexdigest()
        if not sha256 or digest == sha256:
            return dest
    log(f"下载 {dest.name} ({size/1024/1024:.1f} MB)")
    tmp = dest.with_suffix(dest.suffix + ".part")
    subprocess.run(["curl", "-sSL", "--retry", "5", "-C", "-", "-o", str(tmp), url], check=True)
    if tmp.stat().st_size != size:
        raise SystemExit(f"下载大小不符: {tmp.stat().st_size} != {size}")
    if sha256:
        digest = hashlib.sha256(tmp.read_bytes()).hexdigest()
        if digest != sha256:
            raise SystemExit(f"sha256 不符: {digest} != {sha256}")
    tmp.replace(dest)
    return dest


def extract_tar_zst(archive: Path, dest: Path) -> None:
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    subprocess.run(["tar", "--zstd", "-xf", str(archive), "-C", str(dest)], check=True)


def find_single_elf(tree: Path) -> Path:
    """tar 包里 drivers/ 下只有一个文件（可能就是 ELF，也可能是 hnp 之类的 bundle）。"""
    files = [p for p in tree.rglob("*") if p.is_file() and p.name != "agent-registry.json"]
    if len(files) != 1:
        raise SystemExit(f"预期 1 个驱动文件，实际 {len(files)}: {[str(f) for f in files][:5]}")
    return files[0]


SIGN_TOOL = "binary-sign-tool"


def sign_elf(path: Path) -> None:
    """HNP 内的 ELF 必须先签名（安装器的二进制安全校验会读取其签名信息）。"""
    tool = shutil.which(SIGN_TOOL)
    if tool is None:
        raise SystemExit(f"找不到 {SIGN_TOOL}（Harmonybrew/CodeArts SDK 里带）；HNP 内 ELF 必须签名")
    subprocess.run([tool, "sign", "-inFile", str(path), "-outFile", str(path), "-selfSign", "1"], check=True)


def zip_tree(stage: Path, out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for path in sorted(stage.rglob("*")):
            rel = path.relative_to(stage).as_posix()
            if path.is_dir():
                continue
            if path.is_symlink():
                raise SystemExit(f"HNP 内不允许符号链接（鸿蒙动态链接器无法处理）: {rel}")
            info = zipfile.ZipInfo(rel)
            mode = 0o755 if os.access(path, os.X_OK) else 0o644
            info.external_attr = (mode | 0o100000) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, path.read_bytes())


def build_agent_hnp(key: str, registry: dict, out_dir: Path) -> dict:
    driver = registry["drivers"][key]
    artifact = (driver.get("native") or {}).get(PLATFORM)
    if not artifact:
        raise SystemExit(f"{key} 没有 {PLATFORM} 产物")
    archive = download(artifact["url"], artifact.get("sha256", ""), artifact.get("size", 0))
    work = CACHE / f"stage-{key}"
    extract_tar_zst(archive, work)
    elf = find_single_elf(work)

    name = f"dbx-agent-{key}"
    version = sanitize_version(driver["version"])
    stage = CACHE / f"hnp-{key}"
    if stage.exists():
        shutil.rmtree(stage)
    (stage / "bin").mkdir(parents=True)
    target = stage / "bin" / "agent"
    shutil.copy2(elf, target)
    os.chmod(target, 0o755)
    sign_elf(target)
    (stage / "hnp.json").write_text(json.dumps({
        "type": "hnp-config",
        "name": name,
        "version": version,
        "arch": "arm64",
        "os": "ohos",
        "install": {"links": [{"source": "bin/agent", "target": f"dbx-agent-{key}"}]},
    }, indent=2) + "\n")
    out = out_dir / f"{name}.hnp"
    zip_tree(stage, out)
    log(f"{key}: {driver['version']} -> {out.name} ({out.stat().st_size/1024/1024:.2f} MB)")
    return {
        "dbType": key,
        "version": driver["version"],
        "hnpName": name,
        "hnpVersion": version,
        "program": "bin/agent",
        "artifactType": "native",
        "sha256": artifact.get("sha256", ""),
    }


def build_jre_hnp(registry: dict, out_dir: Path) -> dict:
    jre = (registry.get("jres") or {}).get("21")
    if not jre:
        raise SystemExit("registry 里没有 JRE 21")
    artifact = jre["platforms"][PLATFORM]
    archive = download(artifact["url"], artifact.get("sha256", ""), artifact.get("size", 0))
    work = CACHE / "stage-jre21"
    extract_tar_zst(archive, work)
    # tar 顶层通常就是 jdk-21/（也可能多一层），保持原样、只去掉顶层目录名
    tops = [p for p in work.iterdir()]
    stage = CACHE / "hnp-jre21"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    src = tops[0] if len(tops) == 1 and tops[0].is_dir() else work
    for item in sorted(src.iterdir()):
        if item.is_symlink():
            # 符号链接：复制成实体文件（鸿蒙无法处理自签名/内置动态库的 symlink）
            real = item.resolve()
            if real.is_file():
                shutil.copy2(real, stage / item.name)
            elif real.is_dir():
                shutil.copytree(real, stage / item.name, symlinks=False)
        elif item.is_dir():
            shutil.copytree(item, stage / item.name, symlinks=False)
        else:
            shutil.copy2(item, stage / item.name)
    java_rel = "bin/java"
    if not (stage / java_rel).is_file():
        raise SystemExit("JRE 包里找不到 bin/java")
    os.chmod(stage / java_rel, 0o755)
    # lib/ 下所有文件按原权限（.so 需要可读；不依赖 exec 位）
    name = "dbx-jre-21"
    version = sanitize_version(jre["version"])
    (stage / "hnp.json").write_text(json.dumps({
        "type": "hnp-config",
        "name": name,
        "version": version,
        "arch": "arm64",
        "os": "ohos",
        "install": {"links": [{"source": java_rel, "target": "dbx-java-21"}]},
    }, indent=2) + "\n")
    out = out_dir / f"{name}.hnp"
    zip_tree(stage, out)
    log(f"jre-21: {jre['version']} -> {out.name} ({out.stat().st_size/1024/1024:.2f} MB)")
    return {
        "jreKey": "21",
        "version": jre["version"],
        "hnpName": name,
        "hnpVersion": version,
        "javaPath": java_rel,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="逗号分隔的驱动 key，只打这些")
    ap.add_argument("--all-native", action="store_true", help="打全部原生 agent")
    ap.add_argument("--jre", action="store_true", help="额外打 JRE 21")
    ap.add_argument("--keep", action="store_true", help="保留已有 hnp，只追加")
    args = ap.parse_args()

    registry = ensure_registry()
    if args.only:
        keys = [k.strip() for k in args.only.split(",") if k.strip()]
    elif args.all_native:
        keys = list(ALL_NATIVE)
    else:
        keys = ["oracle"]

    missing = [k for k in keys if k not in registry["drivers"]]
    if missing:
        raise SystemExit(f"registry 里没有这些 key: {missing}")

    HNP_DIR.mkdir(parents=True, exist_ok=True)
    RAWFILE.mkdir(parents=True, exist_ok=True)

    manifest_path = MANIFEST_OUT
    manifest = {"schemaVersion": 1, "platform": "arm64", "drivers": {}, "jre": None}
    if args.keep and manifest_path.is_file():
        manifest = json.loads(manifest_path.read_text())

    for key in keys:
        manifest["drivers"][key] = build_agent_hnp(key, registry, HNP_DIR)
    if args.jre or (args.keep and manifest.get("jre")):
        manifest["jre"] = build_jre_hnp(registry, HNP_DIR)

    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    log(f"manifest -> {manifest_path.relative_to(ROOT)} ({len(manifest['drivers'])} drivers)")
    total = sum(p.stat().st_size for p in HNP_DIR.glob("*.hnp"))
    log(f"HNP 合计 {total/1024/1024:.2f} MB，文件: {sorted(p.name for p in HNP_DIR.glob('*.hnp'))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
