"""合并 iOS 本地采集的心理评分和健康摘要。"""

import json
from pathlib import Path

from .records import build_data_quality, build_summary
from . import paths


def merge_ingested_user_data(data: dict, ingested_user_data: Path | None = None) -> None:
    source = Path(ingested_user_data or paths.INGESTED_USER_DATA)
    if not source.exists():
        return

    try:
        user = json.loads(source.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return

    entries = data.get("entries")
    if not isinstance(entries, list):
        return

    mood_scores = user.get("moodScores")
    applied_scores = apply_mood_scores(data["entries"], mood_scores) if isinstance(mood_scores, dict) else 0

    health_by_date = build_health_by_date(user)
    applied_health = 0
    if health_by_date:
        for entry in data["entries"]:
            health = health_by_date.get(entry.get("date"))
            if health:
                entry["ios_health"] = health
                applied_health += 1

    if data.get("summary"):
        data["summary"] = build_summary(data)
    if data.get("data_quality"):
        data["data_quality"] = build_data_quality(data)
    if applied_scores:
        print(f"已合并采集评分: {applied_scores} 天")
    if applied_health:
        print(f"已合并采集健康摘要: {applied_health} 天")


def apply_mood_scores(entries: list, mood_scores: dict) -> int:
    applied = 0
    for entry in entries:
        date = entry.get("date")
        if date in mood_scores:
            score = int(mood_scores[date])
            if 0 <= score <= 100:
                entry["score"] = float(score)
                entry["score_source"] = "user"
                metrics = entry.get("metrics")
                if isinstance(metrics, dict):
                    metrics["mood"] = float(score)
                applied += 1

    return applied


def build_health_by_date(user: dict) -> dict[str, dict]:
    health_by_date: dict[str, dict] = {}

    for night in user.get("sleepNights") or []:
        if not isinstance(night, dict) or not isinstance(night.get("date"), str):
            continue
        try:
            total_hours = max(0.0, float(night.get("totalHours", 0)))
        except (TypeError, ValueError):
            continue
        if total_hours <= 0:
            continue
        health_by_date.setdefault(night["date"], {})["sleep_hours"] = round(total_hours, 2)

    for day in user.get("exerciseDays") or []:
        if not isinstance(day, dict) or not isinstance(day.get("date"), str):
            continue
        try:
            health = health_by_date.setdefault(day["date"], {})
            health["steps"] = max(0, int(float(day.get("steps", 0))))
            health["distance_km"] = round(max(0.0, float(day.get("distanceKilometers", 0))), 2)
            health["active_energy_kcal"] = round(max(0.0, float(day.get("activeEnergyKilocalories", 0))), 1)
        except (TypeError, ValueError):
            continue

    if health_by_date:
        updated_at = user.get("updatedAt")
        for health in health_by_date.values():
            if updated_at:
                health["updated_at"] = updated_at

    return health_by_date


