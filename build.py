#!/usr/bin/env python3
"""构建网页、清洗数据，并把同一份快照同步到 iOS。"""

import hashlib
import datetime as dt
import json
import re
import sys
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parent
IOS_DATA = ROOT / "ios/RiverDiary/RiverDiary/Resources/data.json"
RAW_DATA = ROOT / "data/raw.json"
WEB_DATA = ROOT / "data/data.json"
INGESTED_USER_DATA = ROOT / "data/ios-user-data.json"
ICLOUD_FOLDER = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/河流日记"
ICLOUD_DATA_FILE = ICLOUD_FOLDER / "data.json"
DIST_DIR = ROOT / "dist"


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


def build_assets() -> tuple[str, str]:
    css = "\n".join(path.read_text(encoding="utf-8") for path in sorted((ROOT / "src/css").glob("*.css")))
    js = "\n".join(path.read_text(encoding="utf-8") for path in sorted((ROOT / "src/js").glob("*.js")))
    write_if_changed(ROOT / "css/style.css", css + "\n")
    write_if_changed(ROOT / "js/app.js", js + "\n")
    return css, js


def clean_site_name(site: str) -> str:
    match = re.match(r"^\[([^\]]+)\]\(", site)
    if match:
        site = match.group(1)
    if site.startswith("[") and site.endswith("]"):
        site = site[1:-1]
    site = re.sub(r"\s*（[^）]*）\s*$", "", site)
    return re.sub(r"\s+", " ", site).strip()


def parse_count(site: dict) -> int:
    for value in (site.get("n"), site.get("count")):
        if isinstance(value, bool):
            continue
        if isinstance(value, int):
            return value
        if isinstance(value, str):
            match = re.search(r"\d+", value.replace("\\~", "").replace("~", ""))
            if match:
                return int(match.group())
    return 0


def _number(value: object, *, low: float = 0, high: float = 100) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"数值类型错误：{value!r}")
    number = float(value)
    if not low <= number <= high:
        raise ValueError(f"数值超出范围：{number}（允许 {low}–{high}）")
    return number


def clean_data(raw: dict) -> dict:
    cleaned = json.loads(json.dumps(raw, ensure_ascii=False))
    entries = cleaned.get("entries")
    if not isinstance(entries, list) or not entries:
        raise ValueError("数据必须包含非空 entries 数组")

    dates: set[str] = set()
    for entry in entries:
        date = entry.get("date")
        if not isinstance(date, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
            raise ValueError(f"日期格式错误：{date!r}")
        if not isinstance(entry.get("page_id"), str) or not entry["page_id"].strip():
            entry["page_id"] = str(uuid.uuid5(uuid.NAMESPACE_URL, f"river-diary:{date}"))
        if date in dates:
            raise ValueError(f"日期重复：{date}")
        dates.add(date)

        score = entry.get("score")
        if score is not None:
            entry["score"] = _number(score)
        entry.setdefault("score_source", "ai")
        if entry["score_source"] not in {"ai", "user"}:
            raise ValueError(f"{date} 的 score_source 只能是 ai 或 user")

        metrics = entry.get("metrics")
        if not isinstance(metrics, dict):
            raise ValueError(f"{date} 缺少 metrics")
        for key in ("energy", "focus", "output", "overall", "mood", "growth"):
            if key in metrics and metrics[key] is not None:
                metrics[key] = _number(metrics[key])

        normalized: dict[str, int] = {}
        for site in entry.get("browse_sites") or []:
            name = clean_site_name(str(site.get("site", "")))
            count = parse_count(site)
            if not name or count <= 0:
                continue
            normalized[name] = normalized.get(name, 0) + count
        entry["browse_sites"] = [
            {"site": name, "n": count, "count": str(count)}
            for name, count in sorted(normalized.items(), key=lambda item: item[1], reverse=True)
        ]

    entries.sort(key=lambda item: item["date"])
    if cleaned.get("today") not in dates:
        cleaned["today"] = entries[-1]["date"]

    if not isinstance(cleaned.get("generated"), str) or not cleaned["generated"].strip():
        cleaned["generated"] = dt.datetime.now().strftime("%Y-%m-%d %H:%M")
    cleaned["summary"] = build_summary(cleaned)
    cleaned["data_quality"] = build_data_quality(cleaned)
    return cleaned


def build_summary(data: dict) -> dict:
    entries = data.get("entries", [])
    def values(key: str) -> list[float]:
        return [entry[key] for entry in entries if entry.get(key) is not None]

    def metric_values(key: str) -> list[float]:
        return [
            entry["metrics"][key]
            for entry in entries
            if isinstance(entry.get("metrics"), dict) and entry["metrics"].get(key) is not None
        ]

    def average(values_: list[float]) -> float | None:
        return round(sum(values_) / len(values_), 1) if values_ else None

    scored = values("score")
    health = [entry.get("ios_health", {}) for entry in entries if isinstance(entry.get("ios_health"), dict)]
    return {
        "entry_count": len(entries),
        "date_start": entries[0]["date"] if entries else None,
        "date_end": entries[-1]["date"] if entries else None,
        "score_average": average(scored),
        "metrics_average": {
            key: average(metric_values(key))
            for key in ("mood", "energy", "focus", "output", "overall", "growth")
        },
        "screen_hours_total": round(sum(sum(float(app.get("min") or 0) for app in entry.get("screen_apps") or []) / 60 for entry in entries), 1),
        "browse_count_total": sum(int(entry.get("views") or 0) for entry in entries),
        "health": {
            "sleep_days": sum("sleep_hours" in day for day in health),
            "step_days": sum("steps" in day for day in health),
            "steps_total": sum(int(day.get("steps") or 0) for day in health),
        },
    }


def build_data_quality(data: dict) -> dict:
    entries = data.get("entries", [])
    missing_scores: list[str] = []
    missing_overview: list[str] = []
    missing_plan: list[str] = []
    invalid_stage: list[str] = []
    valid_stages = {"低谷", "回升", "平稳", "积极", "饱满"}
    for entry in entries:
        if entry.get("score") is None:
            missing_scores.append(entry["date"])
        if not str(entry.get("overview") or "").strip():
            missing_overview.append(entry["date"])
        if not str(entry.get("plan") or "").strip():
            missing_plan.append(entry["date"])
        stage = entry.get("stage")
        if not isinstance(stage, dict) or stage.get("label") not in valid_stages:
            invalid_stage.append(entry["date"])

    issues = {
        "missing_scores": missing_scores,
        "missing_overview": missing_overview,
        "missing_plan": missing_plan,
        "invalid_stage": invalid_stage,
    }
    critical_count = len(missing_scores) + len(missing_overview) + len(invalid_stage)
    warning_count = critical_count * 2 + len(missing_plan)
    if critical_count == 0 and not missing_plan:
        status = "good"
    elif critical_count <= 3:
        status = "warning"
    else:
        status = "needs_attention"
    return {
        "status": status,
        "critical_count": critical_count,
        "score": max(0, round(100 - warning_count * max(0, 100 // max(1, len(entries))) * 2)),
        "warning_count": warning_count,
        "issues": issues,
    }


def prepare_data() -> dict:
    source = RAW_DATA if RAW_DATA.exists() else WEB_DATA
    cleaned = clean_data(json.loads(source.read_text(encoding="utf-8")))
    merge_ingested_user_data(cleaned)
    web_text = json.dumps(cleaned, ensure_ascii=False, indent=2) + "\n"
    write_if_changed(WEB_DATA, web_text)
    write_if_changed(IOS_DATA, web_text)
    dist_written, dist_removed = write_daily_outputs(cleaned, DIST_DIR)
    print(f"已生成每日数据: {len(cleaned['entries'])} 条（更新 {dist_written}，清理 {dist_removed}）")
    if ICLOUD_FOLDER.exists():
        try:
            write_if_changed(ICLOUD_DATA_FILE, web_text)
            icloud_written, icloud_removed = write_daily_outputs(cleaned, ICLOUD_FOLDER)
            print(
                "已同步到 iCloud Drive: "
                f"data.json + manifest.json + {icloud_written} 条每日数据（清理 {icloud_removed}）"
            )
        except OSError as error:
            print(f"跳过 iCloud 同步（无法写入 iCloud Drive）：{error}")
    return cleaned


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


def merge_ingested_user_data(data: dict) -> None:
    if not INGESTED_USER_DATA.exists():
        return

    try:
        user = json.loads(INGESTED_USER_DATA.read_text(encoding="utf-8"))
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


def build_dist(css: str, js: str, data: dict) -> Path:
    js = js.replace("</script", "<\\/script")
    data_json = json.dumps(data, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
    html = read("index.html")

    assert '<link rel="stylesheet" href="css/style.css">' in html, "模板缺少 css 外链锚点"
    assert '<script src="js/app.js" defer></script>' in html, "模板缺少 app.js 外链锚点"

    html = html.replace(
        '<link rel="stylesheet" href="css/style.css">',
        "<style>\n" + css + "\n</style>",
        1,
    )
    html = html.replace(
        '<script src="js/app.js" defer></script>',
        '<script id="diary-data" type="application/json">' + data_json
        + "</script>\n<script>\n" + js + "\n</script>",
        1,
    )

    out = ROOT / "dist/index.html"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(html, encoding="utf-8")
    return out


def main() -> int:
    css, js = build_assets()
    data = prepare_data()
    out = build_dist(css, js, data)

    print(f"已生成 {out.relative_to(ROOT)}  ({out.stat().st_size / 1024:.0f} KB)")
    print(f'数据: {len(data["entries"])} 条记录 · 生成于 {data.get("generated", "?")}')
    print("已同步: data/data.json + manifest/entries + iOS Resources/data.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
