#!/usr/bin/env python3
"""Build a daily campus AP load graph and post it to Discord.

Usage:
  campus-apload-report.py [--test] [--force] [--final] [YYYY-MM-DD]

Reads /etc/freeap-notify.env (WEBHOOK) but never prints the URL.
Does not touch the freeap daily-message edit logic; always posts a new message.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import pathlib
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.dates as mdates
import matplotlib.font_manager as fm
import matplotlib.pyplot as plt
import requests
from matplotlib import rcParams
from matplotlib.ticker import MaxNLocator

JST = dt.timezone(dt.timedelta(hours=9))
DATA_DIR = pathlib.Path("/var/lib/campus-apload")
GRAPH_DIR = DATA_DIR / "graphs"
STATE_DIR = DATA_DIR / "state"
ENV_PATH = pathlib.Path("/etc/freeap-notify.env")
FONT_CANDIDATES = [
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf",
]
CLASS_START = dt.time(8, 50)
CLASS_END = dt.time(16, 0)

SERIES = [
    ("aptr_5g", "AP-tr 5GHz", "#1f4e79", "o"),
    ("aptr_24g", "AP-tr 2.4GHz", "#5b9bd5", "s"),
    ("eduroam_5g", "eduroam 5GHz", "#c45911", "o"),
    ("eduroam_24g", "eduroam 2.4GHz", "#ed7d31", "s"),
    ("hidden_5g", "隠しSSID 5GHz", "#7f7f7f", "^"),
    ("hidden_24g", "隠しSSID 2.4GHz", "#b0b0b0", "^"),
]


def now_jst() -> dt.datetime:
    return dt.datetime.now(JST).replace(microsecond=0)


def setup_font():
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            fm.fontManager.addfont(path)
            prop = fm.FontProperties(fname=path)
            name = prop.get_name()
            rcParams["font.family"] = name
            rcParams["axes.unicode_minus"] = False
            return prop
    rcParams["axes.unicode_minus"] = False
    return None


def load_webhook() -> str:
    if not ENV_PATH.exists():
        raise RuntimeError(f"{ENV_PATH} is missing")
    for line in ENV_PATH.read_text().splitlines():
        if line.startswith("WEBHOOK="):
            url = line.split("=", 1)[1].strip().strip('"').strip("'")
            if url:
                return url
    raise RuntimeError("WEBHOOK is not set")


def parse_ts(s: str) -> dt.datetime:
    return dt.datetime.strptime(s.strip(), "%Y-%m-%d %H:%M:%S").replace(tzinfo=JST)


def read_nearest(day: str) -> list[dict]:
    path = DATA_DIR / f"{day}-nearest.csv"
    if not path.exists():
        raise FileNotFoundError(f"データがありません: {path}")
    rows = []
    with path.open(newline="") as f:
        for r in csv.DictReader(f):
            try:
                r["_ts"] = parse_ts(r["timestamp"])
            except (KeyError, ValueError):
                continue
            rows.append(r)
    rows.sort(key=lambda r: r["_ts"])
    return rows


def to_int(v, default=0):
    try:
        if v is None or v == "":
            return default
        return int(v)
    except ValueError:
        return default


def to_opt_int(v):
    try:
        if v is None or v == "":
            return None
        return int(v)
    except ValueError:
        return None


def util_pct(v):
    n = to_opt_int(v)
    if n is None:
        return None
    return n * 100.0 / 255.0


def pick_ap_group(rows: list[dict]) -> str:
    counts: dict[str, int] = {}
    for r in rows:
        g = r.get("ap_group") or ""
        if g:
            counts[g] = counts.get(g, 0) + 1
    if not counts:
        return ""
    return max(counts, key=counts.get)


def summary_text(day: str, rows: list[dict], group: str, test: bool) -> str:
    xs = [r["_ts"] for r in rows]
    totals = [to_int(r.get("total_ex_self"), to_int(r.get("total"))) for r in rows]
    max_total = max(totals) if totals else 0
    max_at = xs[totals.index(max_total)] if totals else None
    class_rows = [r for r in rows if CLASS_START <= r["_ts"].time() <= CLASS_END]
    if class_rows:
        class_avg = sum(to_int(r.get("total_ex_self"), to_int(r.get("total"))) for r in class_rows) / len(class_rows)
        class_s = f"{class_avg:.1f}台（{len(class_rows)}サンプル）"
    else:
        class_s = "記録なし"

    last = rows[-1]
    def n(k):
        return to_int(last.get(k))

    last_bits = [
        f"AP-tr 5GHz {n('aptr_5g')}台",
        f"eduroam 5GHz {n('eduroam_5g')}台",
        f"AP-tr 2.4GHz {n('aptr_24g')}台",
        f"eduroam 2.4GHz {n('eduroam_24g')}台",
    ]
    if n("hidden_5g") or n("hidden_24g"):
        last_bits.append(f"隠し {n('hidden_5g')+n('hidden_24g')}台")
    u5 = util_pct(last.get("util_5g"))
    u24 = util_pct(last.get("util_24g"))
    util_s = "、".join(
        x
        for x in [
            f"5GHz {u5:.0f}%" if u5 is not None else "",
            f"2.4GHz {u24:.0f}%" if u24 is not None else "",
        ]
        if x
    )
    max_s = f"{max_total}台（{max_at.strftime('%H:%M')}）" if max_at else "—"
    prefix = "【テスト】" if test else ""
    self_note = ""
    if any(r.get("self_bssid") for r in rows):
        self_note = "\n※台数はPi自身の接続を除いた値です。"
    lines = [
        f"{prefix}キャンパス最寄りAPの接続台数（{day}）",
        f"最寄りAP: {group or '不明'}",
        f"最大合計: {max_s}",
        f"授業時間帯（08:50–16:00）の平均: {class_s}",
        f"最終サンプル（{last['_ts'].strftime('%H:%M')}）: {' / '.join(last_bits)}",
        f"チャネル利用率: {util_s or '—'}",
        f"サンプル数: {len(rows)}（5分間隔）{self_note}",
    ]
    return "\n".join(lines)


def render(day: str, rows: list[dict], group: str, test: bool, out: pathlib.Path, font) -> None:
    day_start = dt.datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=JST)
    day_end = day_start + dt.timedelta(days=1)
    xs = [r["_ts"] for r in rows]

    fig, (ax1, ax2) = plt.subplots(
        2,
        1,
        sharex=True,
        figsize=(11.5, 8.2),
        gridspec_kw={"height_ratios": [3, 2], "hspace": 0.08},
        constrained_layout=True,
    )
    fp = font

    def set_font(obj):
        if fp:
            try:
                obj.set_fontproperties(fp)
            except Exception:
                pass

    title = f"キャンパス最寄りAPの接続台数（{day} / {group or '不明'}）"
    if test:
        title = "【テスト】" + title
    ax1.set_title(title, fontsize=14, pad=10)
    set_font(ax1.title)

    used_hidden = any(to_int(r.get("hidden_5g")) or to_int(r.get("hidden_24g")) for r in rows)
    for key, label, color, marker in SERIES:
        if key.startswith("hidden") and not used_hidden:
            continue
        ys = [to_int(r.get(key)) for r in rows]
        ax1.plot(xs, ys, label=label, color=color, marker=marker, markersize=4, linewidth=1.8)

    totals = [to_int(r.get("total_ex_self"), to_int(r.get("total"))) for r in rows]
    ax1.plot(xs, totals, label="合計（Pi自身を除く）", color="#222222", marker="D", markersize=4.5, linewidth=2.2, zorder=5)

    ax1.set_ylabel("接続台数（台）")
    set_font(ax1.yaxis.label)
    ax1.grid(True, linestyle="--", alpha=0.4)
    ax1.set_ylim(bottom=0)
    ymax = max(totals + [0])
    ax1.set_ylim(0, max(5, ymax + 1))
    ax1.yaxis.set_major_locator(MaxNLocator(integer=True))
    leg = ax1.legend(loc="upper left", framealpha=0.92, fontsize=9)
    if fp:
        for t in leg.get_texts():
            t.set_fontproperties(fp)

    # class hours shading
    c0 = day_start.replace(hour=CLASS_START.hour, minute=CLASS_START.minute)
    c1 = day_start.replace(hour=CLASS_END.hour, minute=CLASS_END.minute)
    ax1.axvspan(c0, c1, color="#fff3bf", alpha=0.45, zorder=0)
    ax2.axvspan(c0, c1, color="#fff3bf", alpha=0.45, zorder=0)

    u5 = [util_pct(r.get("util_5g")) for r in rows]
    u24 = [util_pct(r.get("util_24g")) for r in rows]
    if any(v is not None for v in u5):
        ax2.plot(xs, [v if v is not None else float("nan") for v in u5], label="5GHz 利用率", color="#1f4e79", marker="o", markersize=4, linewidth=1.8)
    if any(v is not None for v in u24):
        ax2.plot(xs, [v if v is not None else float("nan") for v in u24], label="2.4GHz 利用率", color="#ed7d31", marker="s", markersize=4, linewidth=1.8)
    ax2.set_ylabel("チャネル利用率（%）")
    ax2.set_xlabel("時刻（JST）")
    set_font(ax2.yaxis.label)
    set_font(ax2.xaxis.label)
    ax2.set_ylim(0, 100)
    ax2.grid(True, linestyle="--", alpha=0.4)
    leg2 = ax2.legend(loc="upper left", framealpha=0.92, fontsize=9)
    if fp:
        for t in leg2.get_texts():
            t.set_fontproperties(fp)

    ax2.set_xlim(day_start, day_end)
    ax2.xaxis.set_major_locator(mdates.HourLocator(interval=2))
    ax2.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M", tz=JST))

    # summary box
    max_total = max(totals) if totals else 0
    max_at = xs[totals.index(max_total)] if totals else None
    class_rows = [r for r in rows if CLASS_START <= r["_ts"].time() <= CLASS_END]
    if class_rows:
        avg = sum(to_int(r.get("total_ex_self"), to_int(r.get("total"))) for r in class_rows) / len(class_rows)
        class_s = f"{avg:.1f}台"
    else:
        class_s = "記録なし"
    box = (
        f"最大合計: {max_total}台"
        + (f"（{max_at.strftime('%H:%M')}）" if max_at else "")
        + f"\n授業時間帯平均: {class_s}"
        + f"\nサンプル: {len(rows)}件 / 5分間隔"
        + "\n黄帯は授業時間帯（08:50–16:00）"
        + "\n台数はPi自身を除く"
    )
    ax1.text(
        0.02,
        0.03,
        box,
        transform=ax1.transAxes,
        ha="left",
        va="bottom",
        fontsize=9,
        fontproperties=fp,
        bbox=dict(boxstyle="round,pad=0.4", facecolor="white", edgecolor="#cccccc", alpha=0.92),
        zorder=6,
    )

    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, dpi=120, bbox_inches="tight")
    plt.close(fig)


def already_sent(day: str, kind: str = "sent") -> bool:
    return (STATE_DIR / f"{kind}-{day}").exists()


def mark_sent(day: str, kind: str = "sent") -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    (STATE_DIR / f"{kind}-{day}").write_text(now_jst().isoformat() + "\n")


def post_discord(content: str, png: pathlib.Path) -> None:
    url = load_webhook()
    with png.open("rb") as f:
        data = {"payload_json": json.dumps({"content": content}, ensure_ascii=False)}
        files = {"files[0]": (png.name, f, "image/png")}
        r = requests.post(url, data=data, files=files, timeout=30)
    if r.status_code >= 400:
        raise RuntimeError(f"Discord post failed: HTTP {r.status_code}")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Daily campus AP load graph → Discord")
    p.add_argument("date", nargs="?", help="YYYY-MM-DD (default: today JST)")
    p.add_argument("--test", action="store_true", help="Label the message as a test")
    p.add_argument("--force", action="store_true", help="Post even if already sent today")
    p.add_argument("--no-post", action="store_true", help="Only render the PNG")
    p.add_argument("--final", action="store_true", help="Post the full-day (00-24) graph of the previous day (for the 00:00 run)")
    args = p.parse_args(argv)

    kind = "final" if args.final else "sent"
    if args.final and not args.date:
        day = (now_jst() - dt.timedelta(minutes=30)).strftime("%Y-%m-%d")
    else:
        day = args.date or now_jst().strftime("%Y-%m-%d")
    dt.datetime.strptime(day, "%Y-%m-%d")  # validate

    if not args.test and not args.force and not args.no_post and already_sent(day, kind):
        print(f"{day}: already sent; skip (use --force to post again)")
        return 0

    rows = read_nearest(day)
    if not rows:
        raise RuntimeError(f"{day}: nearest CSV has no usable rows")
    group = pick_ap_group(rows)
    if group:
        rows_g = [r for r in rows if r.get("ap_group") == group]
        if rows_g:
            rows = rows_g

    font = setup_font()
    png = GRAPH_DIR / (f"{day}-test.png" if args.test else (f"{day}-final.png" if args.final else f"{day}.png"))
    render(day, rows, group, args.test, png, font)
    print(f"wrote {png} ({png.stat().st_size} bytes, {len(rows)} samples, nearest={group})")

    if args.no_post:
        return 0

    content = summary_text(day, rows, group, args.test)
    if args.final:
        content = "【前日分・確定（0〜24時）】\n" + content
    post_discord(content, png)
    print(f"posted Discord message for {day} ({'test' if args.test else 'daily'})")
    if not args.test:
        mark_sent(day, kind)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as e:
        print(f"campus-apload-report failed: {e}", file=sys.stderr)
        raise SystemExit(1)
