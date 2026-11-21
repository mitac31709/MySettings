import { createPoll } from "ags/time";
import { execApp } from "./apps";
import { decoder } from "./utils";
import GLib from "gi://GLib?version=2.0";

export interface SysStatsSnapshot {
    cpuPct: number;
    memPct: number;
    label: string;
    tooltip: string;
    cssClass: string;
}

let prevTotal = 0;
let prevIdle = 0;

function readFileText(path: string): string | null {
    try {
        const [ok, bytes] = GLib.file_get_contents(path);
        if (!ok) return null;
        return decoder.decode(bytes);
    } catch {
        return null;
    }
}

function readCpuPct(): number {
    const raw = readFileText("/proc/stat");
    if (!raw) return 0;
    const firstLine = raw.split("\n", 1)[0];
    if (!firstLine || !firstLine.startsWith("cpu ")) return 0;
    const parts = firstLine.trim().split(/\s+/).slice(1).map((n) => Number.parseInt(n, 10) || 0);
    if (parts.length < 4) return 0;

    const idle = (parts[3] || 0) + (parts[4] || 0);
    const total = parts.reduce((acc, v) => acc + v, 0);

    let pct = 0;
    if (prevTotal > 0 && total > prevTotal) {
        const dTotal = total - prevTotal;
        const dIdle = Math.max(0, idle - prevIdle);
        pct = Math.round(((dTotal - dIdle) / dTotal) * 100);
    }
    prevTotal = total;
    prevIdle = idle;
    return Math.max(0, Math.min(100, pct));
}

function readMemInfo(): {
    memPct: number;
    usedGiB: number;
    totalGiB: number;
    swapUsedGiB: number;
    swapTotalGiB: number;
} {
    const raw = readFileText("/proc/meminfo");
    if (!raw) {
        return { memPct: 0, usedGiB: 0, totalGiB: 0, swapUsedGiB: 0, swapTotalGiB: 0 };
    }
    const vals: Record<string, number> = {};
    for (const line of raw.split("\n")) {
        const m = /^([A-Za-z0-9_()]+):\s+(\d+)/.exec(line);
        if (m) {
            vals[m[1]] = Number.parseInt(m[2], 10);
        }
    }
    const totalKb = vals["MemTotal"] || 0;
    const availKb = vals["MemAvailable"] ?? vals["MemFree"] ?? 0;
    const usedKb = Math.max(0, totalKb - availKb);
    const swapTotalKb = vals["SwapTotal"] || 0;
    const swapFreeKb = vals["SwapFree"] || 0;
    const swapUsedKb = Math.max(0, swapTotalKb - swapFreeKb);

    const memPct = totalKb > 0 ? Math.round((usedKb / totalKb) * 100) : 0;
    const kToG = 1024 * 1024;
    return {
        memPct: Math.max(0, Math.min(100, memPct)),
        usedGiB: usedKb / kToG,
        totalGiB: totalKb / kToG,
        swapUsedGiB: swapUsedKb / kToG,
        swapTotalGiB: swapTotalKb / kToG,
    };
}

function readLoadAvg(): string {
    const raw = readFileText("/proc/loadavg");
    if (!raw) return "";
    return raw.trim().split(/\s+/).slice(0, 3).join(" ");
}

function sampleSysStats(): SysStatsSnapshot {
    const cpuPct = readCpuPct();
    const mem = readMemInfo();
    const load = readLoadAvg();

    let level = "";
    if (cpuPct >= 90 || mem.memPct >= 90) {
        level = " critical";
    } else if (cpuPct >= 75 || mem.memPct >= 80) {
        level = " warning";
    }

    const lines = [
        `CPU: ${cpuPct}%`,
        `メモリ: ${mem.usedGiB.toFixed(1)} / ${mem.totalGiB.toFixed(1)} GiB (${mem.memPct}%)`,
    ];
    if (mem.swapTotalGiB > 0.05) {
        lines.push(`Swap: ${mem.swapUsedGiB.toFixed(1)} / ${mem.swapTotalGiB.toFixed(1)} GiB`);
    }
    if (load) {
        lines.push(`Load: ${load}`);
    }
    lines.push("", "クリックで btop を起動");

    return {
        cpuPct,
        memPct: mem.memPct,
        label: `${cpuPct}% · ${mem.memPct}%`,
        tooltip: lines.join("\n"),
        cssClass: `sysstats${level}`,
    };
}

export const sysStats = createPoll<SysStatsSnapshot>(
    sampleSysStats(),
    3000,
    () => sampleSysStats(),
);

export function openBtop(): void {
    const cmd = GLib.getenv("COLORSHELL_BTOP_CMD") || "ghostty -e btop";
    execApp(cmd);
}

export function openNmtui(): void {
    const cmd = GLib.getenv("COLORSHELL_NMTUI_CMD") || "ghostty -e nmtui";
    execApp(cmd);
}

export function openCheatsheet(): void {
    const cmd = GLib.getenv("COLORSHELL_CHEATSHEET_CMD") || "hypr-cheatsheet";
    execApp(cmd);
}
