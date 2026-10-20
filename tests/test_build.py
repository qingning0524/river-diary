import json
import uuid
from pathlib import Path
import unittest
import tempfile

import pipeline
from pipeline import paths

build = pipeline
ROOT = paths.ROOT
FIXTURE = Path(__file__).parent / "fixtures" / "diary.json"


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
                "page_id": "page-2",
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
                "page_id": "page-1",
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
        source = FIXTURE
        data = build.clean_data(json.loads(source.read_text(encoding="utf-8")))
        self.assertEqual(data["today"], data["entries"][-1]["date"])

    def test_clean_data_adds_summary_and_quality(self):
        raw = {
            "generated": "",
            "entries": [
                {
                    "date": "2000-01-01",
                    "score": 80,
                    "overview": "完成一件事",
                    "plan": "继续",
                    "screen_h": 3.5,
                    "views": 10,
                    "metrics": {"mood": 80, "energy": 70, "focus": 60, "output": 50, "overall": 65, "growth": 68},
                    "stage": {"label": "积极", "color": "#7CB342"},
                    "ios_health": {"steps": 1000},
                },
                {
                    "date": "2000-01-02",
                    "metrics": {"energy": 50, "focus": 50, "output": 50, "overall": 50},
                    "stage": {"label": "平稳", "color": "#D4A017"},
                },
            ],
        }
        cleaned = build.clean_data(raw)
        self.assertEqual(cleaned["summary"]["entry_count"], 2)
        self.assertEqual(cleaned["summary"]["score_average"], 80)
        self.assertEqual(cleaned["summary"]["health"]["steps_total"], 1000)
        self.assertEqual(cleaned["data_quality"]["warning_count"], 5)
        self.assertEqual(cleaned["data_quality"]["critical_count"], 2)
        self.assertEqual(cleaned["data_quality"]["status"], "warning")
        self.assertEqual(cleaned["data_quality"]["issues"]["missing_scores"], ["2000-01-02"])

    def test_clean_data_rejects_invalid_metric(self):
        raw = {
            "today": "2000-01-01",
            "entries": [{
                "date": "2000-01-01",
                "metrics": {"energy": 120, "focus": 50, "output": 50, "overall": 50},
            }],
        }
        with self.assertRaises(ValueError):
            build.clean_data(raw)

    def test_clean_data_fills_missing_stable_page_id(self):
        raw = {
            "today": "2000-01-01",
            "entries": [{
                "date": "2000-01-01",
                "metrics": {"energy": 50, "focus": 50, "output": 50, "overall": 50},
            }],
        }
        cleaned = build.clean_data(raw)
        self.assertEqual(cleaned["entries"][0]["page_id"], str(uuid.uuid5(uuid.NAMESPACE_URL, "river-diary:2000-01-01")))

    def test_merge_ingested_user_data_overrides_score(self):
        data = {
            "entries": [
                {"date": "2026-09-02", "score": 50.0, "score_source": "ai",
                 "metrics": {"mood": 50.0, "energy": 50, "focus": 50, "output": 50, "overall": 50}},
            ]
        }
        build.merge_ingested_user_data(data, Path("/tmp/nonexistent"))
        self.assertEqual(data["entries"][0]["score"], 50.0)

    def test_merge_ingested_user_data_adds_health_summary(self):
        user = {
            "updatedAt": "2026-09-03T00:00:00Z",
            "sleepNights": [{"date": "2026-09-02", "totalHours": 7.2}],
            "exerciseDays": [{
                "date": "2026-09-02", "steps": 8123,
                "distanceKilometers": 5.2, "activeEnergyKilocalories": 260,
            }],
        }
        data = {"entries": [{"date": "2026-09-02", "score": 50.0, "metrics": {}}]}
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "ios-user-data.json"
            source.write_text(json.dumps(user), encoding="utf-8")
            build.merge_ingested_user_data(data, source)

        health = data["entries"][0]["ios_health"]
        self.assertEqual(health["sleep_hours"], 7.2)
        self.assertEqual(health["steps"], 8123)
        self.assertEqual(health["active_energy_kcal"], 260.0)

    def test_write_daily_outputs_creates_manifest_and_removes_stale_files(self):
        import tempfile

        data = {
            "generated": "2000-01-02 00:00",
            "today": "2000-01-02",
            "entries": [
                {"date": "2000-01-01", "page_id": "page-1", "score": 40.0},
                {"date": "2000-01-02", "page_id": "page-2", "score": 60.0},
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stale = root / "entries" / "1999-12-31.json"
            stale.parent.mkdir()
            stale.write_text("{}", encoding="utf-8")

            updated, removed = build.write_daily_outputs(data, root)

            manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
            daily = json.loads((root / "entries/2000-01-02.json").read_text(encoding="utf-8"))
            self.assertEqual(updated, 3)
            self.assertEqual(removed, 1)
            self.assertFalse(stale.exists())
            self.assertEqual(manifest["entry_count"], 2)
        self.assertEqual(manifest["entries"][1]["path"], "entries/2000-01-02.json")
        self.assertEqual(daily["page_id"], "page-2")

    def test_web_template_contains_required_anchor_and_new_controls(self):
        html = (paths.WEB_PREVIEW_DIR / "index.html").read_text(encoding="utf-8")
        anchors = [
            '<link rel="stylesheet" href="css/style.css">',
            '<script src="js/app.js" defer></script>',
            'id="dHealthPanel"',
            'id="healthChips"',
            'id="healthScroll"',
            'id="periodCompare"',
            'id="dataQualityAna"',
            'id="correlationAna"',
            'id="exportCsvBtn"',
            'id="exportJsonBtn"',
            'id="helpModal"',
        ]
        for anchor in anchors:
            self.assertIn(anchor, html)

    def test_built_assets_contain_new_features_and_are_valid_enough(self):
        build.build_assets()
        js = (paths.WEB_PREVIEW_DIR / "js/app.js").read_text(encoding="utf-8")
        css = (paths.WEB_PREVIEW_DIR / "css/style.css").read_text(encoding="utf-8")
        for token in ("renderHealth", "renderPeriodCompare", "renderDataQuality", "renderCorrelations", "exportCsv", "exportJson", "openHelpModal"):
            self.assertIn(token, js)
        for token in (".period-compare", ".help-modal", ".quality-row", ".export-row"):
            self.assertIn(token, css)

    def test_production_data_includes_summary_and_quality(self):
        path = FIXTURE
        data = build.clean_data(json.loads(path.read_text(encoding="utf-8")))
        self.assertEqual(data["summary"]["entry_count"], len(data["entries"]))
        self.assertIn(data["data_quality"]["status"], {"good", "warning", "needs_attention"})
