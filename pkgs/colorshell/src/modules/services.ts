import GObject, { property, register } from "ags/gobject";
import { execAsync } from "ags/process";
import { execApp } from "./apps";
import GLib from "gi://GLib?version=2.0";

export type ServiceLevel = "active" | "running" | "warn" | "failed";

export interface ServiceItem {
    id: string;
    name: string;
    level: ServiceLevel;
    statusText: string;
    unitScope: "user" | "system";
    units: Array<string>;
    isActive: boolean;
    canToggle: boolean;
    extraLabel?: string;
    extraAction?: () => void;
}

@register({ GTypeName: "ClshServices" })
class ServicesMonitor extends GObject.Object {
    private static instance: ServicesMonitor | null = null;

    #pollId: number | null = null;
    #refreshing = false;

    @property(String)
    overall = "ok";

    @property(String)
    cssClass = "services ok";

    @property(String)
    tooltip = "裏方デーモン・システム状態を確認中…";

    @property(String)
    dot0Class = "svc-dot active";

    @property(String)
    dot1Class = "svc-dot active";

    @property(String)
    dot2Class = "svc-dot active";

    @property(String)
    dot3Class = "svc-dot active";

    @property(String)
    dot4Class = "svc-dot active";

    @property(String)
    dot5Class = "svc-dot active";

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
        ])
            .then(([ust, sst, rbRes]) => {
                const ucS = ust[0] || "unknown";
                const lmS = ust[1] || "unknown";
                const tdS = ust[2] || "unknown";
                const ctS = ust[3] || "unknown";
                const ciS = ust[4] || "unknown";

                const tsS = sst[0] || "unknown";
                const rbS = sst[1] || "unknown";
                const rtS = sst[2] || "unknown";

                const yazi = GLib.getenv("COLORSHELL_YAZI_CMD") || "yazi";
                const ghostty = GLib.getenv("COLORSHELL_GHOSTTY_CMD") || "ghostty";

                const clipLevel: ServiceLevel = (ctS === "active" && ciS === "active")
                    ? "active"
                    : ((ctS === "failed" || ciS === "failed") ? "failed" : "warn");
                const clipStatus = (ctS === "active" && ciS === "active")
                    ? "active / active"
                    : `text=${ctS} image=${ciS}`;

                const tsUp = GLib.file_test("/sys/class/net/tailscale0", GLib.FileTest.EXISTS);
                const tsLevel: ServiceLevel = tsS === "active"
                    ? (tsUp ? "active" : "warn")
                    : this.#levelFromUnitState(tsS);
                const tsStatus = tsS === "active"
                    ? (tsUp ? "active (tailscale0 UP)" : "active (tailscale0 未接続)")
                    : tsS;

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
                        level: this.#levelFromUnitState(tdS),
                        statusText: tdS,
                        unitScope: "user",
                        units: ["taildrop-receive.service"],
                        isActive: tdS === "active",
                        canToggle: true,
                        extraLabel: "フォルダ",
                        extraAction: () => execApp(`${ghostty} -e ${yazi} ${GLib.get_home_dir()}/Downloads`),
                    },
                    {
                        id: "cliphist",
                        name: "Cliphist (text/image)",
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
                        level: tsLevel,
                        statusText: tsStatus,
                        unitScope: "system",
                        units: ["tailscaled.service"],
                        isActive: tsS === "active",
                        canToggle: false,
                        extraLabel: "Status",
                        extraAction: () => this.#runTerm("tailscale status"),
                    },
                    {
                        id: "restic",
                        name: "Restic Backup",
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

                let overall = "ok";
                for (const it of items) {
                    if (it.level === "failed") {
                        overall = "failed";
                        break;
                    }
                    if (it.level === "warn" && overall === "ok") {
                        overall = "degraded";
                    }
                }

                const prefixFor = (lvl: ServiceLevel): string => {
                    if (lvl === "failed") return "✗";
                    if (lvl === "warn") return "!";
                    if (lvl === "running") return "↻";
                    return "•";
                };
                const tipLines = [
                    "裏方デーモン・システム状態",
                    ...items.map((it) => `${prefixFor(it.level)} ${it.name}: ${it.statusText}`),
                    "",
                    "左クリック: コントロールセンターで管理 / 右クリック: Rofi メニュー",
                ];

                this.items = items;
                this.overall = overall;
                this.cssClass = `services ${overall}`;
                this.tooltip = tipLines.join("\n");
                this.dot0Class = `svc-dot ${items[0].level}`;
                this.dot1Class = `svc-dot ${items[1].level}`;
                this.dot2Class = `svc-dot ${items[2].level}`;
                this.dot3Class = `svc-dot ${items[3].level}`;
                this.dot4Class = `svc-dot ${items[4].level}`;
                this.dot5Class = `svc-dot ${items[5].level}`;
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

    public restartTailscale(): void {
        this.#runTerm("sudo systemctl restart tailscaled.service && tailscale status");
    }

    public openRofiMenu(): void {
        const cmd = GLib.getenv("COLORSHELL_SERVICES_MENU_CMD") || "services-menu";
        execApp(cmd);
    }
}

export default ServicesMonitor;
