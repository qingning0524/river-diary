"""构建流水线的编排入口。"""

import json

from .assets import build_assets, build_dist
from .health import merge_ingested_user_data
from .io import write_if_changed
from .paths import ROOT, DIST_DIR, ICLOUD_DATA_FILE, ICLOUD_FOLDER, IOS_DATA, RAW_DATA, WEB_DATA
from .records import clean_data
from .snapshots import write_daily_outputs


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


def main() -> int:
    css, js = build_assets()
    data = prepare_data()
    out = build_dist(css, js, data)

    print(f"已生成 {out.relative_to(ROOT)}  ({out.stat().st_size / 1024:.0f} KB)")
    print(f'数据: {len(data["entries"])} 条记录 · 生成于 {data.get("generated", "?")}')
    print("已同步: data/data.json + manifest/entries + iOS Resources/data.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
