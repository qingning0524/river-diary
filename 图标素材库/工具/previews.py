#!/usr/bin/env python3
"""Generate the review sheets used in 预览/."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "工具"))
from catalog import ICONS  # noqa: E402
from showcase import read_svg  # noqa: E402

PREVIEW = ROOT / "预览"
PREVIEW.mkdir(exist_ok=True)

MAC_NAV = [("today", "今天"), ("footprints", "足迹"), ("memory", "记忆"), ("river", "River"), ("review", "回顾")]
IOS_NAV = [("today", "今天"), ("footprints", "足迹"), ("confirmations", "待确认"), ("river", "River"), ("profile", "我的")]
TOOLS = ["search", "calendar", "journal", "photo", "lock", "settings"]


def svg(platform: str, state: str, gid: str, size: int) -> str:
    return read_svg(state, gid, size)


def mac_window(dark: bool) -> str:
    state = "dark" if dark else "light"
    rows = "".join(
        f'<div class="row {"on" if gid == "river" else ""}">{svg("mac", "selected-dark" if (dark and gid=="river") else ("selected" if gid=="river" else state), gid, 18)}<span>{label}</span></div>'
        for gid, label in MAC_NAV
    )
    tools = "".join(
        f'<div class="tb {"on" if i == 0 else ""}">{svg("mac", "selected-dark" if (dark and i==0) else ("selected" if i==0 else state), gid, 18)}</div>'
        for i, gid in enumerate(TOOLS)
    )
    return f'''<div class="mac {'dark' if dark else ''}">
  <div class="sidebar"><div class="brand">RIVER DIARY</div>{rows}</div>
  <div class="main">
    <div class="titlebar"><span>今天</span><div class="toolbar">{tools}</div></div>
    <div class="content"><div class="ghost-line w70"></div><div class="ghost-line w40"></div>
      <div class="cards"><div class="mini"></div><div class="mini"></div><div class="mini"></div></div>
      <div class="ghost-line w60"></div><div class="ghost-line w80"></div>
    </div>
  </div>
</div>'''


def ios_phone(dark: bool) -> str:
    state = "dark" if dark else "light"
    tabs = "".join(
        f'<div class="tab {"on" if gid == "river" else ""}">{svg("ios", "selected-dark" if (dark and gid=="river") else ("selected" if gid=="river" else state), gid, 20)}<span>{label}</span></div>'
        for gid, label in IOS_NAV
    )
    return f'''<div class="phone {'dark' if dark else ''}">
  <div class="status"><span>9:41</span><span>RIVER</span></div>
  <div class="phead"><div class="date">10月19日 · 周一</div><div class="ptitle">今天</div></div>
  <div class="pbody"><div class="ghost-line w80"></div><div class="ghost-line w60"></div>
    <div class="pcard"><div class="ghost-line w40"></div><div class="ghost-line w80"></div><div class="ghost-line w70"></div></div>
    <div class="pcard"><div class="ghost-line w30"></div><div class="ghost-line w70"></div></div>
  </div>
  <div class="tabbar">{tabs}</div>
</div>'''


def context_html() -> str:
    return f'''<!doctype html><meta charset="utf-8"><style>
body {{ margin:0; padding:44px 48px; background:#F4F7FB; color:#162233; font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; }}
.top {{ display:flex; align-items:flex-end; justify-content:space-between; margin-bottom:26px; }}
.eyebrow {{ font-family:ui-monospace,"SF Mono",monospace; font-size:11px; letter-spacing:.18em; color:#2F6CF5; }}
h1 {{ font-family:"Songti SC","STSong",serif; font-size:34px; font-weight:600; letter-spacing:-.02em; margin:8px 0 0; }}
.top p {{ margin:0; font-size:12px; color:#6B7C91; }}
.grid {{ display:grid; grid-template-columns:1fr 1fr; gap:22px; }}
.panel {{ background:#fff; border:1px solid #E3EAF3; border-radius:20px; padding:18px; box-shadow:0 18px 44px rgba(20,38,66,.07); }}
.panel.dark {{ background:#151E2A; border-color:#2A3646; }}
.cap {{ display:flex; justify-content:space-between; align-items:center; margin:0 2px 12px; font-size:10px; color:#7C8CA3; font-family:ui-monospace,monospace; letter-spacing:.1em; }}
.mac {{ display:flex; height:360px; border-radius:12px; overflow:hidden; border:1px solid #DCE5F0; background:#EDF1F6; }}
.mac.dark {{ border-color:#33404F; background:#202935; }}
.sidebar {{ width:210px; padding:14px 10px; background:#E8EDF3; border-right:1px solid #D5DFEC; }}
.mac.dark .sidebar {{ background:#1C2530; border-color:#3B495C; }}
.brand {{ font-size:9px; letter-spacing:.18em; color:#7C8CA3; font-weight:700; padding:2px 10px 16px; }}
.mac.dark .brand {{ color:#91A2BA; }}
.row {{ display:flex; align-items:center; gap:10px; padding:6px 10px; border-radius:8px; font-size:12.5px; color:#3A4B63; }}
.row.on {{ background:#DCE7F8; color:#2F6CF5; font-weight:600; }}
.mac.dark .row {{ color:#C7D3E3; }} .mac.dark .row.on {{ background:#2B4166; color:#A2BFFF; }}
.row svg {{ display:block; }}
.main {{ flex:1; display:flex; flex-direction:column; background:#EDF2F7; }}
.mac.dark .main {{ background:#202935; }}
.titlebar {{ display:flex; align-items:center; justify-content:space-between; padding:10px 14px; border-bottom:1px solid #DCE5F0; color:#3A4B63; font-size:12px; font-weight:600; }}
.mac.dark .titlebar {{ border-color:#33404F; color:#E0E8F4; }}
.toolbar {{ display:flex; gap:2px; }}
.tb {{ width:30px; height:28px; display:grid; place-items:center; border-radius:7px; color:#52657D; }}
.tb.on {{ background:#DCE7F8; color:#2F6CF5; }}
.mac.dark .tb {{ color:#A4B3C8; }} .mac.dark .tb.on {{ background:#2B4166; color:#A2BFFF; }}
.content {{ padding:20px 18px; }}
.ghost-line {{ height:7px; border-radius:4px; background:#D9E2EE; opacity:.7; margin-bottom:9px; }}
.mac.dark .ghost-line {{ background:#33404F; }}
.w80 {{ width:80%; }} .w70 {{ width:70%; }} .w60 {{ width:60%; }} .w40 {{ width:40%; }} .w30 {{ width:30%; }}
.cards {{ display:flex; gap:8px; margin:16px 0; }}
.mini {{ flex:1; height:64px; border-radius:10px; background:#F6F9FC; border:1px solid #E1E8F1; }}
.mac.dark .mini {{ background:#25303D; border-color:#3B495C; }}
.phone {{ height:360px; border-radius:30px; overflow:hidden; border:1px solid #DCE5F0; background:#F3F6FA; display:flex; flex-direction:column; }}
.phone.dark {{ border-color:#33404F; background:#202935; }}
.status {{ display:flex; justify-content:space-between; padding:12px 22px 2px; font-size:10.5px; font-weight:600; color:#3A4B63; }}
.phone.dark .status {{ color:#E0E8F4; }}
.phead {{ padding:10px 20px 0; }}
.date {{ font-size:9px; color:#7C8CA3; letter-spacing:.06em; }}
.ptitle {{ font-family:"Songti SC",serif; font-size:24px; font-weight:600; color:#162233; margin-top:2px; }}
.phone.dark .ptitle {{ color:#EAF0F8; }} .phone.dark .date {{ color:#8FA1B8; }}
.pbody {{ padding:10px 16px; flex:1; }}
.pcard {{ background:#fff; border-radius:12px; padding:11px; margin-top:8px; border:1px solid #E6ECF4; }}
.phone.dark .pcard {{ background:#25303D; border-color:#39465A; }}
.phone.dark .ghost-line {{ background:#39465A; }}
.tabbar {{ display:flex; padding:8px 10px 14px; background:#fff; border-top:1px solid #E6ECF4; }}
.phone.dark .tabbar {{ background:#1B2430; border-color:#33404F; }}
.tab {{ flex:1; display:flex; flex-direction:column; align-items:center; gap:3px; font-size:9px; color:#7C8CA3; }}
.tab.on {{ color:#2F6CF5; font-weight:600; }} .phone.dark .tab {{ color:#91A2BA; }} .phone.dark .tab.on {{ color:#A2BFFF; }}
.tab svg {{ display:block; }}
</style>
<div class="top"><div><div class="eyebrow">RIVER GLYPH · IN CONTEXT</div><h1>同一套河流图标，双端共用</h1></div><p>macOS 18pt 侧栏 / 20pt 工具栏 · iOS 20pt Tab</p></div>
<div class="grid">
  <div class="panel"><div class="cap"><span>macOS · LIGHT · ORIGINAL</span><span>18 / 20 pt</span></div>{mac_window(False)}</div>
  <div class="panel dark"><div class="cap" style="color:#7F93AB"><span>macOS · DARK · ORIGINAL</span><span>18 / 20 pt</span></div>{mac_window(True)}</div>
  <div class="panel"><div class="cap"><span>iOS · LIGHT · WATERLINE</span><span>20 pt</span></div>{ios_phone(False)}</div>
  <div class="panel dark"><div class="cap" style="color:#7F93AB"><span>iOS · DARK · WATERLINE</span><span>20 pt</span></div>{ios_phone(True)}</div>
</div>'''


def gallery_html(platform: str, dark: bool = False) -> str:
    size = 24
    title = "河流 · 双端共享"
    sub = "1.75 / 1.25u · Original · 18 / 20 / 24pt" if platform == "mac" else "1.75 / 1.25u · Original · 20 / 24 / 28pt"
    state = "dark" if dark else "light"
    cells = []
    for g in ICONS:
        cells.append(
            f'<div class="cell"><div class="art">{svg(platform, state, g.id, size)}</div>'
            f'<div class="meta"><b>{g.label}</b><code>{g.id}</code></div></div>'
        )
    return f'''<!doctype html><meta charset="utf-8"><style>
body {{ margin:0; padding:38px 42px; background:{"#0D141E" if dark else "#F5F7FA"}; color:{"#E6EDF7" if dark else "#162233"}; font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; }}
.top {{ display:flex; align-items:flex-end; justify-content:space-between; margin-bottom:24px; }}
.eyebrow {{ font-family:ui-monospace,monospace; font-size:10px; letter-spacing:.18em; color:{"#7FAAFF" if dark else "#2F6CF5"}; }}
h1 {{ font-family:"Songti SC","STSong",serif; font-size:30px; font-weight:600; margin:6px 0 0; letter-spacing:-.02em; }}
.top p {{ margin:0; font:11px ui-monospace,monospace; color:{"#7F93AB" if dark else "#7C8CA3"}; letter-spacing:.04em; }}
.grid {{ display:grid; grid-template-columns:repeat(10,1fr); gap:10px; }}
.cell {{ background:{"#18222F" if dark else "#fff"}; border:1px solid {"#2A3646" if dark else "#E4EAF3"}; border-radius:12px; padding:10px 9px 8px; }}
.art {{ height:52px; display:grid; place-items:center; margin-bottom:4px; background:{"#202935" if dark else "#F4F7FB"}; border-radius:9px; }}
.meta b {{ display:block; font-size:10px; font-weight:500; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }}
.meta code {{ font:8px ui-monospace,monospace; color:{"#7F93AB" if dark else "#8A99AD"}; }}
</style>
<div class="top"><div><div class="eyebrow">RIVER GLYPH · {platform.upper()}</div><h1>{title}</h1></div><p>{sub} · 80 GLYPHS</p></div>
<div class="grid">{"".join(cells)}</div>'''


def states_html() -> str:
    rows = []
    for platform, label, size in (("shared", "双端共享", 56),):
        cells = []
        for state in ("light", "dark", "selected", "selected-dark"):
            bg = "#202935" if "dark" in state else "#F4F7FB"
            cells.append(
                f'<div class="state"><div class="art" style="background:{bg}">{svg(platform, state, "memory", size)}</div>'
                f'<span>{state}</span></div>'
            )
        rows.append(f'<div class="row"><div class="label">{label}</div><div class="states">{"".join(cells)}</div></div>')
    return f'''<!doctype html><meta charset="utf-8"><style>
body {{ margin:0; padding:40px 46px; background:#F5F7FA; font-family:-apple-system,"PingFang SC"; color:#162233; }}
h1 {{ font-family:"Songti SC",serif; font-size:28px; margin:0 0 6px; }}
p {{ font-size:12px; color:#6B7C91; margin:0 0 24px; }}
.row {{ display:flex; align-items:center; gap:26px; background:#fff; border:1px solid #E4EAF3; border-radius:18px; padding:18px 22px; margin-bottom:14px; }}
.label {{ width:120px; font-size:12px; color:#5D6E86; }}
.states {{ display:flex; gap:12px; }}
.state {{ text-align:center; }}
.art {{ width:88px; height:88px; border-radius:12px; display:grid; place-items:center; border:1px solid #EDF1F6; }}
.state span {{ display:block; font:9px ui-monospace,monospace; color:#8A99AD; margin-top:5px; }}
</style>
<h1>四种状态</h1><p>选中态同时改变颜色、水位高度与笔画重量。灰度化后仍可区分。</p>
{"".join(rows)}'''


def apps_html() -> str:
    return '''<!doctype html><meta charset="utf-8"><style>
body { margin:0; padding:44px; background:#101B2A; color:#EAF2FF; font-family:-apple-system,"PingFang SC"; }
h1 { font-family:"Songti SC",serif; font-size:28px; margin:0 0 4px; }
p { font-size:12px; color:#9AB0CC; margin:0 0 26px; }
.row { display:flex; gap:30px; align-items:flex-end; }
figure { margin:0; text-align:center; }
img { width:240px; height:240px; display:block; }
figcaption { margin-top:14px; font-size:11px; color:#9AB0CC; letter-spacing:.04em; }
figcaption b { display:block; color:#EAF2FF; font-size:13px; margin-bottom:2px; }
</style>
<h1>应用图标</h1><p>同一道水位穿过品牌双流:iOS 满版,macOS 方舟形。</p>
<div class="row">
<figure><img src="../应用图标/ios-1024.png"><figcaption><b>iOS</b>1024 · 满版</figcaption></figure>
<figure><img src="../应用图标/macos-1024.png"><figcaption><b>macOS</b>1024 · 方舟形 · ICNS</figcaption></figure>
<figure><img src="../应用图标/ios-dark-1024.png"><figcaption><b>iOS · 深色</b>深色主屏</figcaption></figure>
</div>'''


def main() -> None:
    files = {
        "02-双端场景": (context_html(), 1600, 1040),
        "03-80枚图册": (gallery_html("shared"), 1600, 1140),
        "04-深色图册": (gallery_html("shared", True), 1600, 1140),
        "05-四状态": (states_html(), 1100, 420),
        "07-应用图标": (apps_html(), 1200, 420),
    }
    specs = []
    for name, (html, width, height) in files.items():
        path = PREVIEW / f"_{name}.html"
        path.write_text(html, encoding="utf-8")
        specs.append({"url": str(path), "out": str(PREVIEW / f"{name}.png"), "width": width, "height": height})
    shot = ROOT / "工具" / "shot.cjs"
    (ROOT / "工具" / "shot.json").write_text(json.dumps(specs), encoding="utf-8")
    import os

    modules = Path.home() / ".cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules"
    env = dict(os.environ, NODE_PATH=str(modules))
    from runtime import node, node_env
    subprocess.run([node(), str(shot), str(ROOT / "工具" / "shot.json")], check=True, env=node_env())
    for name in files:
        (PREVIEW / f"_{name}.html").unlink()
    (ROOT / "工具" / "shot.json").unlink()
    print("PREVIEWS_READY", PREVIEW)


if __name__ == "__main__":
    main()
