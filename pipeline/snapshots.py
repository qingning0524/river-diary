"""写入和清理带哈希校验的每日快照。"""

import hashlib
import json
from pathlib import Path

from .io import write_if_changed


def entry_hash(entry: dict) -> str:
    canonical = json.dumps(entry, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def daily_manifest_entry(entry: dict, digest: str) -> dict:
    stage = entry.get("stage")
    return {
        "date": entry["date"],
        "path": f"entries/{entry['date']}.json",
        "page_id": entry.get("page_id", ""),
        "title": entry.get("title", ""),
        "score": entry.get("score"),
        "score_source": entry.get("score_source", "ai"),
        "stage": stage.get("label") if isinstance(stage, dict) else None,
        "screen_h": entry.get("screen_h"),
        "hash": digest,
    }


def write_daily_outputs(data: dict, root: Path) -> tuple[int, int]:
    entries_dir = root / "entries"
    entries_dir.mkdir(parents=True, exist_ok=True)

    manifest_entries: list[dict] = []
    expected_files: set[str] = set()
    updated = 0

    for entry in data["entries"]:
        date = entry["date"]
        filename = f"{date}.json"
        expected_files.add(filename)
        digest = entry_hash(entry)
        if write_if_changed(entries_dir / filename, json.dumps(entry, ensure_ascii=False, indent=2) + "\n"):
            updated += 1
        manifest_entries.append(daily_manifest_entry(entry, digest))

    manifest = {
        "version": 1,
        "generated": data.get("generated", ""),
        "today": data.get("today", ""),
        "entry_count": len(manifest_entries),
        "entries": manifest_entries,
    }
    manifest_updated = write_if_changed(root / "manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")

    removed = 0
    for path in entries_dir.glob("*.json"):
        if path.name not in expected_files:
            path.unlink()
            removed += 1

    return updated + (1 if manifest_updated else 0), removed
