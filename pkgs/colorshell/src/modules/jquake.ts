import GObject, { property, register } from "ags/gobject";
import { execAsync } from "ags/process";
import { execApp } from "./apps";
import Compositor from "../compositor";
import GLib from "gi://GLib?version=2.0";

const JQUAKE_CLASS = "net-jquake-app-Main";
const UNITS = [
    "jquake.service",
    "stalonetray-jquake.service",
    "jquake-hypr-alert.service",
];

@register({ GTypeName: "ClshJQuake" })
class JQuakeMonitor extends GObject.Object {
    private static instance: JQuakeMonitor | null = null;

    #pollId: number | null = null;
    #unitStates: [string, string, string] = ["unknown", "unknown", "unknown"];
    #isOpen = false;
    #refreshing = false;

    @property(String)
    state = "active";

    @property(String)
    iconName = "weather-storm-symbolic";

    @property(String)
    cssClass = "jquake active";

    @property(String)
    tooltip = "JQuake: 状態確認中…\n\n左クリックで表示/非表示\n右クリックで管理メニュー";

    constructor() {
        super();

        this.#updateOpenFromCompositor();
        try {
            const comp = Compositor.getDefault();
            comp.connect("client-added", () => this.#updateOpenFromCompositor());
            comp.connect("client-removed", () => this.#updateOpenFromCompositor());
        } catch (err) {
            console.warn("JQuakeMonitor failed to bind Compositor:", err);
        }

        this.refreshUnits();

        this.#pollId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 10, () => {
            this.#updateOpenFromCompositor();
            this.refreshUnits();
            return GLib.SOURCE_CONTINUE;
        });
    }

    public static getDefault(): JQuakeMonitor {
        if (!this.instance) {
            this.instance = new JQuakeMonitor();
        }
        return this.instance;
    }

    #updateOpenFromCompositor(): void {
        try {
            const clients = Compositor.getDefault().clients || [];
            this.#isOpen = clients.some((c) => c?.class === JQUAKE_CLASS);
        } catch {
            this.#isOpen = false;
        }
        this.#syncPresentation();
    }

    #syncPresentation(): void {
        const [jqS, stS, alS] = this.#unitStates;
        if (jqS === "failed" || stS === "failed" || alS === "failed") {
            this.state = "failed";
            this.iconName = "dialog-warning-symbolic";
            this.cssClass = "jquake failed";
            this.tooltip = [
                "✗ JQuake: 異常停止",
                `jquake=${jqS} tray=${stS} alert=${alS}`,
                "",
                "左クリックで起動・表示/非表示",
                "右クリックで管理メニュー",
            ].join("\n");
            return;
        }

        if (jqS === "active" && stS === "active" && alS === "active") {
            if (this.#isOpen) {
                this.state = "open";
                this.iconName = "weather-severe-alert-symbolic";
                this.cssClass = "jquake open";
                this.tooltip = "JQuake: 表示中\n\n左クリックで非表示（トレイへ）\n右クリックで管理メニュー";
            } else {
                this.state = "active";
                this.iconName = "weather-storm-symbolic";
                this.cssClass = "jquake active";
                this.tooltip = "JQuake: 待機中（強震モニタ・EEW 監視）\n\n左クリックで表示/非表示\n右クリックで管理メニュー";
            }
            return;
        }

        this.state = "degraded";
        this.iconName = "weather-storm-symbolic";
        this.cssClass = "jquake degraded";
        this.tooltip = [
            "! JQuake: 停止中",
            `jquake=${jqS} tray=${stS} alert=${alS}`,
            "",
            "左クリックで起動・表示/非表示",
            "右クリックで管理メニュー",
        ].join("\n");
    }

    public refreshUnits(): void {
        if (this.#refreshing) {
            return;
        }
        this.#refreshing = true;

        execAsync(["systemctl", "--user", "show", "-p", "ActiveState", "--value", ...UNITS])
            .then((out) => {
                const lines = out.split("\n").map((s) => s.trim()).filter(Boolean);
                this.#unitStates = UNITS.map((_, idx) => lines[idx] || "unknown");
            })
            .catch(() => {
                this.#unitStates = UNITS.map(() => "unknown");
            })
            .finally(() => {
                this.#refreshing = false;
                this.#syncPresentation();
            });
    }

    public toggleWindow(): void {
        const cmd = GLib.getenv("COLORSHELL_JQUAKE_TOGGLE_CMD") || "jquake-toggle";
        execAsync([cmd])
            .catch((err) => console.warn("jquake-toggle failed:", err))
            .finally(() => {
                this.#updateOpenFromCompositor();
                this.refreshUnits();
            });
    }

    public openMenu(): void {
        const cmd = GLib.getenv("COLORSHELL_JQUAKE_MENU_CMD") || "jquake-menu";
        execApp(cmd);
        GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 2, () => {
            this.refreshUnits();
            return GLib.SOURCE_REMOVE;
        });
    }
}

export default JQuakeMonitor;
