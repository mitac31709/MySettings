import GObject, { property, register } from "ags/gobject";
import { execAsync } from "ags/process";
import { execApp } from "./apps";
import GLib from "gi://GLib?version=2.0";

export type ServiceLevel = "active" | "running" | "warn" | "failed";

export interface ServiceItem {
    id: string;
    name: string;
    iconName: string;
    level: ServiceLevel;
    statusText: string;
    unitScope: "user" | "system";
    units: Array<string>;
    isActive: boolean;
    canToggle: boolean;
    extraLabel?: string;
    extraAction?: () => void;
}

export interface ServiceDef {
    id: string;
    name: string;
    iconName: string;
}

export const SERVICE_DEFS: ReadonlyArray<ServiceDef> = [
    { id: "uniclipd", name: "UniClipboard", iconName: "edit-copy-symbolic" },
    { id: "lan-mouse", name: "LAN Mouse", iconName: "input-mouse-symbolic" },
    { id: "taildrop", name: "Taildrop Receive", iconName: "folder-download-symbolic" },
    { id: "cliphist", name: "Cliphist (text/image)", iconName: "edit-paste-symbolic" },
    { id: "tailscale", name: "Tailscale", iconName: "network-vpn-symbolic" },
    { id: "restic", name: "Restic Backup", iconName: "drive-harddisk-symbolic" },
];

@register({ GTypeName: "ClshServices" })
class ServicesMonitor extends GObject.Object {
    private static instance: ServicesMonitor | null = null;

    #pollId: number | null = null;
    #refreshing = false;

    @property(Array)
    items: Array<ServiceItem> = [];

    constructor() {
        super();
        this.refreshNow();

        this.#pollId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 10, () => {
            this.refreshNow();
            return GLib.SOURCE_CONTINUE;
        });
    }

    public static getDefault(): ServicesMonitor {
        if (!this.instance) {
            this.instance = new ServicesMonitor();
        }
        return this.instance;
    }

    async #queryStates(scope: "user" | "system", units: Array<string>): Promise<Array<string>> {
        const argv = scope === "user"
            ? ["systemctl", "--user", "show", "-p", "ActiveState", "--value", ...units]
            : ["systemctl", "show", "-p", "ActiveState", "--value", ...units];
        try {
            const out = await execAsync(argv);
            const lines = out.split("\n").map((s) => s.trim()).filter(Boolean);
            return units.map((_, idx) => lines[idx] || "unknown");
        } catch {
            return units.map(() => "unknown");
        }
    }

    async #queryResticResult(): Promise<string> {
        try {
            const out = await execAsync([
                "systemctl",
                "show",
                "-p",
                "Result",
                "--value",
                "restic-backups-home.service",
            ]);
            return out.trim();
        } catch {
            return "";
        }
    }

    async #queryTailscaleState(): Promise<{ backendState: string; ip: string }> {
        const tsBin = GLib.getenv("COLORSHELL_TAILSCALE_CMD") || "tailscale";
        try {
            const out = await execAsync([tsBin, "status", "--json", "--peers=false"]);
            const data = JSON.parse(out) as {
                BackendState?: string;
                TailscaleIPs?: Array<string>;
            };
            const backendState = typeof data.BackendState === "string" ? data.BackendState : "";
            const ips = Array.isArray(data.TailscaleIPs) ? data.TailscaleIPs : [];
            const ipv4 = ips.find((addr) => addr.includes(".")) || ips[0] || "";
            return { backendState, ip: ipv4 };
        } catch {
            return { backendState: "", ip: "" };
        }
    }

    #levelFromUnitState(st: string): ServiceLevel {
        if (st === "active") return "active";
        if (st === "activating") return "running";
        if (st === "failed") return "failed";
        return "warn";
    }

    #runTerm(cmd: string): void {
        const ghostty = GLib.getenv("COLORSHELL_GHOSTTY_CMD") || "ghostty";
        execApp(`${ghostty} -e bash -lc "${cmd.replace(/"/g, '\\"')}; printf '\\n[Enter で閉じる] '; IFS= read -r _ || true"`);
    }

    public refreshNow(): void {
        if (this.#refreshing) {
            return;
        }
        this.#refreshing = true;

        Promise.all([
            this.#queryStates("user", [
                "uniclipd.service",
                "lan-mouse.service",
                "taildrop-receive.service",
                "cliphist-text.service",
                "cliphist-image.service",
            ]),
            this.#queryStates("system", [
                "tailscaled.service",
                "restic-backups-home.service",
                "restic-backups-home.timer",
            ]),
            this.#queryResticResult(),
            this.#queryTailscaleState(),
        ])
            .then(([ust, sst, rbRes, tsInfo]) => {
                const ucS = ust[0] || "unknown";
                const lmS = ust[1] || "unknown";
                const tdS = ust[2] || "unknown";
                const ctS = ust[3] || "unknown";
                const ciS = ust[4] || "unknown";

                const tsS = sst[0] || "unknown";
                const rbS = sst[1] || "unknown";
                const rtS = sst[2] || "unknown";

                const nemo = GLib.getenv("COLORSHELL_NEMO_CMD") || "nemo";

                const clipLevel: ServiceLevel = (ctS === "active" && ciS === "active")
                    ? "active"
                    : ((ctS === "failed" || ciS === "failed") ? "failed" : "warn");
                const clipStatus = (ctS === "active" && ciS === "active")
                    ? "active / active"
                    : `text=${ctS} image=${ciS}`;

                let tsLevel: ServiceLevel;
                let tsStatus: string;
                let tsRunning = false;
                if (tsS !== "active") {
                    tsLevel = this.#levelFromUnitState(tsS);
                    tsStatus = tsS;
                } else if (tsInfo.backendState === "Running") {
                    tsLevel = "active";
                    tsStatus = tsInfo.ip ? `Running (${tsInfo.ip})` : "Running";
                    tsRunning = true;
                } else if (tsInfo.backendState === "Starting") {
                    tsLevel = "running";
                    tsStatus = "Starting";
                } else if (tsInfo.backendState === "Stopped") {
                    tsLevel = "warn";
                    tsStatus = "Stopped (未接続)";
                } else if (tsInfo.backendState === "NeedsLogin" || tsInfo.backendState === "NeedsMachineAuth") {
                    tsLevel = "warn";
                    tsStatus = `${tsInfo.backendState} (要認証)`;
                } else {
                    tsLevel = "warn";
                    tsStatus = tsInfo.backendState
                        ? `active (${tsInfo.backendState})`
                        : "active (状態取得失敗)";
                }

                let rbLevel: ServiceLevel;
                let rbStatus: string;
                if (rbS === "active" || rbS === "activating") {
                    rbLevel = "running";
                    rbStatus = `実行中 (timer=${rtS})`;
                } else if (rbS === "failed" || (rbRes.length > 0 && rbRes !== "success")) {
                    rbLevel = "failed";
                    rbStatus = `service=${rbS} result=${rbRes} (timer=${rtS})`;
                } else if (rtS === "active") {
                    rbLevel = "active";
                    rbStatus = "待機 (timer active / 正常)";
                } else {
                    rbLevel = this.#levelFromUnitState(rtS);
                    rbStatus = `timer=${rtS} service=${rbS}`;
                }

                const items: Array<ServiceItem> = [
                    {
                        id: "uniclipd",
                        name: "UniClipboard",
                        iconName: "edit-copy-symbolic",
                        level: this.#levelFromUnitState(ucS),
                        statusText: ucS,
                        unitScope: "user",
                        units: ["uniclipd.service"],
                        isActive: ucS === "active",
                        canToggle: true,
                        extraLabel: "GUI",
                        extraAction: () => execApp("uniclipboard"),
                    },
                    {
                        id: "lan-mouse",
                        name: "LAN Mouse",
                        iconName: "input-mouse-symbolic",
                        level: this.#levelFromUnitState(lmS),
                        statusText: lmS,
                        unitScope: "user",
                        units: ["lan-mouse.service"],
                        isActive: lmS === "active",
                        canToggle: true,
                        extraLabel: "GUI",
                        extraAction: () => execApp("lan-mouse"),
                    },
                    {
                        id: "taildrop",
                        name: "Taildrop Receive",
                        iconName: "folder-download-symbolic",
                        level: this.#levelFromUnitState(tdS),
                        statusText: tdS,
                        unitScope: "user",
                        units: ["taildrop-receive.service"],
                        isActive: tdS === "active",
                        canToggle: true,
                        extraLabel: "フォルダ",
                        extraAction: () => execApp(`${nemo} ${GLib.get_home_dir()}/Downloads`),
                    },
                    {
                        id: "cliphist",
                        name: "Cliphist (text/image)",
                        iconName: "edit-paste-symbolic",
                        level: clipLevel,
                        statusText: clipStatus,
                        unitScope: "user",
                        units: ["cliphist-text.service", "cliphist-image.service"],
                        isActive: ctS === "active" && ciS === "active",
                        canToggle: false,
                        extraLabel: "履歴",
                        extraAction: () => execApp("clipboard-history"),
                    },
                    {
                        id: "tailscale",
                        name: "Tailscale",
                        iconName: "network-vpn-symbolic",
                        level: tsLevel,
                        statusText: tsStatus,
                        unitScope: "system",
                        units: ["tailscaled.service"],
                        isActive: tsS === "active" && tsRunning,
                        canToggle: tsS === "active",
                        extraLabel: "Status",
                        extraAction: () => this.#runTerm("tailscale status"),
                    },
                    {
                        id: "restic",
                        name: "Restic Backup",
                        iconName: "drive-harddisk-symbolic",
                        level: rbLevel,
                        statusText: rbStatus,
                        unitScope: "system",
                        units: ["restic-backups-home.service"],
                        isActive: rbS === "active" || rbS === "activating",
                        canToggle: false,
                        extraLabel: "ログ",
                        extraAction: () => this.#runTerm("backup status; echo; backup log"),
                    },
                ];

                this.items = items;
            })
            .catch((err) => {
                console.warn("ServicesMonitor poll failed:", err);
            })
            .finally(() => {
                this.#refreshing = false;
            });
    }

    public restartUserUnits(units: Array<string>): void {
        execAsync(["systemctl", "--user", "restart", ...units])
            .catch((err) => console.warn("restart user units failed:", err))
            .finally(() => this.refreshNow());
    }

    public toggleUserUnit(unit: string, currentlyActive: boolean): void {
        const verb = currentlyActive ? "stop" : "start";
        execAsync(["systemctl", "--user", verb, unit])
            .catch((err) => console.warn(`${verb} ${unit} failed:`, err))
            .finally(() => this.refreshNow());
    }

    public runBackupNow(): void {
        this.#runTerm("sudo backup run");
    }

    public toggleTailscale(currentlyRunning: boolean): void {
        const tsBin = GLib.getenv("COLORSHELL_TAILSCALE_CMD") || "tailscale";
        const subcmd = currentlyRunning ? "down" : "up";
        execAsync([tsBin, subcmd])
            .catch((err) => console.warn(`tailscale ${subcmd} failed:`, err))
            .finally(() => this.refreshNow());
    }

    public restartTailscale(): void {
        this.#runTerm("sudo systemctl restart tailscaled.service && tailscale status");
    }

    public openRofiMenu(): void {
        const cmd = GLib.getenv("COLORSHELL_SERVICES_MENU_CMD") || "services-menu";
        execApp(cmd);
    }
}

export default ServicesMonitor;
