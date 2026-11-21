import { execAsync } from "ags/process";
import { decoder } from "./utils";
import GLib from "gi://GLib?version=2.0";

export interface WorldClockRow {
    tag: string;
    datetime: string;
    meta: string;
}

export interface WorldClockSnapshot {
    zones: Array<WorldClockRow>;
    gpst: WorldClockRow;
    unix: WorldClockRow;
    ntpSynced: boolean;
    tooltip: string;
}

const WEEKDAYS = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

interface LeapEntry {
    ntp: number;
    dtai: number;
}

const TZ_SPECS = [
    { id: "Asia/Tokyo", fallbackTag: "JST" },
    { id: "UTC", fallbackTag: "UTC" },
    { id: "America/Los_Angeles", fallbackTag: "LA" },
    { id: "Asia/Shanghai", fallbackTag: "CST" },
];

const cachedTimeZones = TZ_SPECS.map((spec) => ({
    ...spec,
    tz: GLib.TimeZone.new_identifier(spec.id) ?? GLib.TimeZone.new_utc(),
}));

let cachedLeapTable: Array<LeapEntry> | null = null;

function loadLeapSeconds(): Array<LeapEntry> {
    if (cachedLeapTable !== null) {
        return cachedLeapTable;
    }

    const candidates: Array<string> = [];
    const tzdir = GLib.getenv("TZDIR");
    if (tzdir) {
        candidates.push(`${tzdir}/leap-seconds.list`);
    }
    candidates.push(
        "/etc/zoneinfo/leap-seconds.list",
        "/usr/share/zoneinfo/leap-seconds.list",
    );

    const entries: Array<LeapEntry> = [];
    for (const path of candidates) {
        if (!GLib.file_test(path, GLib.FileTest.EXISTS)) {
            continue;
        }
        try {
            const [ok, bytes] = GLib.file_get_contents(path);
            if (!ok) {
                continue;
            }
            const text = decoder.decode(bytes);
            for (const rawLine of text.split("\n")) {
                const line = rawLine.trim();
                if (!line || line.startsWith("#")) {
                    continue;
                }
                const parts = line.split(/\s+/);
                if (parts.length < 2) {
                    continue;
                }
                const ntp = Number(parts[0]);
                const dtai = Number(parts[1]);
                if (Number.isFinite(ntp) && Number.isFinite(dtai)) {
                    entries.push({ ntp, dtai });
                }
            }
            if (entries.length > 0) {
                break;
            }
        } catch {
            // Try next candidate path.
        }
    }

    cachedLeapTable = entries;
    return entries;
}

function getTaiMinusUtc(unixSec: number): number {
    const entries = loadLeapSeconds();
    if (entries.length === 0) {
        // Fallback: TAI - UTC = 37s since 2017-01-01.
        return 37;
    }
    const ntpNow = unixSec + 2208988800;
    let dtai = 19;
    for (const entry of entries) {
        if (entry.ntp <= ntpNow) {
            dtai = entry.dtai;
        }
    }
    return dtai;
}

function pad2(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
}

function formatDateTime(dt: GLib.DateTime): string {
    const y = dt.get_year();
    const mo = pad2(dt.get_month());
    const d = pad2(dt.get_day_of_month());
    const wd = WEEKDAYS[dt.get_day_of_week()] ?? "???";
    const hh = pad2(dt.get_hour());
    const mm = pad2(dt.get_minute());
    const ss = pad2(dt.get_second());
    return `${y}-${mo}-${d} (${wd}) ${hh}:${mm}:${ss}`;
}

function formatOffset(dt: GLib.DateTime): string {
    const raw = dt.format("%z") ?? "+0000";
    if (raw.length >= 5) {
        return `${raw.slice(0, 3)}:${raw.slice(3, 5)}`;
    }
    return raw;
}

export function getWorldClockSnapshot(dt: GLib.DateTime): WorldClockSnapshot {
    const nowUnix = dt.to_unix();
    const zones: Array<WorldClockRow> = [];
    const tipLines: Array<string> = [];

    for (const spec of cachedTimeZones) {
        const zdt = dt.to_timezone(spec.tz);
        const abbr = zdt.format("%Z") || spec.fallbackTag;
        const ts = formatDateTime(zdt);
        const off = formatOffset(zdt);
        zones.push({
            tag: abbr,
            datetime: ts,
            meta: off,
        });
        tipLines.push(`${abbr.padEnd(4, " ")} ${ts} (${off})`);
    }

    // GPST = TAI - 19s (epoch 1980-01-06T00:00:00Z = Unix 315964800).
    const dtai = getTaiMinusUtc(nowUnix);
    const gpsOff = dtai - 19;
    const gpsUnix = nowUnix + gpsOff;
    const gpsSec = nowUnix - 315964800 + gpsOff;
    const gpsWeek = Math.floor(gpsSec / 604800);
    const gpsTow = ((gpsSec % 604800) + 604800) % 604800;
    const gpsDt = GLib.DateTime.new_from_unix_utc(gpsUnix);
    const gpsTs = formatDateTime(gpsDt);
    const gpsOffSign = gpsOff >= 0 ? `+${gpsOff}` : `${gpsOff}`;
    const gpsMeta = `UTC${gpsOffSign}s / W${gpsWeek} ${gpsTow}s`;

    const gpst: WorldClockRow = {
        tag: "GPST",
        datetime: gpsTs,
        meta: gpsMeta,
    };
    tipLines.push(`${"GPST".padEnd(4, " ")} ${gpsTs} (${gpsMeta})`);

    const unix: WorldClockRow = {
        tag: "UNIX",
        datetime: `${nowUnix}`,
        meta: "epoch",
    };
    tipLines.push(`${"UNIX".padEnd(4, " ")} ${nowUnix}`);

    const ntpSynced = GLib.file_test(
        "/run/systemd/timesync/synchronized",
        GLib.FileTest.EXISTS,
    );
    const ntpLine = ntpSynced
        ? "NTP: 同期済み（右クリックまたはボタンで時刻同期）"
        : "NTP: 同期待ち（右クリックまたはボタンで時刻同期）";

    return {
        zones,
        gpst,
        unix,
        ntpSynced,
        tooltip: `${tipLines.join("\n")}\n\n${ntpLine}`,
    };
}

export function triggerNtpSync(): void {
    const cmd = GLib.getenv("COLORSHELL_NTP_SYNC_CMD") || "ntp-sync";
    execAsync([cmd]).catch((err) => {
        console.error("Failed to run ntp-sync:", err);
    });
}
