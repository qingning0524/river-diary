#!/usr/bin/env python3
"""River Glyph: shared water-mouth geometry and state rendering for both platforms."""
from __future__ import annotations

import html
import math
from dataclasses import dataclass, field
from typing import Iterable

TAU = math.pi * 2

PALETTES = {
    "light": {"ink": "#2B3B52", "accent": "#2F6CF5", "water": "#2F6CF5", "canvas": "#F4F7FB"},
    "dark": {"ink": "#E0E8F4", "accent": "#92B4FF", "water": "#92B4FF", "canvas": "#202935"},
    "selected": {"ink": "#2F6CF5", "accent": "#2F6CF5", "water": "#2F6CF5", "canvas": "#EAF0FF"},
    "selected-dark": {"ink": "#A2BFFF", "accent": "#A2BFFF", "water": "#A2BFFF", "canvas": "#293E63"},
}
WEIGHTS = {"current": 1.75, "ripple": 1.25}

LIVE = 20.0


def _n(v: float) -> str:
    """Compact, stable number formatting."""
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return s or "0"


def _pt(cx: float, cy: float, r: float, deg: float) -> tuple[float, float]:
    a = math.radians(deg)
    return cx + r * math.cos(a), cy + r * math.sin(a)


def _arc(cx: float, cy: float, r: float, start: float, end: float, sweep: int = 1) -> str:
    x1, y1 = _pt(cx, cy, r, start)
    x2, y2 = _pt(cx, cy, r, end)
    large = 1 if abs(end - start) > 180 else 0
    return f"A{_n(r)} {_n(r)} 0 {large} {sweep} {_n(x2)} {_n(y2)}"


# ---------------------------------------------------------------- primitives


@dataclass
class Part:
    """One drawable. Weight is semantic, not numeric."""

    d: str
    weight: str = "current"
    accent: bool = False
    opacity: float = 1.0
    # filled shapes (dots, selected containers) use fill=true
    fill: bool = False
    selected_only: bool = False


@dataclass
class Water:
    """Water level inside a container, in container-local coordinates."""

    x: float
    y: float
    w: float
    h: float
    r: float = 2.4
    rise: float = 0.8  # downstream tilt


@dataclass
class Glyph:
    id: str
    label: str
    category: str
    parts: list[Part] = field(default_factory=list)
    water: Water | None = None
    mouth: tuple[float, float, float, float] | None = None  # rect for mouth dot placement
    nav: bool = False  # primary navigation glyph: gets the source dot


def circle_open(cx: float, cy: float, r: float, *, gap: float = 22.0, start: float = 34.0) -> str:
    gap = max(gap, math.degrees(2 * math.asin(min(1, 4.1 / (2 * r)))))
    a, b = start, start + gap
    x1, y1 = _pt(cx, cy, r, b)
    return f"M{_n(x1)} {_n(y1)}{_arc(cx, cy, r, b, a + 360)}"


def rect_open(x: float, y: float, w: float, h: float, r: float, *, mouth_from: float = 0.60,
              mouth_w: float = 2.9) -> str:
    """Rounded rect with a river mouth cut out of the bottom edge (right of centre)."""
    x1, y1, x2, y2 = x, y, x + w, y + h
    # Keep a 3.8u slot: even the 1.95u selected stroke leaves a visible opening.
    gap = max(3.8, mouth_w)
    right = x2 - r - 0.25
    left = x1 + r + 0.25
    if right - left < gap:
        raise ValueError("Container too narrow for the shared river mouth")
    mx2 = min(x + w * mouth_from + gap, right)
    mx1 = mx2 - gap
    return (
        f"M{_n(mx2)} {_n(y2)}"
        f"L{_n(x2 - r)} {_n(y2)}"
        f"A{_n(r)} {_n(r)} 0 0 0 {_n(x2)} {_n(y2 - r)}"
        f"L{_n(x2)} {_n(y1 + r)}"
        f"A{_n(r)} {_n(r)} 0 0 0 {_n(x2 - r)} {_n(y1)}"
        f"L{_n(x1 + r)} {_n(y1)}"
        f"A{_n(r)} {_n(r)} 0 0 0 {_n(x1)} {_n(y1 + r)}"
        f"L{_n(x1)} {_n(y2 - r)}"
        f"A{_n(r)} {_n(r)} 0 0 0 {_n(x1 + r)} {_n(y2)}"
        f"L{_n(mx1)} {_n(y2)}"
    )


def rect_closed(x: float, y: float, w: float, h: float, r: float) -> str:
    return (
        f"M{_n(x + r)} {_n(y)}L{_n(x + w - r)} {_n(y)}"
        f"A{_n(r)} {_n(r)} 0 0 1 {_n(x + w)} {_n(y + r)}"
        f"L{_n(x + w)} {_n(y + h - r)}"
        f"A{_n(r)} {_n(r)} 0 0 1 {_n(x + w - r)} {_n(y + h)}"
        f"L{_n(x + r)} {_n(y + h)}"
        f"A{_n(r)} {_n(r)} 0 0 1 {_n(x)} {_n(y + h - r)}"
        f"L{_n(x)} {_n(y + r)}"
        f"A{_n(r)} {_n(r)} 0 0 1 {_n(x + r)} {_n(y)}Z"
    )


# ---------------------------------------------------------------- rendering


def _color(variant: str, kind: str) -> str:
    palette = PALETTES[variant]
    return palette.get(kind, palette["ink"])


def _curve(ix, iw, left_y, right_y, *, offset=False):
    """Water surface: a shallow downstream rise, always higher on the right."""
    dy = 0.15 if offset else 0.0
    return (
        f"M{_n(ix)} {_n(left_y)}"
        f"C{_n(ix + iw * 0.33)} {_n(left_y - dy)} {_n(ix + iw * 0.62)} {_n(right_y + dy)} {_n(ix + iw)} {_n(right_y)}"
    )


def water_svg(variant: str, water: Water, clip_id: str) -> str:
    """Shared tinted pool and surface line for both platforms."""
    x, y, w, h, r = water.x, water.y, water.w, water.h, water.r
    # inner shelf keeps the pool off the contour
    inset = 1.15
    ix, iy, iw, ih = x + inset, y + inset, w - inset * 2, h - inset * 2
    ir = max(1.2, r - inset)
    level_ratio = 0.60
    if variant in ("selected", "selected-dark"):
        level_ratio = 0.46
    level = iy + ih * level_ratio
    rise = water.rise
    left_y = level + rise / 2
    right_y = level - rise / 2
    line = _curve(ix, iw, left_y, right_y)
    clip = (
        f'<clipPath id="{clip_id}"><path d="{rect_closed(ix, iy, iw, ih, ir)}"/></clipPath>'
    )
    water_color = _color(variant, "water")
    fill_opacity = 0.18 if variant in ("light", "dark") else 0.26
    stroke_opacity = 0.72 if variant in ("light", "dark") else 0.95
    band = (
        f'<path d="{line}L{_n(ix + iw)} {_n(iy + ih)}L{_n(ix)} {_n(iy + ih)}Z"'
        f' fill="{water_color}" fill-opacity="{fill_opacity}" clip-path="url(#{clip_id})"/>'
    )
    surface = (
        f'<path d="{line}" fill="none" stroke="{water_color}" stroke-opacity="{stroke_opacity}" '
        f'stroke-width="1.15" stroke-linecap="round" clip-path="url(#{clip_id})"/>'
    )
    return f"<defs>{clip}</defs>{band}{surface}"


def render_svg(glyph: Glyph, variant: str, size: float = 24) -> str:
    ink = _color(variant, "ink")
    accent = _color(variant, "accent")
    weights = WEIGHTS
    selected = variant in ("selected", "selected-dark")
    clip_id = f"clip-{glyph.id}"
    body: list[str] = []
    water = water_svg(variant, glyph.water, clip_id) if glyph.water else ""
    for part in glyph.parts:
        if part.selected_only and not selected:
            continue
        color = accent if part.accent else ink
        opacity = part.opacity
        width = weights[part.weight]
        if selected:
            # Selection carries a little more water: every stroke gains 0.2u,
            # including accent-only glyphs (add / play / refresh).
            width += 0.2
        if part.fill:
            body.append(
                f'<path d="{part.d}" fill="{color}" fill-opacity="{_n(opacity)}" stroke="none"/>'
            )
        else:
            attrs = f'stroke="{color}" stroke-width="{_n(width)}"'
            if opacity != 1.0:
                attrs += f' stroke-opacity="{_n(opacity)}"'
            body.append(
                f'<path d="{part.d}" fill="none" {attrs} stroke-linecap="round" stroke-linejoin="round"/>'
            )
    content = f"{water}{''.join(body)}"
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{_n(size)}" height="{_n(size)}" '
        f'viewBox="0 0 24 24" fill="none" color="{ink}" role="img" aria-label="{html.escape(glyph.label)}">'
        f"<title>{html.escape(glyph.label)}</title>{content}</svg>"
    )


# ---------------------------------------------------------------- helpers for authoring


def line(x1: float, y1: float, x2: float, y2: float, weight: str = "ripple", **kw) -> Part:
    return Part(f"M{_n(x1)} {_n(y1)}L{_n(x2)} {_n(y2)}", weight, **kw)


def poly(d: str, weight: str = "current", **kw) -> Part:
    return Part(d, weight, **kw)


def dot(x: float, y: float, r: float = 1.25, weight: str = "current", **kw) -> Part:
    return Part(
        f"M{_n(x - r)} {_n(y)}a{_n(r)} {_n(r)} 0 1 0 {_n(2 * r)} 0a{_n(r)} {_n(r)} 0 1 0 {_n(-2 * r)} 0Z",
        weight,
        fill=True,
        **kw,
    )


def container(x: float, y: float, w: float, h: float, r: float, *, mouth: bool = True,
              water: bool = True) -> tuple[list[Part], Water | None]:
    parts = [Part(rect_open(x, y, w, h, r) if mouth else rect_closed(x, y, w, h, r))]
    wat = Water(x, y, w, h, r) if water else None
    return parts, wat


def rr(x: float, y: float, w: float, h: float, r: float = 2.0) -> str:
    return rect_closed(x, y, w, h, r)


def cir(cx: float, cy: float, r: float) -> str:
    """Full ring drawn as two half arcs (a single 359.999-degree arc collapses in some renderers)."""
    return (f"M{_n(cx - r)} {_n(cy)}"
            f"A{_n(r)} {_n(r)} 0 1 0 {_n(cx + r)} {_n(cy)}"
            f"A{_n(r)} {_n(r)} 0 1 0 {_n(cx - r)} {_n(cy)}")
