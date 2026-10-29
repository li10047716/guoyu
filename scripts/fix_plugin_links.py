"""修复 Flutter Windows 插件 junction（本机无 Developer Mode 的环境必需）。

flutter 的 pub get / build 过程会重建 `windows/flutter/ephemeral/.plugin_symlinks`：
有时把某个插件写成**真目录**（Dart 的 `link.existsSync()` 对真目录判 false，
随后 `link.createSync()` 撞 errno 183「文件已存在」直接崩溃），有时把其它
junction 清掉（重建真 symlink 需要 Developer Mode，errno 1314 退出）。

本脚本把两处 `.plugin_symlinks`（根目录 + ephemeral）统一修成指向当前
`.flutter-plugins-dependencies` 声明路径的 junction：
- 条目缺失 → 建 junction（mklink /J 不需要特权）；
- 条目是真目录或指向旧目标 → 删掉重建；
- junction 已正确 → 跳过。

build_windows.py 在 pub get 之前自动调用；analyze/test 前手动跑一次亦可。
"""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]

LINK_DIRS = [
    root / ".plugin_symlinks",
    root / "windows" / "flutter" / "ephemeral" / ".plugin_symlinks",
]


def is_junction(path: Path) -> bool:
    try:
        os.readlink(str(path))
        return True
    except OSError:
        return False


def junction_target(path: Path) -> str:
    raw = os.readlink(str(path))
    # mklink 返回的可能是 \\?\ 前缀形式，统一规整化比较。
    return os.path.normcase(os.path.normpath(raw.replace("\\\\?\\", "")))


def fix_dir(link_dir: Path, plugins) -> None:
    link_dir.mkdir(parents=True, exist_ok=True)
    for plugin in plugins:
        name = plugin["name"]
        target = plugin["path"]
        dest = link_dir / name
        if dest.exists():
            if is_junction(dest) and junction_target(dest) == os.path.normcase(
                os.path.normpath(target)
            ):
                continue
            # 真目录（flutter 复制产物）或指向失效旧目标的 junction：清掉重建。
            if is_junction(dest):
                dest.rmdir()
            else:
                shutil.rmtree(dest)
        result = subprocess.run(
            ["cmd", "/c", "mklink", "/J", str(dest), target],
            capture_output=True,
        )
        if result.returncode != 0:
            print(f"[fix_plugin_links] FAILED {name}: {result.stdout!r} {result.stderr!r}")
        else:
            print(f"[fix_plugin_links] linked {name} -> {link_dir.name}")


def main() -> None:
    deps_file = root / ".flutter-plugins-dependencies"
    if not deps_file.exists():
        print("[fix_plugin_links] no .flutter-plugins-dependencies, skip")
        return
    deps = json.loads(deps_file.read_text(encoding="utf-8"))
    plugins = deps.get("plugins", {}).get("windows", [])
    if not plugins:
        print("[fix_plugin_links] no windows plugins, skip")
        return
    for link_dir in LINK_DIRS:
        fix_dir(link_dir, plugins)


if __name__ == "__main__":
    sys.exit(main())
