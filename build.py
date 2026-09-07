#!/usr/bin/env python3
"""兼容入口：新的实现位于 `pipeline/`。"""

from pipeline.assets import build_assets, build_dist
from pipeline.health import apply_mood_scores, build_health_by_date
from pipeline.io import read, write_if_changed
from pipeline.paths import (
    DIST_DIR,
    ICLOUD_DATA_FILE,
    ICLOUD_FOLDER,
    INGESTED_USER_DATA,
    IOS_DATA,
    RAW_DATA,
    ROOT,
    WEB_DATA,
)
from pipeline.records import build_data_quality, build_summary, clean_data, clean_site_name, parse_count
from pipeline.runtime import main, prepare_data
from pipeline.snapshots import daily_manifest_entry, entry_hash, write_daily_outputs


def merge_ingested_user_data(data: dict, ingested_user_data=None) -> None:
    """保持旧 API：可从外部替换采集数据路径。"""
    from pipeline.health import merge_ingested_user_data as merge

    source = ingested_user_data if ingested_user_data is not None else INGESTED_USER_DATA
    merge(data, source)


__all__ = [
    "apply_mood_scores",
    "build_assets",
    "build_data_quality",
    "build_dist",
    "build_health_by_date",
    "build_summary",
    "clean_data",
    "clean_site_name",
    "daily_manifest_entry",
    "entry_hash",
    "main",
    "merge_ingested_user_data",
    "parse_count",
    "prepare_data",
    "read",
    "write_daily_outputs",
    "write_if_changed",
]


if __name__ == "__main__":
    raise SystemExit(main())
