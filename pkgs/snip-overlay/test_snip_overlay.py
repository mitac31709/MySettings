#!/usr/bin/env python3
"""Unit tests for snip_core geometry, hit-testing, and Cairo cropping."""

from __future__ import annotations

import unittest

import cairo

from snip_core import (
    MonitorInfo,
    crop_freeform_surface,
    crop_rect_surface,
    hit_test_window,
    logical_rect_to_pixel_rect,
    normalize_rect,
    parse_monitors,
    windows_for_monitor,
)


class SnipCoreTests(unittest.TestCase):
    def test_parse_monitors_and_logical_size(self) -> None:
        raw = [
            {
                "name": "eDP-1",
                "x": 0,
                "y": 0,
                "width": 1920,
                "height": 1080,
                "scale": 1.25,
                "transform": 0,
                "focused": True,
                "activeWorkspace": {"id": 2},
            },
            {
                "name": "HDMI-A-1",
                "x": 1536,
                "y": 0,
                "width": 1920,
                "height": 1080,
                "scale": 1.0,
                "transform": 1,
                "focused": False,
                "activeWorkspace": {"id": 5},
            },
            {
                "name": "DP-2",
                "disabled": True,
                "width": 1920,
                "height": 1080,
                "scale": 1.0,
            },
        ]
        mons = parse_monitors(raw)
        self.assertEqual(len(mons), 2)
        self.assertEqual(mons[0].logical_size(), (1536.0, 864.0))
        self.assertEqual(mons[1].logical_size(), (1080.0, 1920.0))

    def test_windows_for_monitor_zorder_and_hit_test(self) -> None:
        mon = MonitorInfo(
            name="eDP-1",
            x=100,
            y=0,
            width=1000,
            height=800,
            scale=1.0,
            transform=0,
            focused=True,
            active_workspace_id=1,
        )
        clients = [
            {
                "address": "0x1",
                "title": "Tiled",
                "class": "term",
                "mapped": True,
                "hidden": False,
                "workspace": {"id": 1},
                "at": [100, 0],
                "size": [1000, 800],
                "floating": False,
                "focusHistoryID": 0,
            },
            {
                "address": "0x2",
                "title": "FloatingBack",
                "class": "dialog",
                "mapped": True,
                "hidden": False,
                "workspace": {"id": 1},
                "at": [200, 100],
                "size": [300, 200],
                "floating": True,
                "focusHistoryID": 2,
            },
            {
                "address": "0x3",
                "title": "FloatingFront",
                "class": "popup",
                "mapped": True,
                "hidden": False,
                "workspace": {"id": 1},
                "at": [250, 150],
                "size": [200, 100],
                "floating": True,
                "focusHistoryID": 1,
            },
            {
                "address": "0x4",
                "title": "OtherWS",
                "class": "other",
                "mapped": True,
                "hidden": False,
                "workspace": {"id": 2},
                "at": [100, 0],
                "size": [500, 500],
                "floating": False,
                "focusHistoryID": 0,
            },
        ]
        wins = windows_for_monitor(clients, mon)
        self.assertEqual([w.address for w in wins], ["0x3", "0x2", "0x1"])

        # Inside FloatingFront (local x: 150..350, y: 150..250)
        hit = hit_test_window(wins, 200.0, 200.0)
        self.assertIsNotNone(hit)
        assert hit is not None
        self.assertEqual(hit.address, "0x3")

        # Inside FloatingBack only (local x: 100..400, y: 100..300)
        hit2 = hit_test_window(wins, 120.0, 120.0)
        self.assertIsNotNone(hit2)
        assert hit2 is not None
        self.assertEqual(hit2.address, "0x2")

        # Inside Tiled only
        hit3 = hit_test_window(wins, 50.0, 50.0)
        self.assertIsNotNone(hit3)
        assert hit3 is not None
        self.assertEqual(hit3.address, "0x1")

    def test_logical_to_pixel_and_crop_rect(self) -> None:
        x, y, w, h = normalize_rect(80.0, 60.0, 20.0, 10.0)
        self.assertEqual((x, y, w, h), (20.0, 10.0, 60.0, 50.0))

        px, py, pw, ph = logical_rect_to_pixel_rect(20.0, 10.0, 60.0, 50.0, 100.0, 100.0, 200, 200)
        self.assertEqual((px, py, pw, ph), (40, 20, 120, 100))

        src = cairo.ImageSurface(cairo.FORMAT_ARGB32, 200, 200)
        cr = cairo.Context(src)
        cr.set_source_rgba(0.2, 0.4, 0.8, 1.0)
        cr.paint()

        cropped = crop_rect_surface(src, px, py, pw, ph)
        self.assertEqual(cropped.get_width(), 120)
        self.assertEqual(cropped.get_height(), 100)

    def test_crop_freeform_transparency(self) -> None:
        src = cairo.ImageSurface(cairo.FORMAT_ARGB32, 100, 100)
        cr = cairo.Context(src)
        cr.set_source_rgba(1.0, 0.0, 0.0, 1.0)
        cr.paint()

        # Triangle inside (10,10)-(90,10)-(90,90)
        out = crop_freeform_surface(src, [(10.0, 10.0), (90.0, 10.0), (90.0, 90.0)], 100.0, 100.0)
        self.assertIsNotNone(out)
        assert out is not None
        self.assertEqual(out.get_width(), 80)
        self.assertEqual(out.get_height(), 80)

        data = bytes(out.get_data())
        stride = out.get_stride()
        # Bottom-left corner (x=2, y=77) is outside the triangle -> alpha == 0
        alpha_outside = data[77 * stride + 2 * 4 + 3]
        self.assertEqual(alpha_outside, 0)
        # Top-right interior (x=70, y=10) is inside the triangle -> alpha == 255
        alpha_inside = data[10 * stride + 70 * 4 + 3]
        self.assertEqual(alpha_inside, 255)


if __name__ == "__main__":
    unittest.main()
