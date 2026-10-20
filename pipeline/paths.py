"""项目内固定路径。"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WEB_PREVIEW_DIR = ROOT / "web-preview"
IOS_DATA = ROOT / "ios/RiverDiary/RiverDiary/Resources/data.json"
RAW_DATA = ROOT / "data/raw.json"
WEB_DATA = ROOT / "data/data.json"
INGESTED_USER_DATA = ROOT / "data/ios-user-data.json"
ICLOUD_FOLDER = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/河流日记"
ICLOUD_DATA_FILE = ICLOUD_FOLDER / "data.json"
DIST_DIR = ROOT / "dist"
