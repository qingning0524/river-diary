"""日记记录清洗、汇总和数据体检。"""

import datetime as dt
import json
import re
import uuid


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
