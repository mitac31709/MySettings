import { createPoll } from "ags/time";
import { decoder } from "./utils";
import Notifications from "./notifications";
import AstalNotifd from "gi://AstalNotifd";
import GLib from "gi://GLib?version=2.0";

export interface SysfsBatteryState {
    present: boolean;
    name: string;
    status: string;
    acOnline: boolean;
    percent: number;
    barLabel: string;
    iconName: string;
    cssClass: string;
    headline: string;
    voltageLine: string;
    capacityLine: string;
    powerLine: string;
    noteLine: string;
    gaugeAnomaly: boolean;
    tooltip: string;
}

const EMPTY_STATE: SysfsBatteryState = {
    present: false,
    name: "",
    status: "Unknown",
    acOnline: false,
    percent: 0,
    barLabel: "",
    iconName: "battery-missing-symbolic",
    cssClass: "battery empty",
    headline: "",
    voltageLine: "",
    capacityLine: "",
    powerLine: "",
    noteLine: "",
    gaugeAnomaly: false,
    tooltip: "",
};

function readText(path: string): string | null {
    if (!GLib.file_test(path, GLib.FileTest.EXISTS)) {
        return null;
    }
    try {
        const [ok, bytes] = GLib.file_get_contents(path);
        if (!ok) {
            return null;
        }
        return decoder.decode(bytes).trim();
    } catch {
        return null;
    }
}

function readNum(path: string, fallback = 0): number {
    const raw = readText(path);
    if (raw === null || raw === "") {
        return fallback;
    }
    const n = Number(raw);
    return Number.isFinite(n) ? n : fallback;
}

function listDir(root: string): Array<string> {
    if (!GLib.file_test(root, GLib.FileTest.IS_DIR)) {
        return [];
    }
    const names: Array<string> = [];
    try {
        const dir = GLib.Dir.open(root, 0);
        let name = dir.read_name();
        while (name !== null) {
            names.push(name);
            name = dir.read_name();
        }
        dir.close();
    } catch {
        return [];
    }
    names.sort();
    return names;
}

function findBatteryDir(root: string, preferred: string): string | null {
    if (preferred && GLib.file_test(`${root}/${preferred}`, GLib.FileTest.IS_DIR)) {
        return `${root}/${preferred}`;
    }
    const entries = listDir(root);
    const ordered = [
        ...entries.filter((e) => e.startsWith("BAT")),
        ...entries.filter((e) => !e.startsWith("BAT")),
    ];
    for (const name of ordered) {
        const dir = `${root}/${name}`;
        if (!GLib.file_test(dir, GLib.FileTest.IS_DIR)) {
            continue;
        }
        if (readText(`${dir}/type`) !== "Battery") {
            continue;
        }
        const scope = readText(`${dir}/scope`);
        if (scope && scope.toLowerCase() === "device") {
            continue;
        }
        return dir;
    }
    return null;
}

function readAdapterOnline(root: string, preferred: string): boolean {
    if (preferred) {
        const val = readText(`${root}/${preferred}/online`);
        if (val !== null) {
            return val === "1";
        }
    }
    for (const name of listDir(root)) {
        const dir = `${root}/${name}`;
        if (readText(`${dir}/type`) === "Mains") {
            const val = readText(`${dir}/online`);
            if (val !== null) {
                return val === "1";
            }
        }
    }
    return false;
}

function pad2(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
}

function pickBatteryIcon(cap: number, status: string, gaugeAnomaly: boolean): string {
    if (gaugeAnomaly) {
        return "battery-caution-symbolic";
    }
    if (status === "Full" || (status === "Plugged" && cap >= 98)) {
        return "battery-full-charged-symbolic";
    }
    const bucket = Math.min(100, Math.max(0, Math.round(cap / 10) * 10));
    if (status === "Charging") {
        return `battery-level-${Math.min(90, bucket)}-charging-symbolic`;
    }
    if (cap <= 10) {
        return "battery-caution-symbolic";
    }
    return `battery-level-${bucket}-symbolic`;
}

let anomalyNotified = false;

export function readSysfsBattery(): SysfsBatteryState {
    const root = GLib.getenv("COLORSHELL_POWER_SUPPLY_DIR") || "/sys/class/power_supply";
    const prefBat = GLib.getenv("COLORSHELL_BATTERY_DEV") || "";
    const prefAdapter = GLib.getenv("COLORSHELL_ADAPTER_DEV") || "";

    const batDir = findBatteryDir(root, prefBat);
    if (!batDir) {
        return EMPTY_STATE;
    }

    const batName = GLib.path_get_basename(batDir);
    const rawStatus = readText(`${batDir}/status`) || "Unknown";
    const rawCapStr = readText(`${batDir}/capacity`);
    const rawCap = rawCapStr !== null && rawCapStr !== "" && Number.isFinite(Number(rawCapStr))
        ? Math.trunc(Number(rawCapStr))
        : null;
    const vn = readNum(`${batDir}/voltage_now`, 0);
    const vmin = readNum(`${batDir}/voltage_min_design`, 0);
    const acOnline = readAdapterOnline(root, prefAdapter);

    let mode: "energy" | "charge" | "" = "";
    let nowVal = 0;
    let fullVal = 0;
    let designVal = 0;

    if (
        GLib.file_test(`${batDir}/energy_now`, GLib.FileTest.EXISTS)
        && GLib.file_test(`${batDir}/energy_full`, GLib.FileTest.EXISTS)
    ) {
        mode = "energy";
        nowVal = readNum(`${batDir}/energy_now`, 0);
        fullVal = readNum(`${batDir}/energy_full`, 0);
        designVal = readNum(`${batDir}/energy_full_design`, 0);
    } else if (
        GLib.file_test(`${batDir}/charge_now`, GLib.FileTest.EXISTS)
        && GLib.file_test(`${batDir}/charge_full`, GLib.FileTest.EXISTS)
    ) {
        mode = "charge";
        nowVal = readNum(`${batDir}/charge_now`, 0);
        fullVal = readNum(`${batDir}/charge_full`, 0);
        designVal = readNum(`${batDir}/charge_full_design`, 0);
    }

    let powerVal = 0;
    let pwUnit: "W" | "A" | "" = "";
    let hasPower = false;
    if (GLib.file_test(`${batDir}/power_now`, GLib.FileTest.EXISTS)) {
        powerVal = Math.abs(readNum(`${batDir}/power_now`, 0));
        pwUnit = "W";
        hasPower = true;
    } else if (GLib.file_test(`${batDir}/current_now`, GLib.FileTest.EXISTS)) {
        powerVal = Math.abs(readNum(`${batDir}/current_now`, 0));
        pwUnit = "A";
        hasPower = true;
    }

    let dispStatus = rawStatus;
    if (rawStatus === "Unknown") {
        dispStatus = acOnline ? "Plugged" : "Discharging";
    } else if (rawStatus === "Not charging" && acOnline) {
        dispStatus = "Plugged";
    }

    let cap = 0;
    if ((mode === "energy" || mode === "charge") && fullVal > 0) {
        cap = Math.round((100.0 * nowVal) / fullVal);
    } else if (rawCap !== null) {
        cap = rawCap;
    }
    cap = Math.max(0, Math.min(100, cap));

    if (cap === 100 && dispStatus === "Charging") {
        dispStatus = "Full";
    }

    const acNote = acOnline ? "（AC 接続中）" : "";
    const headline = `${batName}: ${dispStatus} ${cap}%${acNote}`;

    let voltageLine = "";
    if (vn > 0) {
        if (vmin > 0) {
            voltageLine = `電圧: ${(vn / 1e6).toFixed(2)} V（設計下限 ${(vmin / 1e6).toFixed(2)} V）`;
        } else {
            voltageLine = `電圧: ${(vn / 1e6).toFixed(2)} V`;
        }
    }

    const vRef = vn > 0 ? vn / 1e6 : vmin > 0 ? vmin / 1e6 : 0;
    let pwW = 0;
    if (hasPower) {
        if (pwUnit === "W") {
            pwW = powerVal / 1e6;
        } else if (pwUnit === "A" && vRef > 0) {
            pwW = (powerVal / 1e6) * vRef;
        }
    }

    let capacityLine = "";
    let remHours = 0;
    if (mode === "energy") {
        const health = designVal > 0 ? (100.0 * fullVal) / designVal : 0;
        if (designVal > 0) {
            capacityLine = `容量: ${(nowVal / 1e6).toFixed(2)} / ${(fullVal / 1e6).toFixed(2)} Wh（設計 ${(designVal / 1e6).toFixed(2)} Wh / 健康度 ${health.toFixed(0)}%）`;
        } else {
            capacityLine = `容量: ${(nowVal / 1e6).toFixed(2)} / ${(fullVal / 1e6).toFixed(2)} Wh`;
        }
        if (pwW > 0.1) {
            if (dispStatus === "Discharging" && nowVal > 0) {
                remHours = (nowVal / 1e6) / pwW;
            } else if (dispStatus === "Charging" && fullVal > nowVal) {
                remHours = ((fullVal - nowVal) / 1e6) / pwW;
            }
        }
    } else if (mode === "charge") {
        const health = designVal > 0 ? (100.0 * fullVal) / designVal : 0;
        if (vRef > 0) {
            const nowWh = (nowVal / 1e6) * vRef;
            const fullWh = (fullVal / 1e6) * vRef;
            if (designVal > 0) {
                capacityLine = `容量: ${nowWh.toFixed(2)} / ${fullWh.toFixed(2)} Wh（${(nowVal / 1e6).toFixed(2)} / ${(fullVal / 1e6).toFixed(2)} Ah / 健康度 ${health.toFixed(0)}%）`;
            } else {
                capacityLine = `容量: ${nowWh.toFixed(2)} / ${fullWh.toFixed(2)} Wh（${(nowVal / 1e6).toFixed(2)} / ${(fullVal / 1e6).toFixed(2)} Ah）`;
            }
            if (pwW > 0.1) {
                if (dispStatus === "Discharging" && nowVal > 0) {
                    remHours = nowWh / pwW;
                } else if (dispStatus === "Charging" && fullVal > nowVal) {
                    remHours = (fullWh - nowWh) / pwW;
                }
            }
        } else if (designVal > 0) {
            capacityLine = `容量: ${(nowVal / 1e6).toFixed(2)} / ${(fullVal / 1e6).toFixed(2)} Ah（健康度 ${health.toFixed(0)}%）`;
        } else {
            capacityLine = `容量: ${(nowVal / 1e6).toFixed(2)} / ${(fullVal / 1e6).toFixed(2)} Ah`;
        }
    }

    let powerLine = "";
    if (hasPower && (pwUnit === "W" || vRef > 0)) {
        const sign = dispStatus === "Charging" ? "+" : dispStatus === "Discharging" ? "-" : "";
        let etaStr = "";
        if (remHours > 0) {
            const totalMin = Math.round(remHours * 60);
            const hh = Math.floor(totalMin / 60);
            const mm = totalMin % 60;
            const dur = hh > 0 ? `${hh}時間${mm}分` : `${mm}分`;
            const etaDt = GLib.DateTime.new_now_local().add_seconds(Math.round(remHours * 3600));
            const etaTs = etaDt ? `${pad2(etaDt.get_hour())}:${pad2(etaDt.get_minute())}` : "";
            if (dispStatus === "Charging") {
                etaStr = `  満充電まで ${dur} (${etaTs})`;
            } else if (dispStatus === "Discharging") {
                etaStr = `  残り ${dur} (${etaTs})`;
            }
        }
        powerLine = `電力: ${sign}${pwW.toFixed(2)} W${etaStr}`;
    }

    const gaugeAnomaly = cap === 0 && dispStatus === "Discharging" && vn > 5500000;
    let noteLine = "";
    if (gaugeAnomaly) {
        noteLine = "注: 残量 0% 表示でも電圧あり（満充電→空→満充電で較正）";
    } else if (rawCap !== null && rawCap !== cap) {
        noteLine = `注: カーネル capacity=${rawCap}%`;
    }

    if (gaugeAnomaly && !anomalyNotified) {
        anomalyNotified = true;
        Notifications.getDefault().sendNotification({
            urgency: AstalNotifd.Urgency.NORMAL,
            appIcon: "battery-caution-symbolic",
            replaceId: "sysfs-battery-gauge-anomaly",
            summary: `${batName}: 残量 0% 表示（ゲージ異常検知）`,
            body: `${voltageLine || `電圧 ${(vn / 1e6).toFixed(2)} V`} — 電圧が残っています。満充電→空→満充電で較正してください。`,
        }).catch(() => {});
    } else if (!gaugeAnomaly && anomalyNotified) {
        anomalyNotified = false;
    }

    const tipParts = [headline];
    if (voltageLine) tipParts.push(voltageLine);
    if (capacityLine) tipParts.push(capacityLine);
    if (powerLine) tipParts.push(powerLine);
    if (noteLine) tipParts.push(noteLine);

    const classes = ["battery", dispStatus.toLowerCase().replace(/\s+/g, "-")];
    if (gaugeAnomaly) {
        classes.push("anomaly");
    } else if (cap <= 15 && dispStatus === "Discharging") {
        classes.push("critical");
    } else if (cap <= 30 && dispStatus === "Discharging") {
        classes.push("warning");
    }

    const barLabel = gaugeAnomaly
        ? `${cap}%!`
        : dispStatus === "Charging"
            ? `${cap}%`
            : `${cap}%`;

    return {
        present: true,
        name: batName,
        status: dispStatus,
        acOnline,
        percent: cap,
        barLabel,
        iconName: pickBatteryIcon(cap, dispStatus, gaugeAnomaly),
        cssClass: classes.join(" "),
        headline,
        voltageLine,
        capacityLine,
        powerLine,
        noteLine,
        gaugeAnomaly,
        tooltip: tipParts.join("\n"),
    };
}

export const sysfsBattery = createPoll<SysfsBatteryState>(
    readSysfsBattery(),
    5000,
    () => readSysfsBattery(),
);
