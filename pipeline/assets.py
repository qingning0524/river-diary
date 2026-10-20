"""合并 CSS/JS 并生成单文件网页产物。"""

import json
from pathlib import Path

from .io import read, write_if_changed
from .paths import ROOT, WEB_PREVIEW_DIR


def build_assets() -> tuple[str, str]:
    css = "\n".join(path.read_text(encoding="utf-8") for path in sorted((WEB_PREVIEW_DIR / "src/css").glob("*.css")))
    js = "\n".join(path.read_text(encoding="utf-8") for path in sorted((WEB_PREVIEW_DIR / "src/js").glob("*.js")))
    write_if_changed(WEB_PREVIEW_DIR / "css/style.css", css + "\n")
    write_if_changed(WEB_PREVIEW_DIR / "js/app.js", js + "\n")
    return css, js




def build_dist(css: str, js: str, data: dict) -> Path:
    js = js.replace("</script", "<\\/script")
    data_json = json.dumps(data, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
    html = read("web-preview/index.html")

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
