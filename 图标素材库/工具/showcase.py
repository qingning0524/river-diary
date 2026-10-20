#!/usr/bin/env python3
"""Build the self-contained showcase: 展示/index.html."""
from __future__ import annotations

import html
import json
import itertools
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / "共享语义" / "manifest.json").read_text(encoding="utf-8"))
ICONS = MANIFEST["icons"]
CATEGORIES = MANIFEST["categories"]
INSTANCE = itertools.count()
STATES = ["light", "dark", "selected", "selected-dark"]
STATE_LABEL = {"light": "浅色", "dark": "深色", "selected": "选中", "selected-dark": "深色选中"}


def read_svg(state: str, gid: str, size: int) -> str:
    entry = next(i for i in ICONS if i["id"] == gid)
    text = (ROOT / entry["svg"][state]).read_text(encoding="utf-8")
    # IDs must be unique per inline instance, including hero and hidden state layers.
    import re
    suffix = f"-instance-{next(INSTANCE)}"
    for old in re.findall(r'id="([^"]+)"', text):
        text = text.replace(f'id="{old}"', f'id="{old}{suffix}"').replace(f'url(#{old})', f'url(#{old}{suffix})')
    return text.replace('width="24" height="24"', f'width="{size}" height="{size}"', 1)


def layers(gid: str, size: int) -> str:
    inner = "".join(
        f'<span class="layer" data-state="{s}">{read_svg(s, gid, size)}</span>'
        for s in STATES
    )
    return f'<span class="glyph-stack">{inner}</span>'


def nav_icon(gid: str, size: int, label: str) -> str:
    return (
        f'<div class="nav-item"><div class="nav-glyph">{layers(gid, size)}</div>'
        f"<span>{label}</span></div>"
    )


def card(icon: dict) -> str:
    gid = icon["id"]
    search = f'{icon["label"]} {gid} {icon["category"]}'.lower()
    return f'''<a class="glyph-card" download href="../{icon["svg"]["light"]}" data-id="{gid}" data-search="{html.escape(search)}" data-cat="{html.escape(icon["category"])}">
  <div class="sizes">
    <div class="slot mac">{layers(gid, 18)}<em>macOS</em></div>
    <div class="slot ios">{layers(gid, 20)}<em>iOS</em></div>
  </div>
  <div class="meta"><b>{html.escape(icon["label"])}</b><code>{gid}</code></div>
</a>'''


def library() -> str:
    return "".join(card(i) for i in ICONS)


def category_chips() -> str:
    chips = ['<button class="chip is-on" data-cat="全部">全部 <span>80</span></button>']
    for c in CATEGORIES:
        n = sum(1 for i in ICONS if i["category"] == c)
        chips.append(f'<button class="chip" data-cat="{html.escape(c)}">{html.escape(c)} <span>{n}</span></button>')
    return "".join(chips)


def meta_rows() -> str:
    rows = [
        ("Mac 显示尺寸", "16 / 18 / 20 / 24 pt · 同一份 Original 资源"),
        ("iOS 显示尺寸", "20 / 24 / 28 / 32 pt · 同一份 Original 资源"),
        ("笔画", "主体 1.75u · 细节 1.25u · 选中 +0.2u"),
        ("网格", "24 × 24 · 共享几何 · 圆头与凸圆角"),
        ("状态", "浅色 · 深色 · 选中 · 深色选中"),
        ("命名", "RiverGlyphToday · RiverGlyphTodaySelected"),
    ]
    return "".join(f"<tr><th>{k}</th><td>{v}</td></tr>" for k, v in rows)


def page() -> str:
    nav_mac = "".join(
        nav_icon(gid, 20, label)
        for gid, label in [("today", "今天"), ("footprints", "足迹"), ("memory", "记忆"), ("river", "River"), ("review", "回顾")]
    )
    nav_ios = "".join(
        nav_icon(gid, 20, label)
        for gid, label in [("today", "今天"), ("footprints", "足迹"), ("confirmations", "待确认"), ("river", "River"), ("profile", "我的")]
    )
    anatomy_mac = read_svg("light", "confirmations", 132)
    anatomy_ios = read_svg("light", "confirmations", 320)

    return f'''<!doctype html>
<html lang="zh-CN" data-theme="light">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>River Glyph · 河流图标系统</title>
<style>
:root {{
  --paper: #F5F7FA; --paper-2: #EDF1F6; --card: #FFFFFF; --ink: #162233;
  --ink-2: #56687F; --ink-3: #8998AB; --line: #DFE6EF; --line-2: #EDF1F6;
  --accent: #2F6CF5; --accent-soft: #E4EDFF; --water: #EAF2FF;
  --shadow: 0 18px 50px rgba(20, 38, 66, .07);
  --serif: "Songti SC", "STSong", "Noto Serif SC", ui-serif, Georgia, serif;
  --sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Helvetica Neue", sans-serif;
  --mono: "SF Mono", ui-monospace, "Roboto Mono", Menlo, monospace;
}}
html[data-theme="dark"] {{
  --paper: #0D141E; --paper-2: #131C28; --card: #18222F; --ink: #E6EDF7;
  --ink-2: #A6B4C7; --ink-3: #74849A; --line: #2A3646; --line-2: #202B3A;
  --accent: #7FAAFF; --accent-soft: #23324C; --water: #1B2B44;
  --shadow: 0 18px 50px rgba(0, 0, 0, .35);
}}
* {{ box-sizing: border-box; }}
html {{ scroll-behavior: smooth; }}
body {{
  margin: 0; background: var(--paper); color: var(--ink); font-family: var(--sans);
  -webkit-font-smoothing: antialiased; line-height: 1.6;
}}
a {{ color: inherit; text-decoration: none; }}
code {{ font-family: var(--mono); font-size: .78em; color: var(--ink-3); }}
.wrap {{ max-width: 1240px; margin: 0 auto; padding: 0 40px; }}
.topbar {{
  position: sticky; top: 0; z-index: 30; backdrop-filter: saturate(180%) blur(18px);
  background: color-mix(in srgb, var(--paper) 82%, transparent); border-bottom: 1px solid var(--line-2);
}}
.topbar .wrap {{ display: flex; align-items: center; justify-content: space-between; height: 60px; }}
.brand {{ display: flex; align-items: center; gap: 10px; font-weight: 650; letter-spacing: .12em; font-size: 12px; }}
.brand svg {{ width: 22px; height: 22px; }}
.top-actions {{ display: flex; gap: 8px; }}
.ghost {{
  border: 1px solid var(--line); background: transparent; color: var(--ink-2); border-radius: 999px;
  padding: 7px 14px; font: inherit; font-size: 12px; cursor: pointer;
}}
.ghost:hover {{ color: var(--accent); border-color: var(--accent); }}
.hero {{ padding: 76px 0 42px; }}
.hero-grid {{ display: grid; grid-template-columns: 1.08fr .92fr; gap: 56px; align-items: center; }}
.eyebrow {{ font-family: var(--mono); font-size: 11px; letter-spacing: .18em; color: var(--accent); text-transform: uppercase; }}
h1 {{
  font-family: var(--serif); font-size: clamp(40px, 4.4vw, 64px); line-height: 1.16; font-weight: 600;
  letter-spacing: -.03em; margin: 18px 0 22px;
}}
h1 em {{ font-style: normal; color: var(--accent); }}
.lede {{ font-size: 16px; color: var(--ink-2); max-width: 520px; margin: 0 0 26px; }}
.meta-chips {{ display: flex; flex-wrap: wrap; gap: 8px; }}
.meta-chips span {{
  font-family: var(--mono); font-size: 10.5px; letter-spacing: .04em; color: var(--ink-2);
  border: 1px solid var(--line); border-radius: 999px; padding: 5px 10px;
}}
.plate {{
  position: relative; border-radius: 26px; padding: 34px; overflow: hidden;
  background: radial-gradient(120% 120% at 18% 8%, #2E64D8 0%, #173A7C 55%, #0E2554 100%);
  color: #EAF2FF; box-shadow: var(--shadow);
}}
.plate::after {{
  content: ""; position: absolute; left: 0; right: 0; top: 63%; height: 1px;
  background: linear-gradient(90deg, transparent, rgba(210,230,255,.55), transparent);
}}
.plate-row {{ display: flex; justify-content: space-between; align-items: flex-end; position: relative; z-index: 1; }}
.specimen {{ text-align: center; }}
.specimen .art {{ width: 132px; height: 132px; display: grid; place-items: center; }}
.specimen .art svg {{ width: 120px; height: 120px; }}
.specimen span {{ display: block; margin-top: 10px; font-family: var(--mono); font-size: 10px; letter-spacing: .16em; color: #A9C2E8; }}
.plate-title {{ position: absolute; top: 22px; left: 30px; font-family: var(--mono); font-size: 10px; letter-spacing: .2em; color: #9AB6E2; }}
.plate-foot {{ display: flex; justify-content: space-between; margin-top: 22px; font-family: var(--mono); font-size: 10px; letter-spacing: .08em; color: #A9C2E8; position: relative; z-index: 1; }}
section {{ padding: 54px 0; }}
.sec-head {{ display: flex; align-items: baseline; gap: 18px; margin-bottom: 26px; }}
.sec-head .num {{ font-family: var(--mono); font-size: 11px; color: var(--accent); letter-spacing: .14em; }}
.sec-head h2 {{ font-family: var(--serif); font-size: 30px; letter-spacing: -.02em; margin: 0; font-weight: 600; }}
.sec-head p {{ margin: 0 0 0 auto; color: var(--ink-3); font-size: 12px; max-width: 340px; }}
.dual {{ display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }}
.voice {{
  background: var(--card); border: 1px solid var(--line-2); border-radius: 22px; padding: 26px 26px 20px;
  box-shadow: var(--shadow);
}}
.voice-top {{ display: flex; align-items: center; justify-content: space-between; }}
.voice h3 {{ margin: 0; font-size: 18px; letter-spacing: .01em; }}
.voice .tag {{ font-family: var(--mono); font-size: 10px; letter-spacing: .1em; color: var(--accent); background: var(--accent-soft); padding: 4px 9px; border-radius: 999px; }}
.voice p {{ color: var(--ink-2); font-size: 13px; margin: 8px 0 18px; min-height: 42px; }}
.nav-strip {{ display: flex; justify-content: space-between; background: var(--paper-2); border-radius: 16px; padding: 14px 18px; }}
.nav-item {{ display: flex; flex-direction: column; align-items: center; gap: 6px; font-size: 10px; color: var(--ink-2); }}
.nav-glyph {{ width: 28px; height: 28px; display: grid; place-items: center; }}
.nav-item:first-child .nav-glyph, .nav-item:last-child .nav-glyph {{ color: var(--accent); }}
.spec-list {{ margin: 16px 0 0; padding: 0; list-style: none; font-size: 12px; color: var(--ink-2); display: grid; gap: 6px; }}
.spec-list b {{ color: var(--ink); font-weight: 600; }}
.anatomy {{ display: grid; grid-template-columns: 1.05fr .95fr; gap: 26px; background: var(--card); border: 1px solid var(--line-2); border-radius: 24px; padding: 30px; box-shadow: var(--shadow); }}
.anatomy-art {{ min-width: 0; display: grid; grid-template-columns: 1.4fr .8fr; gap: 10px; align-items: center; border-radius: 18px; background: var(--paper-2); padding: 18px; }}
.anatomy-art .big {{ display: grid; place-items: center; }}
.anatomy-art .small {{ display: grid; gap: 12px; place-items: center; }}
.anatomy-art .cap {{ display: block; font-family: var(--mono); font-size: 9px; letter-spacing: .12em; color: var(--ink-3); }}
.anatomy-art .big {{ display: flex; flex-direction: column; align-items: center; gap: 8px; }}
.anatomy-art .small {{ display: flex; flex-direction: column; align-items: center; gap: 8px; }}
.anatomy-art .small svg {{ width: 132px; height: 132px; }}
.rule {{ display: grid; grid-template-columns: 30px 1fr; gap: 14px; padding: 13px 0; border-bottom: 1px solid var(--line-2); }}
.rule:last-child {{ border-bottom: 0; }}
.rule .n {{
  width: 26px; height: 26px; border-radius: 50%; border: 1px solid var(--line); display: grid; place-items: center;
  font-family: var(--mono); font-size: 10px; color: var(--accent);
}}
.rule b {{ font-size: 13px; display: block; margin-bottom: 2px; }}
.rule p {{ margin: 0; font-size: 12px; color: var(--ink-2); }}
.table {{ width: 100%; border-collapse: collapse; background: var(--card); border: 1px solid var(--line-2); border-radius: 20px; overflow: hidden; box-shadow: var(--shadow); }}
.table th, .table td {{ text-align: left; padding: 13px 20px; border-bottom: 1px solid var(--line-2); font-size: 12.5px; }}
.table tr:last-child th, .table tr:last-child td {{ border-bottom: 0; }}
.table th {{ width: 160px; color: var(--ink-3); font-weight: 500; font-family: var(--mono); font-size: 10.5px; letter-spacing: .06em; }}
.library {{ padding-top: 20px; }}
.filters {{
  position: sticky; top: 60px; z-index: 20; display: flex; flex-wrap: wrap; gap: 8px; align-items: center;
  padding: 12px 0 14px; background: color-mix(in srgb, var(--paper) 94%, transparent); backdrop-filter: blur(16px);
  border-bottom: 1px solid var(--line-2); margin-bottom: 20px;
}}
#cats {{ flex-basis: 100%; display: flex; flex-wrap: wrap; gap: 7px; padding-top: 2px; }}
section[id] {{ scroll-margin-top: 84px; }}
.seg {{ display: inline-flex; border: 1px solid var(--line); border-radius: 999px; padding: 2px; background: var(--card); }}
.seg button {{ border: 0; background: transparent; color: var(--ink-2); font: inherit; font-size: 11.5px; padding: 6px 12px; border-radius: 999px; cursor: pointer; }}
.seg button.is-on {{ background: var(--accent); color: white; }}
.chip {{
  border: 1px solid var(--line); background: transparent; color: var(--ink-2); border-radius: 999px;
  padding: 6px 11px; font: inherit; font-size: 11.5px; cursor: pointer; white-space: nowrap;
}}
.chip span {{ color: var(--ink-3); font-family: var(--mono); font-size: 10px; margin-left: 3px; }}
.chip.is-on {{ border-color: var(--accent); color: var(--accent); background: var(--accent-soft); }}
.search {{ margin-left: auto; border: 1px solid var(--line); background: var(--card); border-radius: 999px; padding: 7px 14px; font: inherit; font-size: 12px; color: var(--ink); width: 180px; }}
.search:focus {{ outline: 2px solid color-mix(in srgb, var(--accent) 45%, transparent); outline-offset: 1px; }}
.grid {{ display: grid; grid-template-columns: repeat(8, 1fr); gap: 10px; }}
.glyph-card {{
  background: var(--card); border: 1px solid var(--line-2); border-radius: 14px; padding: 12px 10px 10px;
  transition: transform .18s ease, border-color .18s ease, box-shadow .18s ease;
}}
.glyph-card:hover {{ transform: translateY(-2px); border-color: color-mix(in srgb, var(--accent) 35%, var(--line)); box-shadow: 0 10px 24px rgba(20, 38, 66, .07); }}
.glyph-card[hidden] {{ display: none; }}
.sizes {{ display: flex; align-items: center; justify-content: center; gap: 10px; min-height: 72px; border-radius: 10px; margin: -2px -2px 4px; padding: 6px 2px; transition: background .18s ease; }}
body[data-state="dark"] .sizes, body[data-state="selected-dark"] .sizes {{ background: #202935; }}
.slot {{ display: flex; flex-direction: column; align-items: center; gap: 4px; }}
.slot em {{ display: none; font-style: normal; font-family: var(--mono); font-size: 7.5px; letter-spacing: .08em; color: var(--ink-3); }}
body.compare .slot em {{ display: block; }}
.glyph-stack {{ display: grid; place-items: center; width: 40px; height: 40px; }}
.layer {{ display: none; }}
.layer svg {{ display: block; }}
body[data-state="light"] .layer[data-state="light"],
body[data-state="dark"] .layer[data-state="dark"],
body[data-state="selected"] .layer[data-state="selected"],
body[data-state="selected-dark"] .layer[data-state="selected-dark"] {{ display: block; }}
body[data-platform="mac"] .slot.ios {{ display: none; }}
body[data-platform="ios"] .slot.mac {{ display: none; }}
body.compare .sizes {{ gap: 6px; }}
body.compare .slot {{ display: flex !important; }}
body.compare .slot.mac .glyph-stack {{ width: 32px; height: 32px; }}
body.compare .slot.ios .glyph-stack {{ width: 36px; height: 36px; }}
.meta {{ margin-top: 6px; display: flex; align-items: baseline; justify-content: space-between; gap: 4px; }}
.meta b {{ font-size: 11px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
.meta code {{ font-size: 8.5px; color: var(--ink-3); white-space: nowrap; }}
.empty {{ display: none; padding: 60px; text-align: center; color: var(--ink-3); }}
.app {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; }}
.app figure {{ margin: 0; background: var(--card); border: 1px solid var(--line-2); border-radius: 22px; padding: 26px; text-align: center; box-shadow: var(--shadow); }}
.app img {{ width: 168px; height: 168px; border-radius: 34px; box-shadow: 0 16px 36px rgba(14, 35, 70, .18); }}
.app figcaption {{ margin-top: 14px; font-size: 12px; color: var(--ink-2); }}
.app figcaption b {{ display: block; color: var(--ink); font-size: 13px; margin-bottom: 2px; }}
.code {{ background: #101A28; color: #D7E3F4; border-radius: 18px; padding: 22px 24px; overflow: auto; font-family: var(--mono); font-size: 12px; line-height: 1.75; }}
.code .c {{ color: #6F87A6; }} .code .k {{ color: #9DC0FF; }} .code .s {{ color: #A6E3C4; }}
.note {{ display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-top: 20px; }}
.note div {{ border: 1px solid var(--line-2); border-radius: 18px; padding: 18px 20px; background: var(--card); }}
.note b {{ display: block; font-size: 13px; margin-bottom: 4px; }}
.note p {{ margin: 0; font-size: 12px; color: var(--ink-2); }}
footer {{ border-top: 1px solid var(--line-2); margin-top: 40px; padding: 34px 0 60px; color: var(--ink-3); font-size: 11.5px; }}
footer .wrap {{ display: flex; justify-content: space-between; gap: 20px; flex-wrap: wrap; }}
@media (max-width: 980px) {{
  .hero-grid, .dual, .anatomy, .note {{ grid-template-columns: 1fr; }}
  .grid {{ grid-template-columns: repeat(5, 1fr); }}
  .app {{ grid-template-columns: 1fr; }}
  .sec-head p {{ display: none; }}
}}
@media (max-width: 640px) {{
  .wrap {{ padding: 0 20px; }}
  .grid {{ grid-template-columns: repeat(3, 1fr); }}
  .search {{ width: 100%; margin-left: 0; }}
  .anatomy {{ padding: 16px; }}
  .anatomy-art {{ grid-template-columns: minmax(0,1fr); min-width: 0; padding: 12px; }}
  .anatomy-art .big, .anatomy-art .small {{ min-width: 0; }}
  .anatomy-art .big svg {{ width: min(100%, 260px); height: auto; }}
  .anatomy-art .small svg {{ width: min(100%, 132px); height: auto; }}
  .meta {{ flex-wrap: wrap; }}
  .meta code {{ overflow-wrap: anywhere; white-space: normal; }}
  .grid {{ grid-template-columns: repeat(3,minmax(0,1fr)); }}
  .table th, .table td {{ padding: 10px 8px; }}
  .table th {{ width: 95px; }}
  .hero h1 {{ font-size: clamp(30px,9vw,48px); }}
}}
@media (prefers-reduced-motion: reduce) {{ * {{ transition: none !important; }} }}
</style>
</head>
<body data-platform="mac" data-state="light">
<div class="topbar"><div class="wrap">
  <a class="brand" href="#top"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M15.12 1.92C.48 7.2 22.8 15.6 5.28 22.08"/><path d="M19.92 1.92C5.28 7.2 27.6 15.6 10.08 22.08" opacity=".55"/></svg>RIVER GLYPH</a>
  <div class="top-actions">
    <button class="ghost" id="theme">深色</button>
    <a class="ghost" href="../原生资源包/RiverGlyph-SVG.zip">下载 SVG</a>
  </div>
</div></div>

<main id="top">
<div class="wrap hero">
  <div class="hero-grid">
    <div>
      <div class="eyebrow">Icon language · v2.0 · 80 shared glyphs</div>
      <h1>河流的形状，<br>成为<em>界面的语言</em>。</h1>
      <p class="lede">一套河流图标，双端共用。承载资料的容器留出可见水口，水面向右抬升；双笔画与双色强调构成统一轮廓，选中时水位和笔画一起变化。Mac 与 iPhone 使用完全相同的图形，只按界面调整尺寸。</p>
      <div class="meta-chips"><span>80 SHARED GLYPHS</span><span>4 STATES</span><span>24u GRID</span><span>ONE FAMILY / ORIGINAL</span></div>
    </div>
    <div class="plate">
      <div class="plate-title">ONE FAMILY · TWO PLATFORMS</div>
      <div class="plate-row">
        <div class="specimen"><div class="art">{read_svg("dark", "confirmations", 124)}</div><span>macOS · 共用</span></div>
        <div class="specimen"><div class="art">{read_svg("dark", "confirmations", 124)}</div><span>iOS · 共用</span></div>
      </div>
      <div class="plate-foot"><span>CONFIRMATIONS / 待确认</span><span>24 → 18 / 20 pt</span></div>
    </div>
  </div>
</div>

<section class="wrap" id="voices">
  <div class="sec-head"><span class="num">01</span><h2>一套图标，两个场景</h2><p>同一份轮廓、颜色与状态规则。尺寸随界面调整，风格始终一致。</p></div>
  <div class="dual">
    <div class="voice">
      <div class="voice-top"><h3>工作区 · Workspace</h3><span class="tag">macOS</span></div>
      <p>1.75u 主体与 1.25u 细节。保留轻盈的双笔画，同时与 iPhone 共用双色水位与形态选中态。</p>
      <div class="nav-strip">{nav_mac}</div>
      <ul class="spec-list"><li><b>尺寸</b> 18 侧栏 · 20 工具栏 · 24 空态</li><li><b>状态</b> 浅色 / 深色 / 选中 / 深色选中</li></ul>
    </div>
    <div class="voice">
      <div class="voice-top"><h3>随身记录 · Everyday</h3><span class="tag">iOS</span></div>
      <p>与 Mac 使用相同资源。容器保留 18% 染色水位；选中时水位从 60% 抬升到 46%，笔画加重 0.2u。</p>
      <div class="nav-strip">{nav_ios}</div>
      <ul class="spec-list"><li><b>尺寸</b> 20 Tab · 24 工具栏 · 28 详情</li><li><b>状态</b> 浅色 / 深色 / 选中 / 深色选中</li></ul>
    </div>
  </div>
</section>

<section class="wrap" id="anatomy">
  <div class="sec-head"><span class="num">02</span><h2>四条规则</h2><p>水口、水位、双笔、圆端。四个动作足以让 80 枚图标被认成同一家人。</p></div>
  <div class="anatomy">
    <div class="anatomy-art">
      <div class="big">{anatomy_ios}<span class="cap">iOS · 共用 · 320px</span></div>
      <div class="small">{anatomy_mac}<span class="cap">同一轮廓 · 缩小适配</span></div>
    </div>
    <div>
      <div class="rule"><span class="n">01</span><div><b>水口 · Mouth</b><p>容器在右下方向留出 3.8u 中心线开口，圆头收边；它是「河流离开容器」的地方，也是整套图形最容易被记住的缺口。</p></div></div>
      <div class="rule"><span class="n">02</span><div><b>水位 · Level</b><p>在有水位的容器里，水面永远向右抬升 0.8u。两端都用 18% 染色与 72% 不透明度的水位线；选中时水位同步抬升。</p></div></div>
      <div class="rule"><span class="n">03</span><div><b>双笔 · Two weights</b><p>主体与细节永远差一档：1.75 / 1.25（双端共用）。细节是证据，不是第二套轮廓。</p></div></div>
      <div class="rule"><span class="n">04</span><div><b>圆端 · Round</b><p>所有端点圆头、转角圆角，不用直角。图标没有尖锐的末端——像水，也像一个不会打断你的界面。</p></div></div>
    </div>
  </div>
</section>

<section class="wrap" id="states">
  <div class="sec-head"><span class="num">03</span><h2>状态与尺寸</h2><p>颜色不是唯一信号：选中态同时改变水位高度与笔画重量。</p></div>
  <table class="table">{meta_rows()}</table>
</section>

<section class="wrap library" id="library">
  <div class="sec-head"><span class="num">04</span><h2>完整图库</h2><p>点击单枚下载当前状态的共享 SVG；尺寸切换仅用于观察不同界面的显示效果。</p></div>
  <div class="filters">
    <div class="seg" id="platform"><button class="is-on" data-platform="mac">Mac 18pt</button><button data-platform="ios">iPhone 20pt</button></div>
    <div class="seg" id="state"><button class="is-on" data-state="light">浅色</button><button data-state="dark">深色</button><button data-state="selected">选中</button><button data-state="selected-dark">深色选中</button></div>
    <button class="ghost" id="compare" aria-pressed="false">双端对照</button>
    <input class="search" id="search" type="search" placeholder="搜索名称 / ID / 分类" aria-label="搜索图标">
    <div id="cats">{category_chips()}</div>
  </div>
  <div class="grid" id="grid">{library()}</div>
  <div class="empty" id="empty">没有匹配的图标。</div>
</section>

<section class="wrap" id="app">
  <div class="sec-head"><span class="num">05</span><h2>应用图标</h2><p>同一道水位穿过品牌双流。iOS 满版，macOS 保留方舟形与投影。</p></div>
  <div class="app">
    <figure><img src="../应用图标/ios-1024.png" alt="iOS 应用图标"><figcaption><b>iOS · 满版</b>1024 × 1024 · 深浅两版</figcaption></figure>
    <figure><img src="../应用图标/macos-1024.png" alt="macOS 应用图标"><figcaption><b>macOS · 方舟形</b>1024 · 含 .icns 与 .iconset</figcaption></figure>
    <figure><img src="../应用图标/ios-dark-1024.png" alt="iOS 深色应用图标"><figcaption><b>iOS · 深色</b>深色主屏外观</figcaption></figure>
  </div>
</section>

<section class="wrap" id="code">
  <div class="sec-head"><span class="num">06</span><h2>接入</h2><p>共享组件不默认切换 App 绑定；接入时先替换导航与工具栏；不要用图标替代文字标签，也不要把颜色当作唯一状态。</p></div>
  <pre class="code"><span class="c">// 同一组件与资源目录加入双端 target</span>
RiverGlyphView(.memory, state: isSelected ? .selected : .normal, size: 18)

<span class="c">// iOS Tab：选中态切换图片，水位自动抬升</span>
RiverGlyphView(.river,
               state: selected ? .selected : .normal,
               size: 20)

<span class="c">// 资源命名：RiverGlyphToday · RiverGlyphTodaySelected</span></pre>
  <div class="note">
    <div><b>存量图标迁移</b><p>旧 SF Symbols 与旧图集不一次性删除。先按「语义 ID → 新资源」映射替换导航、空态与卡片动作；截图验收通过后再清理旧图。</p></div>
    <div><b>不可省略的文字</b><p>图标不承载唯一必要信息。水位是装饰性层次，不是数据；提醒、失败与同步状态仍然需要文字、位置和可重试动作。</p></div>
  </div>
</section>
</main>

<footer><div class="wrap"><span>River Glyph System · 80 glyphs · 24u grid · 2026</span><span>一套河流图标 · macOS / iOS 共用</span></div></footer>

<script>
const body = document.body;
const cards = [...document.querySelectorAll('.glyph-card')];
const search = document.getElementById('search');
const empty = document.getElementById('empty');
let category = '全部';

function applyFilter() {{
  const q = search.value.trim().toLowerCase();
  let n = 0;
  for (const card of cards) {{
    const ok = (category === '全部' || card.dataset.cat === category) && card.dataset.search.includes(q);
    card.hidden = !ok;
    if (ok) n++;
  }}
  empty.style.display = n ? 'none' : 'block';
}}

document.querySelectorAll('#platform button').forEach(btn => btn.onclick = () => {{
  document.querySelectorAll('#platform button').forEach(b => b.classList.toggle('is-on', b === btn));
  body.dataset.platform = btn.dataset.platform;
}});
document.querySelectorAll('#state button').forEach(btn => btn.onclick = () => {{
  document.querySelectorAll('#state button').forEach(b => b.classList.toggle('is-on', b === btn));
  body.dataset.state = btn.dataset.state;
}});
document.querySelectorAll('#cats .chip').forEach(btn => btn.onclick = () => {{
  document.querySelectorAll('#cats .chip').forEach(b => b.classList.toggle('is-on', b === btn));
  category = btn.dataset.cat;
  applyFilter();
}});
search.addEventListener('input', applyFilter);
document.getElementById('compare').onclick = function () {{
  const on = body.classList.toggle('compare');
  this.classList.toggle('is-on', on);
  this.setAttribute('aria-pressed', on);
}};
document.getElementById('theme').onclick = function () {{
  const dark = document.documentElement.dataset.theme !== 'dark';
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  this.textContent = dark ? '浅色' : '深色';
}};
function syncLinks() {{
  const state = body.dataset.state;
  document.querySelectorAll('.glyph-card').forEach(card => {{
    card.href = '../SVG/' + state + '/' + card.dataset.id + '.svg';
  }});
}}
const platformButtons = document.querySelectorAll('#platform button');
const stateButtons = document.querySelectorAll('#state button');
platformButtons.forEach(b => b.addEventListener('click', syncLinks));
stateButtons.forEach(b => b.addEventListener('click', syncLinks));
syncLinks();
</script>
</body>
</html>'''


if __name__ == "__main__":
    out = ROOT / "展示" / "index.html"
    out.write_text(page(), encoding="utf-8")
    print("SHOWCASE", out)
