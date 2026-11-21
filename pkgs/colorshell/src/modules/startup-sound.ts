import GObject, { property, register } from "ags/gobject";
import { execAsync } from "ags/process";
import { execApp } from "./apps";
import GLib from "gi://GLib?version=2.0";
import Gio from "gi://Gio?version=2.0";

interface StartupSoundPayload {
    text?: string;
    tooltip?: string;
    class?: string;
}

@register({ GTypeName: "ClshStartupSound" })
class StartupSoundMonitor extends GObject.Object {
    private static instance: StartupSoundMonitor | null = null;

    #stateMonitor: Gio.FileMonitor | null = null;
    #localMonitor: Gio.FileMonitor | null = null;
    #pollId: number | null = null;
    #refreshing = false;

    @property(String)
    state = "enabled";

    @property(String)
    iconName = "audio-x-generic-symbolic";

    @property(String)
    cssClass = "startup-sound enabled";

    @property(String)
    tooltip = "起動音: 確認中…\n\n左クリック: 一覧・編集・ON/OFF・再生\n右クリック: 全体 ON/OFF\n中クリック: ランダム再生";

    constructor() {
        super();
        const stateBase = GLib.getenv("XDG_STATE_HOME") || `${GLib.get_home_dir()}/.local/state`;
        const dataBase = GLib.getenv("XDG_DATA_HOME") || `${GLib.get_home_dir()}/.local/share`;
        const stateDir = `${stateBase}/startup-sound`;
        const localDir = `${dataBase}/startup-sounds`;

        this.refresh();

        try {
            GLib.mkdir_with_parents(stateDir, 0o755);
            const dir = Gio.File.new_for_path(stateDir);
            this.#stateMonitor = dir.monitor_directory(Gio.FileMonitorFlags.NONE, null);
            this.#stateMonitor.connect("changed", () => this.refresh());
        } catch (err) {
            console.warn("Failed to watch startup-sound state dir:", err);
        }

        if (GLib.file_test(localDir, GLib.FileTest.IS_DIR)) {
            try {
                const dir = Gio.File.new_for_path(localDir);
                this.#localMonitor = dir.monitor_directory(Gio.FileMonitorFlags.NONE, null);
                this.#localMonitor.connect("changed", () => this.refresh());
            } catch (err) {
                console.warn("Failed to watch startup-sounds local dir:", err);
            }
        }

        this.#pollId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 60, () => {
            this.refresh();
            return GLib.SOURCE_CONTINUE;
        });
    }

    public static getDefault(): StartupSoundMonitor {
        if (!this.instance) {
            this.instance = new StartupSoundMonitor();
        }
        return this.instance;
    }

    #bin(): string {
        return GLib.getenv("COLORSHELL_STARTUP_SOUND_CMD") || "startup-sound";
    }

    public refresh(): void {
        if (this.#refreshing) {
            return;
        }
        this.#refreshing = true;

        execAsync([this.#bin(), "--waybar"])
            .then((out) => {
                const raw = out.trim();
                if (!raw) return;
                const parsed = JSON.parse(raw) as StartupSoundPayload;
                const cls = parsed.class || "enabled";
                this.state = cls;
                this.cssClass = `startup-sound ${cls}`;
                this.iconName = cls === "disabled"
                    ? "audio-volume-muted-symbolic"
                    : "audio-x-generic-symbolic";
                if (parsed.tooltip) {
                    this.tooltip = parsed.tooltip;
                }
            })
            .catch((err) => {
                console.warn("startup-sound --waybar failed:", err);
            })
            .finally(() => {
                this.#refreshing = false;
            });
    }

    public openMenu(): void {
        execApp(`${this.#bin()} --menu`);
    }

    public toggleGlobal(): void {
        execAsync([this.#bin(), "--toggle-and-notify"])
            .catch((err) => console.warn("startup-sound --toggle-and-notify failed:", err))
            .finally(() => this.refresh());
    }

    public playRandom(): void {
        execAsync([this.#bin(), "--play-bg"])
            .catch((err) => console.warn("startup-sound --play-bg failed:", err))
            .finally(() => this.refresh());
    }
}

export default StartupSoundMonitor;
