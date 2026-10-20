#!/usr/bin/env python3
"""预览或清理可再生成的缓存；Xcode 测试证据先转存到 output/qa。"""

import argparse
import os
from pathlib import Path
import shutil


ROOT = Path(__file__).resolve().parents[1]
CACHES = (
    ".build", ".simbuild", "ios/.build", "ios/.simbuild", "ios/.signedbuild",
    "ios/.devicebuild", "ios/.simrelease", "macos/RiverDiaryMac/.build",
    "Packages/RiverDiaryCore/.build", "server/admin-ui/node_modules", "server/dist",
)


def cache_paths():
    for relative in CACHES:
        path = ROOT / relative
        if path.exists() and not path.is_symlink():
            yield path
    for current, directories, files in os.walk(ROOT, followlinks=False):
        directories[:] = [
            name for name in directories
            if name not in {".git", "archive", "dist", "node_modules", ".build",
                            ".simbuild", ".signedbuild", ".devicebuild", ".simrelease"}
        ]
        if "__pycache__" in directories:
            yield Path(current) / "__pycache__"
            directories.remove("__pycache__")
        if ".DS_Store" in files:
            yield Path(current) / ".DS_Store"


def preserve_test_results(cache):
    for result in sorted(cache.rglob("*.xcresult")):
        if result.is_symlink():
            continue
        destination = (
            ROOT / "output/qa/xcode-results"
            / str(cache.relative_to(ROOT)).replace("/", "-").replace(".", "")
            / result.name
        )
        original = destination
        version = 1
        while destination.exists():
            destination = original.with_name(f"{original.stem}-{version}{original.suffix}")
            version += 1
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(result), str(destination))
        print(f"保留测试记录：{destination.relative_to(ROOT)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="执行清理；默认只预览")
    args = parser.parse_args()
    paths = list(cache_paths())
    for path in paths:
        print(f"{'清理' if args.apply else '可清理'}：{path.relative_to(ROOT)}")
        if args.apply:
            if path.is_dir():
                preserve_test_results(path)
                shutil.rmtree(path)
            else:
                path.unlink()
    print(f"{'已清理' if args.apply else '预览完成'} {len(paths)} 项。")
    if not args.apply:
        print("确认后运行 make clean；源码、数据、历史归档和当前安装包均保留。")


if __name__ == "__main__":
    main()
