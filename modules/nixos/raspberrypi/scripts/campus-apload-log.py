#!/usr/bin/env python3
"""Record campus AP BSS Load (station count / channel utilisation) from wlan0.

Writes per-BSS and nearest-AP total CSVs under /var/lib/campus-apload/.
Intended to run every 5 minutes as a systemd oneshot. Root required for iw scan.
"""
from __future__ import annotations

import csv
import datetime as dt
import pathlib
import re
import subprocess
import sys
import time

JST = dt.timezone(dt.timedelta(hours=9))
DATA_DIR = pathlib.Path("/var/lib/campus-apload")
IFACE = "wlan0"
IW = "/usr/sbin/iw"
SCAN_TIMEOUT = 30
DUMP_TIMEOUT = 15
RETENTION_DAYS = 180
CAMPUS_SSIDS = frozenset({"Hazamaru AP-tr", "eduroam"})

BSS_RE = re.compile(r"^BSS ([0-9a-fA-F:]{17})")
BSS_COLS = [
    "timestamp",
    "bssid",
    "ssid",
    "freq_mhz",
    "signal_dbm",
    "station_count",
    "channel_util",
    "ap_group",
    "nearest",
    "self_associated",
    "scan_source",
]
NEAR_COLS = [
    "timestamp",
    "ap_group",
    "strongest_signal_dbm",
    "scan_source",
    "aptr_5g",
    "aptr_24g",
    "eduroam_5g",
    "eduroam_24g",
    "hidden_5g",
    "hidden_24g",
    "other",
    "total",
    "total_ex_self",
    "util_5g",
    "util_24g",
    "self_bssid",
]


def now_jst() -> dt.datetime:
    return dt.datetime.now(JST).replace(microsecond=0)


def ts_str(t: dt.datetime) -> str:
    return t.strftime("%Y-%m-%d %H:%M:%S")


def ap_group(bssid: str) -> str:
    parts = bssid.lower().split(":")
    if len(parts) != 6:
        return bssid.lower()
    return ":".join(parts[3:])


def is_5g(freq: int | None) -> bool:
    return freq is not None and freq >= 5000


def decode_ssid(raw: str) -> str:
    if "\\x" not in raw and "\\" not in raw:
        return raw
    out = bytearray()
    i = 0
    s = raw
    while i < len(s):
        if s[i] == "\\" and i + 3 < len(s) and s[i + 1] == "x":
            try:
                out.append(int(s[i + 2 : i + 4], 16))
                i += 4
                continue
            except ValueError:
                pass
        if s[i] == "\\" and i + 1 < len(s) and s[i + 1] in "nt\\":
            out.extend({"n": b"\n", "t": b"\t", "\\": b"\\"}.get(s[i + 1], s[i + 1].encode()))
            i += 2
            continue
        out.extend(s[i].encode("utf-8", "surrogateescape"))
        i += 1
    return out.decode("utf-8", "replace")


def local_macs() -> set[str]:
    macs: set[str] = set()
    net = pathlib.Path("/sys/class/net")
    if not net.exists():
        return macs
    for iface in net.iterdir():
        addr_path = iface / "address"
        if not addr_path.exists():
            continue
        addr = addr_path.read_text().strip().lower()
        if not addr or addr == "00:00:00:00:00:00":
            continue
        macs.add(addr)
    return macs


def run_scan() -> tuple[str, str]:
    last = "unknown error"
    for attempt in range(1, 4):
        try:
            r = subprocess.run(
                [IW, "dev", IFACE, "scan"],
                capture_output=True,
                text=True,
                timeout=SCAN_TIMEOUT,
            )
            if r.returncode == 0 and r.stdout.strip():
                if attempt > 1:
                    print(f"iw scan succeeded on attempt {attempt}", file=sys.stderr)
                return r.stdout, "scan"
            last = (r.stderr or "").strip().replace("\n", " ") or "empty output"
            print(f"iw scan attempt {attempt}/3 failed (rc={r.returncode}): {last}", file=sys.stderr)
        except subprocess.TimeoutExpired:
            last = "timed out"
            print(f"iw scan attempt {attempt}/3 timed out", file=sys.stderr)
        if attempt < 3:
            time.sleep(4)
    print(f"iw scan failed after retries ({last}); falling back to scan dump", file=sys.stderr)
    r = subprocess.run(
        [IW, "dev", IFACE, "scan", "dump"],
        capture_output=True,
        text=True,
        timeout=DUMP_TIMEOUT,
    )
    if r.returncode != 0 or not r.stdout.strip():
        err = (r.stderr or "").strip().replace("\n", " ")
        raise RuntimeError(f"iw scan dump failed (rc={r.returncode}): {err or 'empty output'}")
    return r.stdout, "dump"


def parse_bsses(text: str) -> list[dict]:
    bsses: list[dict] = []
    cur = None
    for line in text.splitlines():
        m = BSS_RE.match(line)
        if m:
            if cur is not None:
                bsses.append(cur)
            cur = {
                "bssid": m.group(1).lower(),
                "associated": "-- associated" in line,
                "ssid": "",
                "freq": None,
                "signal": None,
                "sta": None,
                "util": None,
            }
            continue
        if cur is None:
            continue
        s = line.strip()
        if s.startswith("freq:"):
            try:
                cur["freq"] = int(float(s.split(":", 1)[1].strip().split()[0]))
            except ValueError:
                pass
        elif s.startswith("signal:"):
            try:
                cur["signal"] = float(s.split(":", 1)[1].strip().split()[0])
            except ValueError:
                pass
        elif s.startswith("SSID:"):
            cur["ssid"] = decode_ssid(s.split(":", 1)[1].strip())
        elif s.startswith("* station count:"):
            try:
                cur["sta"] = int(s.split(":", 1)[1].strip())
            except ValueError:
                pass
        elif s.startswith("* channel utilisation:"):
            part = s.split(":", 1)[1].strip()
            try:
                cur["util"] = int(part.split("/", 1)[0].strip())
            except ValueError:
                pass
    if cur is not None:
        bsses.append(cur)
    return bsses


def pick_nearest(bsses: list[dict], local: set[str]) -> str | None:
    local_groups = {ap_group(m) for m in local}
    cands = [
        b
        for b in bsses
        if b["sta"] is not None
        and b["bssid"] not in local
        and ap_group(b["bssid"]) not in local_groups
    ]
    if not cands:
        return None
    groups: dict[str, list[dict]] = {}
    for b in cands:
        groups.setdefault(ap_group(b["bssid"]), []).append(b)

    def score(members: list[dict]) -> float:
        return max(x["signal"] if x["signal"] is not None else -999.0 for x in members)

    campus = {
        g: ms
        for g, ms in groups.items()
        if any(x["ssid"] in CAMPUS_SSIDS for x in ms)
    }
    pool = campus or groups
    return max(pool.items(), key=lambda kv: score(kv[1]))[0]


def classify(ssid: str, freq: int | None) -> str:
    band = "5g" if is_5g(freq) else "24g"
    if ssid == "Hazamaru AP-tr":
        return f"aptr_{band}"
    if ssid == "eduroam":
        return f"eduroam_{band}"
    if not ssid:
        return f"hidden_{band}"
    return "other"


def append_csv(path: pathlib.Path, cols: list[str], row: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    new = not path.exists() or path.stat().st_size == 0
    with path.open("a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        if new:
            w.writeheader()
        w.writerow(row)


def prune(now: dt.datetime) -> None:
    cutoff = (now.date() - dt.timedelta(days=RETENTION_DAYS)).isoformat()
    if not DATA_DIR.exists():
        return
    for p in DATA_DIR.glob("*.csv"):
        name = p.name
        day = name[:10]
        if re.match(r"\d{4}-\d{2}-\d{2}", day) and day < cutoff:
            p.unlink()
            print(f"pruned {p.name}")
    graphs = DATA_DIR / "graphs"
    if graphs.exists():
        for p in graphs.glob("*.png"):
            day = p.stem[:10]
            if re.match(r"\d{4}-\d{2}-\d{2}", day) and day < cutoff:
                p.unlink()
                print(f"pruned {p.name}")


def nearest_totals(members: list[dict], source: str, ts: str, group: str) -> dict:
    keys = {
        "aptr_5g": 0,
        "aptr_24g": 0,
        "eduroam_5g": 0,
        "eduroam_24g": 0,
        "hidden_5g": 0,
        "hidden_24g": 0,
        "other": 0,
    }
    util_5g = None
    util_24g = None
    self_bssid = ""
    self_sta = 0
    signals = []
    for b in members:
        cls = classify(b["ssid"], b["freq"])
        sta = int(b["sta"] or 0)
        keys[cls] = keys.get(cls, 0) + sta
        if b["associated"]:
            self_bssid = b["bssid"]
            self_sta = sta
        if b["signal"] is not None:
            signals.append(b["signal"])
        if b["util"] is not None:
            if is_5g(b["freq"]):
                util_5g = b["util"] if util_5g is None else max(util_5g, b["util"])
            else:
                util_24g = b["util"] if util_24g is None else max(util_24g, b["util"])
    total = sum(keys.values())
    ex = total - 1 if self_bssid and self_sta >= 1 else total
    return {
        "timestamp": ts,
        "ap_group": group,
        "strongest_signal_dbm": f"{max(signals):.2f}" if signals else "",
        "scan_source": source,
        **keys,
        "total": total,
        "total_ex_self": ex,
        "util_5g": "" if util_5g is None else util_5g,
        "util_24g": "" if util_24g is None else util_24g,
        "self_bssid": self_bssid,
    }


def main() -> int:
    t = now_jst()
    ts = ts_str(t)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    prune(t)

    text, source = run_scan()
    bsses = parse_bsses(text)
    loaded = [b for b in bsses if b["sta"] is not None]
    local = local_macs()
    nearest = pick_nearest(loaded, local)

    day = t.strftime("%Y-%m-%d")
    bss_path = DATA_DIR / f"{day}.csv"
    near_path = DATA_DIR / f"{day}-nearest.csv"

    for b in loaded:
        group = ap_group(b["bssid"])
        append_csv(
            bss_path,
            BSS_COLS,
            {
                "timestamp": ts,
                "bssid": b["bssid"],
                "ssid": b["ssid"],
                "freq_mhz": "" if b["freq"] is None else b["freq"],
                "signal_dbm": "" if b["signal"] is None else f"{b['signal']:.2f}",
                "station_count": b["sta"],
                "channel_util": "" if b["util"] is None else b["util"],
                "ap_group": group,
                "nearest": 1 if nearest and group == nearest else 0,
                "self_associated": 1 if b["associated"] else 0,
                "scan_source": source,
            },
        )

    if nearest:
        members = [b for b in loaded if ap_group(b["bssid"]) == nearest]
        totals = nearest_totals(members, source, ts, nearest)
        append_csv(near_path, NEAR_COLS, totals)
        print(
            f"{ts} source={source} nearest={nearest} "
            f"total={totals['total']} ex_self={totals['total_ex_self']} "
            f"aptr_5g={totals['aptr_5g']} eduroam_5g={totals['eduroam_5g']} "
            f"aptr_24g={totals['aptr_24g']} eduroam_24g={totals['eduroam_24g']} "
            f"util_5g={totals['util_5g']} util_24g={totals['util_24g']} "
            f"bss={len(loaded)}"
        )
    else:
        print(f"{ts} source={source} nearest=none bss_with_load={len(loaded)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as e:
        print(f"campus-apload-log failed: {e}", file=sys.stderr)
        raise SystemExit(1)
