"""小而可测试的文件读写工具。"""

from pathlib import Path

from .paths import ROOT


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def write_if_changed(path: Path, content: str) -> bool:
    encoded = content.encode("utf-8")
    if path.exists() and path.read_bytes() == encoded:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".tmp")
    try:
        temp.write_bytes(encoded)
        temp.replace(path)
    finally:
        if temp.exists():
            temp.unlink()
    return True
