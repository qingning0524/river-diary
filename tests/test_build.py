import importlib.util
import unittest.mock
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("river_build", ROOT / "build.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class BuildTests(unittest.TestCase):
    def test_clean_site_name_repairs_markdown_and_annotations(self):
        self.assertEqual(build.clean_site_name("[bilibili.com](http://bilibili"), "bilibili.com")
        self.assertEqual(build.clean_site_name("[yopu.com](http://yopu.com)（找吉他谱"), "yopu.com")

    def test_clean_data_normalizes_counts_sites_and_today(self):
        raw = {
        "today": "2000-01-02",
        "entries": [
            {
                "date": "2000-01-02",
                "score": 60,
                "metrics": {"energy": 50, "focus": 50, "output": 50, "overall": 50},
                "browse_sites": [
                    {"site": "[a.com](http://a", "n": 3, "count": "3"},
                    {"site": "a.com", "n": 2, "count": 2},
                    {"site": "域名", "n": 0, "count": "次数"},
                ],
            },
            {
                "date": "2000-01-01",
                "score": 40,
                "metrics": {"energy": 50, "focus": 50, "output": 50, "overall": 50},
            },
        ],
    }

        cleaned = build.clean_data(raw)
        self.assertEqual([entry["date"] for entry in cleaned["entries"]], ["2000-01-01", "2000-01-02"])
        self.assertEqual(cleaned["today"], "2000-01-02")
        self.assertEqual(cleaned["entries"][0]["score_source"], "ai")
        self.assertEqual(cleaned["entries"][1]["browse_sites"], [{"site": "a.com", "n": 5, "count": "5"}])

    def test_production_snapshot_is_valid(self):
        source = build.RAW_DATA if build.RAW_DATA.exists() else build.WEB_DATA
        data = build.clean_data(json.loads(source.read_text(encoding="utf-8")))
        self.assertEqual(data["today"], data["entries"][-1]["date"])

    def test_merge_ios_user_data_overrides_score(self):
        data = {
            "entries": [
                {"date": "2026-09-02", "score": 50.0, "score_source": "ai",
                 "metrics": {"mood": 50.0, "energy": 50, "focus": 50, "output": 50, "overall": 50}},
            ]
        }
        with unittest.mock.patch.object(build, "IOS_USER_DATA", Path("/tmp/nonexistent")):
            build.merge_ios_user_data(data)
        self.assertEqual(data["entries"][0]["score"], 50.0)

    def test_merge_ios_user_data_adds_health_summary(self):
        user = {
            "updatedAt": "2026-09-03T00:00:00Z",
            "sleepNights": [{"date": "2026-09-02", "totalHours": 7.2}],
            "exerciseDays": [{
                "date": "2026-09-02", "exerciseMinutes": 32.4, "steps": 8123,
                "distanceKilometers": 5.2, "activeEnergyKilocalories": 260,
            }],
        }
        data = {"entries": [{"date": "2026-09-02", "score": 50.0, "metrics": {}}]}
        with unittest.mock.patch.object(
            build, "IOS_USER_DATA", ROOT / "data/.test-ios-user-data.json"
        ), unittest.mock.patch.object(
            build, "merge_ios_user_data", build.merge_ios_user_data
        ):
            (ROOT / "data/.test-ios-user-data.json").write_text(json.dumps(user), encoding="utf-8")
            build.merge_ios_user_data(data)
            (ROOT / "data/.test-ios-user-data.json").unlink()

        health = data["entries"][0]["ios_health"]
        self.assertEqual(health["sleep_hours"], 7.2)
        self.assertEqual(health["exercise_minutes"], 32.4)
        self.assertEqual(health["steps"], 8123)
        self.assertEqual(health["active_energy_kcal"], 260.0)
