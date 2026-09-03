#!/usr/bin/env python3
"""构建网页、清洗数据，并把同一份快照同步到 iOS。"""

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent
IOS_DATA = ROOT / "ios/RiverDiary/RiverDiary/Resources/data.json"
RAW_DATA = ROOT / "data/raw.json"
WEB_DATA = ROOT / "data/data.json"
IOS_USER_DATA = ROOT / "data/ios-user-data.json"
ICLOUD_FOLDER = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/河流日记"
ICLOUD_DATA_FILE = ICLOUD_FOLDER / "data.json"


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def write_if_changed(path: Path, content: str) -> bool:
    encoded = content.encode("utf-8")
    if path.exists() and path.read_bytes() == encoded:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(encoded)
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
        if date in dates:
            raise ValueError(f"日期重复：{date}")
        dates.add(date)

        score = entry.get("score")
        if score is not None and not 0 <= float(score) <= 100:
            raise ValueError(f"{date} 的 score 超出 0–100：{score}")
        entry.setdefault("score_source", "ai")

        metrics = entry.get("metrics")
        if not isinstance(metrics, dict):
            raise ValueError(f"{date} 缺少 metrics")
        for key in ("energy", "focus", "output", "overall"):
            value = metrics.get(key)
            if value is not None and not 0 <= float(value) <= 100:
                raise ValueError(f"{date} 的 metrics.{key} 超出范围：{value}")

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
    return cleaned


def prepare_data() -> dict:
    source = RAW_DATA if RAW_DATA.exists() else WEB_DATA
    cleaned = clean_data(json.loads(source.read_text(encoding="utf-8")))
    merge_ios_user_data(cleaned)
    web_text = json.dumps(cleaned, ensure_ascii=False, indent=2) + "\n"
    write_if_changed(WEB_DATA, web_text)
    write_if_changed(IOS_DATA, web_text)
    if ICLOUD_FOLDER.exists():
        write_if_changed(ICLOUD_DATA_FILE, web_text)
        print(f"已同步到 iCloud Drive: {ICLOUD_DATA_FILE.name}")
    return cleaned


def merge_ios_user_data(data: dict) -> None:
    if not IOS_USER_DATA.exists():
        return

    try:
        user = json.loads(IOS_USER_DATA.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return

    entries = data.get("entries")
    if not isinstance(entries, list):
        return

    mood_scores = user.get("moodScores")
    if isinstance(mood_scores, dict):
        apply_mood_scores(data["entries"], mood_scores)

    health_by_date = build_health_by_date(user)
    if health_by_date:
        applied_health = 0
        for entry in data["entries"]:
            health = health_by_date.get(entry.get("date"))
            if health:
                entry["ios_health"] = health
                applied_health += 1
        if applied_health:
            print(f"已合并 iOS 健康摘要: {applied_health} 天")


def apply_mood_scores(entries: list, mood_scores: dict) -> None:
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

    if applied:
        print(f"已合并 iOS 用户评分: {applied} 天")


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
            health["exercise_minutes"] = round(max(0.0, float(day.get("exerciseMinutes", 0))), 1)
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
    print("已同步: data/data.json + iOS Resources/data.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
