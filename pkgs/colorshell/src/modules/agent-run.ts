import GObject, { property, register } from "ags/gobject";
import { execAsync } from "ags/process";
import { decoder } from "./utils";
import GLib from "gi://GLib?version=2.0";
import Gio from "gi://Gio?version=2.0";

const STATUS_FILENAME = "agent-run-status.json";

export interface AgentRunRow {
    kind?: string;
    text?: string;
    durationMs?: number | null;
    state?: string;
}

export interface AgentRunApproval {
    requestId?: string;
    summary?: string;
}

export interface AgentRunThread {
    id?: string;
    title?: string;
    phase?: string;
    provider?: string;
    model?: string;
    action?: string;
    actionKind?: string;
    step?: number;
    segments?: string[];
    startedAt?: string | null;
    finishedAt?: string | null;
    filesChanged?: number | null;
    approval?: AgentRunApproval | null;
    runId?: string | null;
    openUrl?: string | null;
    rows?: AgentRunRow[];
}

interface AgentRunDocument {
    source?: string;
    detail?: string | null;
    threads?: AgentRunThread[];
}

@register({ GTypeName: "ClshAgentRun" })
class AgentRunMonitor extends GObject.Object {
    private static instance: AgentRunMonitor | null = null;

    #statusPath: string;
    #monitor: Gio.FileMonitor | null = null;
    #pollId: number | null = null;
    #pulseId: number | null = null;

    threads: AgentRunThread[] = [];

    @property(Boolean)
    active = false;

    @property(String)
    phase = "running";

    @property(String)
    label = "";

    @property(String)
    tooltip = "";

    @property(String)
    cssClass = "agent-run";

    @property(Boolean)
    pulseDim = false;

    @property(String)
    payload = "";

    constructor() {
        super();
        const runtimeRoot = GLib.get_user_runtime_dir() || "/tmp";
        this.#statusPath = `${runtimeRoot}/${STATUS_FILENAME}`;
        this.refresh();

        try {
            const dir = Gio.File.new_for_path(runtimeRoot);
            this.#monitor = dir.monitor_directory(Gio.FileMonitorFlags.NONE, null);
            this.#monitor.connect("changed", (_mon, file, otherFile) => {
                const n1 = file?.get_basename();
                const n2 = otherFile?.get_basename();
                if (n1 === STATUS_FILENAME || n2 === STATUS_FILENAME) this.refresh();
            });
        } catch (err) {
            console.warn("Failed to watch agent-run-status:", err);
        }

        this.#pollId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 2, () => {
            this.refresh();
            return GLib.SOURCE_CONTINUE;
        });

        this.#pulseId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 700, () => {
            if (this.active && this.phase !== "done") this.pulseDim = !this.pulseDim;
            else if (this.pulseDim) this.pulseDim = false;
            this.#syncClass();
            return GLib.SOURCE_CONTINUE;
        });
    }

    public static getDefault(): AgentRunMonitor {
        if (!this.instance) this.instance = new AgentRunMonitor();
        return this.instance;
    }

    public refresh(): void {
        if (!GLib.file_test(this.#statusPath, GLib.FileTest.EXISTS)) {
            this.#clear();
            return;
        }
        try {
            const [ok, bytes] = GLib.file_get_contents(this.#statusPath);
            if (!ok) return;
            const raw = decoder.decode(bytes).trim();
            if (!raw) {
                this.#clear();
                return;
            }
            if (raw === this.payload) return;
            const parsed = JSON.parse(raw) as AgentRunDocument;
            const threads = Array.isArray(parsed.threads)
                ? parsed.threads.filter((thread) => typeof thread?.id === "string" && thread.id)
                : [];
            this.threads = threads;
            this.payload = raw;
            this.active = threads.length > 0;
            this.phase = pillPhase(threads);
            this.label = pillLabel(threads);
            const lines = threads.map((thread) => {
                const who = thread.provider || thread.title || "agent";
                return `${who}: ${thread.action || thread.phase || ""}`;
            });
            const detail = parsed.detail ? `\n${parsed.detail}` : "";
            this.tooltip = threads.length === 0
                ? (parsed.detail || "エージェントは動いていません")
                : `${lines.join("\n")}${detail}\n\nクリックでカード`;
            this.#syncClass();
        } catch (err) {
            console.warn("Failed to parse agent-run-status:", err);
        }
    }

    public command(args: string[]): void {
        const bin = GLib.getenv("COLORSHELL_AGENT_RUN_CMD") || "agent-run-status";
        execAsync([bin, ...args]).catch((err) => {
            console.warn("agent-run command failed:", err);
        });
    }

    #clear(): void {
        this.threads = [];
        this.payload = "";
        this.active = false;
        this.phase = "running";
        this.label = "";
        this.tooltip = "";
        this.pulseDim = false;
        this.#syncClass();
    }

    #syncClass(): void {
        const pulse = this.pulseDim && this.phase !== "done" ? " pulse-dim" : "";
        this.cssClass = `agent-run ${this.phase}${pulse}`;
    }
}

function pillPhase(threads: AgentRunThread[]): string {
    if (threads.some((thread) => thread.phase === "approval")) return "approval";
    if (threads.some((thread) => thread.phase === "running")) return "running";
    if (threads.some((thread) => thread.phase === "error")) return "error";
    return "done";
}

function pillLabel(threads: AgentRunThread[]): string {
    if (threads.length === 0) return "";
    if (threads.length > 1) return String(threads.length);
    const thread = threads[0];
    if (thread.phase === "done") return "Done";
    const text = (thread.provider || thread.title || "agent").trim();
    return text.length > 18 ? `${text.slice(0, 17)}…` : text;
}

export default AgentRunMonitor;
