#!/usr/bin/env python3
"""App artwork for the River Glyph System (iOS full bleed, macOS squircle)."""
from __future__ import annotations

import subprocess
from pathlib import Path

RIVER1 = "M15.12 1.92C.48 7.2 22.8 15.6 5.28 22.08"
RIVER2 = "M19.92 1.92C5.28 7.2 27.6 15.6 10.08 22.08"


def app_svg(platform: str, dark: bool = False) -> str:
    if dark:
        bg1, bg2 = "#14326E", "#071733"
        glow = "#8FB6FF"
        water = "#9DC2FF"
    else:
        bg1, bg2 = "#2F66E8", "#0E3070"
        glow = "#A9C8FF"
        water = "#D7E6FF"
    squircle = (
        '<clipPath id="plate"><path d="M824 0H200C89.5 0 0 89.5 0 200v624c0 110.5 89.5 200 200 200h624'
        'c110.5 0 200-89.5 200-200V200C1024 89.5 934.5 0 824 0Z"/></clipPath>'
    )
    body = (
        '<rect width="1024" height="1024" fill="url(#bg)"/>'
        '<rect width="1024" height="1024" fill="url(#glow)"/>'
        '<path d="M0 690C150 660 292 722 446 700S760 640 1024 682V1024H0Z" fill="url(#water)" opacity=".22"/>'
        '<path d="M0 692C150 662 292 724 446 702S760 642 1024 684" fill="none" stroke="' + water + '" stroke-width="4" stroke-opacity=".55"/>'
        '<g transform="translate(210 200) scale(26)" fill="none" stroke-linecap="round" stroke-width="2.05">'
        f'<path d="{RIVER1}" stroke="#FFFFFF"/>'
        f'<path d="{RIVER2}" stroke="{glow}"/>'
        "</g>"
    )
    if platform == "macos":
        return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2=".85" y2="1"><stop stop-color="{bg1}"/><stop offset="1" stop-color="{bg2}"/></linearGradient>
  <radialGradient id="glow" cx=".22" cy=".12" r=".9"><stop stop-color="{glow}" stop-opacity=".38"/><stop offset="1" stop-color="{glow}" stop-opacity="0"/></radialGradient>
  <linearGradient id="water" x1="0" y1="0" x2="0" y2="1"><stop stop-color="{water}" stop-opacity=".55"/><stop offset="1" stop-color="{water}" stop-opacity=".08"/></linearGradient>
  {squircle}
  <filter id="shadow" x="-25%" y="-20%" width="150%" height="155%"><feDropShadow dx="0" dy="22" stdDeviation="24" flood-color="#08152C" flood-opacity=".35"/></filter>
</defs>
<g transform="translate(72 64) scale(.859375)" filter="url(#shadow)">
  <g clip-path="url(#plate)">{body}
    <rect x="1.5" y="1.5" width="1021" height="1021" rx="200" fill="none" stroke="#FFFFFF" stroke-opacity=".18" stroke-width="3"/>
  </g>
</g>
</svg>'''
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2=".85" y2="1"><stop stop-color="{bg1}"/><stop offset="1" stop-color="{bg2}"/></linearGradient>
  <radialGradient id="glow" cx=".22" cy=".12" r=".9"><stop stop-color="{glow}" stop-opacity=".38"/><stop offset="1" stop-color="{glow}" stop-opacity="0"/></radialGradient>
  <linearGradient id="water" x1="0" y1="0" x2="0" y2="1"><stop stop-color="{water}" stop-opacity=".55"/><stop offset="1" stop-color="{water}" stop-opacity=".08"/></linearGradient>
</defs>
{body}
</svg>'''


def write_app_icons(root: Path) -> None:
    out = root / "应用图标"
    out.mkdir(exist_ok=True)
    jobs = []
    targets = [
        ("ios", False, "ios-1024"),
        ("ios", True, "ios-dark-1024"),
        ("macos", False, "macos-1024"),
    ]
    for platform, dark, name in targets:
        svg = out / f"{name}.svg"
        svg.write_text(app_svg(platform, dark), encoding="utf-8")
        jobs.append((svg, out / f"{name}.png"))
    script = (
        "const sharp=require('sharp');(async()=>{"
        "for(const [s,d] of JSON.parse(process.argv[1])){"
        "await sharp(s,{density:300}).resize(1024,1024).png().toFile(d);}"
        "console.log('APP_ICONS_DONE')})().catch(e=>{console.error(e);process.exit(1)})"
    )
    import json
    import os

    modules = Path(
        os.environ.get(
            "RIVER_ICON_NODE_MODULES",
            str(Path.home() / ".cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules"),
        )
    )
    env = dict(os.environ, NODE_PATH=str(modules))
    from runtime import node, node_env
    subprocess.run(
        [node(), "-e", script, json.dumps([[str(a), str(b)] for a, b in jobs])],
        check=True,
        env=node_env(),
        cwd=str(root),
    )
    # App Store icons must be opaque; scanlines of the design preview stay RGBA.
    from PIL import Image

    for png in (out / "ios-1024.png", out / "ios-dark-1024.png"):
        Image.open(png).convert("RGB").save(png)


def write_macos_icns(root: Path) -> None:
    from PIL import Image

    out = root / "应用图标"
    master = Image.open(out / "macos-1024.png").convert("RGBA")
    iconset = out / "RiverGlyph.iconset"
    iconset.mkdir(exist_ok=True)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            master.resize((size * scale, size * scale), Image.Resampling.LANCZOS).save(
                iconset / f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            )
    subprocess.run(["/usr/bin/iconutil", "-c", "icns", str(iconset), "-o", str(out / "RiverGlyph.icns")], check=True)
