#!/usr/bin/env python3
"""Pure logic for snip-overlay: monitor/window geometry, hit-testing, and Cairo cropping."""

from __future__ import annotations

from dataclasses import dataclass
import math
from typing import Iterable

import cairo


@dataclass(frozen=True)
class MonitorInfo:
    name: str
    x: int
    y: int
    width: int
    height: int
    scale: float
    transform: int
    focused: bool
    active_workspace_id: int

    def logical_size(self) -> tuple[float, float]:
        scale = self.scale if self.scale > 0 else 1.0
        if self.transform % 2 == 1:
            return (self.height / scale, self.width / scale)
        return (self.width / scale, self.height / scale)


@dataclass(frozen=True)
class WindowRect:
    address: str
    title: str
    class_name: str
    x: float
    y: float
    w: float
    h: float
    floating: bool
    focus_history_id: int


def parse_monitors(raw: Iterable[dict]) -> list[MonitorInfo]:
    monitors: list[MonitorInfo] = []
    for item in raw:
        if item.get("disabled", False):
            continue
        ws = item.get("activeWorkspace") or {}
        monitors.append(
            MonitorInfo(
                name=str(item.get("name", "")),
                x=int(item.get("x", 0)),
                y=int(item.get("y", 0)),
                width=int(item.get("width", 0)),
                height=int(item.get("height", 0)),
                scale=float(item.get("scale", 1.0) or 1.0),
                transform=int(item.get("transform", 0) or 0),
                focused=bool(item.get("focused", False)),
                active_workspace_id=int(ws.get("id", -1)),
            )
        )
    return monitors


def windows_for_monitor(clients_raw: Iterable[dict], mon: MonitorInfo) -> list[WindowRect]:
    mon_lw, mon_lh = mon.logical_size()
    result: list[WindowRect] = []
    for c in clients_raw:
        if not c.get("mapped", False) or c.get("hidden", False):
            continue
        ws = c.get("workspace") or {}
        ws_id = int(ws.get("id", -999999))
        pinned = bool(c.get("pinned", False))
        if not pinned and ws_id != mon.active_workspace_id:
            continue

        at = c.get("at") or [0, 0]
        size = c.get("size") or [0, 0]
        if len(at) < 2 or len(size) < 2:
            continue

        lx1 = float(at[0]) - mon.x
        ly1 = float(at[1]) - mon.y
        lx2 = lx1 + float(size[0])
        ly2 = ly1 + float(size[1])

        # Clip to monitor logical bounds
        cx1 = max(0.0, min(mon_lw, lx1))
        cy1 = max(0.0, min(mon_lh, ly1))
        cx2 = max(0.0, min(mon_lw, lx2))
        cy2 = max(0.0, min(mon_lh, ly2))
        cw = cx2 - cx1
        ch = cy2 - cy1
        if cw < 2.0 or ch < 2.0:
            continue

        result.append(
            WindowRect(
                address=str(c.get("address", "")),
                title=str(c.get("title", "")),
                class_name=str(c.get("class", "")),
                x=cx1,
                y=cy1,
                w=cw,
                h=ch,
                floating=bool(c.get("floating", False)),
                focus_history_id=int(c.get("focusHistoryID", 999999)),
            )
        )

    # Top-most first: floating windows above tiled, then most recently focused.
    result.sort(key=lambda w: (0 if w.floating else 1, w.focus_history_id))
    return result


def hit_test_window(windows: Iterable[WindowRect], x: float, y: float) -> WindowRect | None:
    for win in windows:
        if win.x <= x <= (win.x + win.w) and win.y <= y <= (win.y + win.h):
            return win
    return None


def normalize_rect(x1: float, y1: float, x2: float, y2: float) -> tuple[float, float, float, float]:
    left = min(x1, x2)
    top = min(y1, y2)
    return (left, top, abs(x2 - x1), abs(y2 - y1))


def logical_rect_to_pixel_rect(
    lx: float,
    ly: float,
    lw: float,
    lh: float,
    alloc_w: float,
    alloc_h: float,
    img_w: int,
    img_h: int,
) -> tuple[int, int, int, int]:
    if alloc_w <= 0 or alloc_h <= 0 or img_w <= 0 or img_h <= 0:
        return (0, 0, max(1, img_w), max(1, img_h))

    sx = img_w / alloc_w
    sy = img_h / alloc_h

    px1 = max(0, min(img_w - 1, int(math.floor(lx * sx))))
    py1 = max(0, min(img_h - 1, int(math.floor(ly * sy))))
    px2 = max(px1 + 1, min(img_w, int(math.ceil((lx + lw) * sx))))
    py2 = max(py1 + 1, min(img_h, int(math.ceil((ly + lh) * sy))))
    return (px1, py1, px2 - px1, py2 - py1)


def crop_rect_surface(
    src: cairo.ImageSurface,
    px: int,
    py: int,
    pw: int,
    ph: int,
) -> cairo.ImageSurface:
    out = cairo.ImageSurface(cairo.FORMAT_ARGB32, max(1, pw), max(1, ph))
    cr = cairo.Context(out)
    cr.set_operator(cairo.OPERATOR_SOURCE)
    cr.set_source_surface(src, -px, -py)
    cr.paint()
    return out


def crop_freeform_surface(
    src: cairo.ImageSurface,
    points: list[tuple[float, float]],
    alloc_w: float,
    alloc_h: float,
) -> cairo.ImageSurface | None:
    if len(points) < 3 or alloc_w <= 0 or alloc_h <= 0:
        return None

    img_w = src.get_width()
    img_h = src.get_height()
    sx = img_w / alloc_w
    sy = img_h / alloc_h

    px_pts = [
        (max(0.0, min(float(img_w), x * sx)), max(0.0, min(float(img_h), y * sy)))
        for x, y in points
    ]
    xs = [p[0] for p in px_pts]
    ys = [p[1] for p in px_pts]

    min_x = max(0, int(math.floor(min(xs))))
    min_y = max(0, int(math.floor(min(ys))))
    max_x = min(img_w, int(math.ceil(max(xs))))
    max_y = min(img_h, int(math.ceil(max(ys))))
    bw = max_x - min_x
    bh = max_y - min_y
    if bw < 2 or bh < 2:
        return None

    out = cairo.ImageSurface(cairo.FORMAT_ARGB32, bw, bh)
    cr = cairo.Context(out)
    cr.set_antialias(cairo.ANTIALIAS_BEST)

    cr.move_to(px_pts[0][0] - min_x, px_pts[0][1] - min_y)
    for px, py in px_pts[1:]:
        cr.line_to(px - min_x, py - min_y)
    cr.close_path()
    cr.clip()

    cr.set_source_surface(src, -min_x, -min_y)
    cr.paint()
    return out
