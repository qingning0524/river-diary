#!/usr/bin/env python3
"""Hermes ↔ iOS 数据同步桥。

用法:
  python3 tools/hermes_sync.py          一次性同步
  python3 tools/hermes_sync.py --watch  持续监听文件变化

输出:
  data/ios-user-data.json  供 Hermes 管道读取的清洗后数据
"""

import argparse
import hashlib
import json
import shutil
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ICLOUD_FILE = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/河流日记/river-diary-user-data.json"
OUTPUT_FILE = ROOT / "data/ios-user-data.json"
HASH_CACHE = ROOT / "data/.ios-sync-hash"


def file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_last_hash() -> str:
    if HASH_CACHE.exists():
        return HASH_CACHE.read_text().strip()
    return ""


def save_hash(value: str) -> None:
    HASH_CACHE.parent.mkdir(parents=True, exist_ok=True)
    HASH_CACHE.write_text(value)


def sync() -> dict | None:
    if not ICLOUD_FILE.exists():
        print(f"[hermes-sync] 未找到 iOS 数据: {ICLOUD_FILE}", file=sys.stderr)
        return None

    current = file_hash(ICLOUD_FILE)
    if current == load_last_hash():
        return None

    try:
        raw = json.loads(ICLOUD_FILE.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as error:
        print(f"[hermes-sync] 解析失败: {error}", file=sys.stderr)
        return None

    mood_scores = raw.get("moodScores")
    if not isinstance(mood_scores, dict):
        mood_scores = {}

    sleep_nights = raw.get("sleepNights")
    if not isinstance(sleep_nights, list):
        sleep_nights = []

    quick_notes = raw.get("quickNotes")
    if not isinstance(quick_notes, list):
        quick_notes = []

    exercise_days = raw.get("exerciseDays")
    if not isinstance(exercise_days, list):
        exercise_days = []

    cleaned = {
        "syncedAt": datetime.now(timezone.utc).isoformat(),
        "updatedAt": raw.get("updatedAt"),
        "moodScores": {
            date: int(score)
            for date, score in mood_scores.items()
            if isinstance(date, str) and isinstance(score, (int, float)) and 0 <= score <= 100
        },
        "sleepNights": [
            {
                "date": night.get("date", ""),
                "totalHours": round(float(night.get("totalHours", 0)), 2),
                "deepMinutes": round(float(night.get("deepMinutes", 0)), 1),
                "remMinutes": round(float(night.get("remMinutes", 0)), 1),
                "awakeMinutes": round(float(night.get("awakeMinutes", 0)), 1),
            }
            for night in sleep_nights
            if isinstance(night, dict) and night.get("date")
        ],
        "exerciseDays": [
            {
                "date": day.get("date", ""),
                "steps": int(float(day.get("steps", 0))),
                "distanceKilometers": round(float(day.get("distanceKilometers", 0)), 2),
                "activeEnergyKilocalories": round(float(day.get("activeEnergyKilocalories", 0)), 1),
            }
            for day in exercise_days
            if isinstance(day, dict) and day.get("date")
        ],
        "quickNotes": [
            {
                "date": note.get("date", ""),
                "text": str(note.get("text", "")).strip(),
                "createdAt": note.get("createdAt"),
            }
            for note in quick_notes
            if isinstance(note, dict) and note.get("date") and note.get("text")
        ],
    }

    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_FILE.write_text(
        json.dumps(cleaned, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    save_hash(current)

    print(f"[hermes-sync] 同步完成: {OUTPUT_FILE.relative_to(ROOT)}")
    print(f"  心情评分: {len(cleaned['moodScores'])} 天")
    print(f"  睡眠记录: {len(cleaned['sleepNights'])} 晚")
    print(f"  运动记录: {len(cleaned['exerciseDays'])} 天")
    print(f"  快速笔记: {len(cleaned['quickNotes'])} 条")
    return cleaned


def watch(interval: float = 5.0) -> None:
    print(f"[hermes-sync] 监听中 (每 {interval}s 检查一次)…")
    print(f"  源: {ICLOUD_FILE}")
    print(f"  输出: {OUTPUT_FILE.relative_to(ROOT)}")
    try:
        while True:
            sync()
            time.sleep(interval)
    except KeyboardInterrupt:
        print("\n[hermes-sync] 已停止")


def main() -> int:
    parser = argparse.ArgumentParser(description="Hermes ↔ iOS 数据同步")
    parser.add_argument("--watch", action="store_true", help="持续监听文件变化")
    parser.add_argument("--interval", type=float, default=5.0, help="监听间隔（秒）")
    args = parser.parse_args()

    if args.watch:
        watch(interval=args.interval)
    else:
        result = sync()
        if result is None:
            print("[hermes-sync] 没有新数据需要同步")
        return 0


if __name__ == "__main__":
    sys.exit(main())
