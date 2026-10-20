#!/usr/bin/env python3
"""Build the web icon sprite from the shared River Glyph v2 source.

The native apps and this console use the same 24u geometry.  We only replace the
two source colours with CSS-friendly values:

    #2B3B52  -> currentColor
    #2F6CF5  -> var(--glyph-accent, currentColor)

Run from the repository root:

    python3 website/user/tools/build_glyphs.py

The generated file is committed so the static console keeps working without a
build step.  Do not hand-edit assets/glyphs.svg.
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

INK = "#2B3B52"
ACCENT = "#2F6CF5"
ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "图标素材库" / "SVG" / "light"
DEFAULT_OUT = ROOT / "website" / "user" / "assets" / "glyphs.svg"
INDEX = ROOT / "website" / "user" / "index.html"
START = "<!-- river-glyphs:start -->"
END = "<!-- river-glyphs:end -->"


def clean(svg: str, name: str) -> str:
    svg = re.sub(r"<svg[^>]*>", "", svg, count=1)
    svg = svg.replace("</svg>", "")
    svg = re.sub(r"<title>.*?</title>", "", svg, flags=re.S)
    svg = svg.replace(INK, "currentColor").replace(ACCENT, "var(--glyph-accent, currentColor)")
    svg = re.sub(r"\s+", " ", svg).strip()
    return f'<symbol id="i-{name}" viewBox="0 0 24 24">{svg}</symbol>'


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()

    files = sorted(args.source.glob("*.svg"))
    if not files:
        raise SystemExit(f"no source icons under {args.source}")

    symbols = []
    for path in files:
        symbols.append(clean(path.read_text(encoding="utf-8"), path.stem))

    out = (
        '<svg xmlns="http://www.w3.org/2000/svg" aria-hidden="true" '
        'class="river-glyph-sprite">\n'
        + "\n".join(symbols)
        + "\n</svg>\n"
    )
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(out, encoding="utf-8")
    print(f"wrote {len(symbols)} glyphs -> {args.out.relative_to(ROOT)}")

    # Inline the same symbols into the static shell.  Keeping the sprite in the
    # document avoids cross-document <use> differences in Safari and removes one
    # request; the standalone file remains the reviewable source artifact.
    if INDEX.exists():
        html = INDEX.read_text(encoding="utf-8")
        if START in html and END in html:
            before, rest = html.split(START, 1)
            _, after = rest.split(END, 1)
            inline = (
                f"{START}\n<svg xmlns=\"http://www.w3.org/2000/svg\" class=\"glyph-sprite\" "
                "aria-hidden=\"true\" focusable=\"false\">\n"
                + "\n".join(symbols)
                + f"\n</svg>\n{END}"
            )
            INDEX.write_text(before + inline + after, encoding="utf-8")
            print(f"inlined {len(symbols)} glyphs -> website/user/index.html")
        else:
            print("warning: index.html is missing river-glyphs markers")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
