import GObject, { property, register } from "ags/gobject";
import { execAsync } from "ags/process";
import { decoder } from "./utils";
import GLib from "gi://GLib?version=2.0";
import Gio from "gi://Gio?version=2.0";

const DIRNAME = "power-save";
const STATUS_FILENAME = "status.json";

export const BRIGHTNESS_CAP_PRESETS: ReadonlyArray<number> = [20, 30, 35, 40, 50];
export const LOW_BATTERY_PRESETS: ReadonlyArray<number> = [15, 20, 25, 30];

interface PowerSavePayload {
    active?: boolean;
    reason?: string;
    applied?: {
        cpu?: boolean;
        hyprland?: boolean;
        brightness?: boolean;
        bluetooth?: boolean;
        services?: boolean;
    };
    paused_services?: Array<string>;
    saved_brightness?: number | null;
    bt_powered_off?: boolean;
    error?: string | null;
    config?: {
        cpu?: boolean;
        hyprland?: boolean;
        brightness?: boolean;
        brightness_cap?: number;
        bluetooth?: boolean;
        services?: boolean;
        auto_on_low_battery?: boolean;
        low_battery_threshold?: number;
        auto_off_on_ac?: boolean;
        show_bar_icon?: boolean;
    };
    battery?: {
        present?: boolean;
        capacity?: number | null;
        status?: string;
        ac_online?: boolean;
    };
}

@register({ GTypeName: "ClshPowerSave" })
class PowerSave extends GObject.Object {
    private static instance: PowerSave | null = null;

    #dir: string;
    #statusPath: string;
    #dirMonitor: Gio.FileMonitor | null = null;
    #runtimeMonitor: Gio.FileMonitor | null = null;
    #pollId: number | null = null;
    #busy = false;

    @property(Boolean)
    active = false;

    @property(String)
    reason = "off";

    @property(String)
    errorMessage = "";

    @property(Boolean)
    cfgCpu = true;

    @property(Boolean)
    cfgHyprland = true;

    @property(Boolean)
    cfgBrightness = true;

    @property(Number)
    cfgBrightnessCap = 35;

    @property(Boolean)
    cfgBluetooth = true;

    @property(Boolean)
    cfgServices = true;

    @property(Boolean)
    cfgAutoOnLowBattery = true;

    @property(Number)
    cfgLowBatteryThreshold = 20;

    @property(Boolean)
    cfgAutoOffOnAc = true;

    @property(Boolean)
    showBarIcon = true;

    @property(String)
    appliedSummary = "";

    @property(String)
    iconName = "power-profile-power-saver-symbolic";

    @property(String)
    cssClass = "power-save off";

    @property(String)
    dotClass = "ps-dot off";

    @property(String)
    barLabel = "";

    @property(String)
    tileDescription = "無効";

    @property(String)
    tooltip = "省電力モード: OFF\n左クリック: ON/OFF 切替 / 右クリック: コントロールセンター";

    constructor() {
        super();
        const runtimeRoot = GLib.get_user_runtime_dir() || "/tmp";
        this.#dir = `${runtimeRoot}/${DIRNAME}`;
        this.#statusPath = `${this.#dir}/${STATUS_FILENAME}`;

        this.refresh();
        this.#attachDirMonitor();

        try {
            const rtDir = Gio.File.new_for_path(runtimeRoot);
            this.#runtimeMonitor = rtDir.monitor_directory(Gio.FileMonitorFlags.NONE, null);
            this.#runtimeMonitor.connect("changed", (_mon, file, otherFile) => {
                const n1 = file?.get_basename();
                const n2 = otherFile?.get_basename();
                if (n1 === DIRNAME || n2 === DIRNAME) {
                    this.#attachDirMonitor();
                    this.refresh();
                }
            });
        } catch (err) {
            console.warn("Failed to watch runtime dir for power-save:", err);
        }

        this.#pollId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 10, () => {
            if (!this.#dirMonitor) {
                this.#attachDirMonitor();
            }
            this.refresh();
            return GLib.SOURCE_CONTINUE;
        });
    }

    public static getDefault(): PowerSave {
        if (!this.instance) {
            this.instance = new PowerSave();
        }
        return this.instance;
    }

    #attachDirMonitor(): void {
        if (this.#dirMonitor || !GLib.file_test(this.#dir, GLib.FileTest.IS_DIR)) {
            return;
        }
        try {
            const dir = Gio.File.new_for_path(this.#dir);
            this.#dirMonitor = dir.monitor_directory(Gio.FileMonitorFlags.NONE, null);
            this.#dirMonitor.connect("changed", (_mon, file, otherFile) => {
                const n1 = file?.get_basename();
                const n2 = otherFile?.get_basename();
                if (n1 === STATUS_FILENAME || n2 === STATUS_FILENAME) {
                    this.refresh();
                }
            });
        } catch (err) {
            console.warn("Failed to watch power-save status dir:", err);
        }
    }

    #cmdBin(): string {
        return GLib.getenv("COLORSHELL_POWER_SAVE_CMD") || "power-save";
    }

    #syncPresentation(payload?: PowerSavePayload): void {
        const parts: Array<string> = [];
        if (this.active) {
            const ap = payload?.applied;
            if (ap?.cpu) parts.push("CPU省電力");
            if (ap?.hyprland) parts.push("描画軽量化");
            if (ap?.brightness && payload?.saved_brightness != null) {
                parts.push(`輝度${this.cfgBrightnessCap}%`);
            }
            if (ap?.bluetooth && payload?.bt_powered_off) parts.push("BTオフ");
            const paused = payload?.paused_services?.length ?? 0;
            if (ap?.services && paused > 0) parts.push(`裏方${paused}件停止`);
        }
        this.appliedSummary = parts.length > 0 ? parts.join(" · ") : "";

        if (this.errorMessage) {
            this.cssClass = this.active ? "power-save on error" : "power-save error";
            this.dotClass = "ps-dot error";
            this.barLabel = this.active ? "ECO" : "ERR";
            this.tileDescription = this.active ? "有効 (一部エラー)" : "エラー";
        } else if (this.active) {
            this.cssClass = "power-save on";
            this.dotClass = "ps-dot on";
            this.barLabel = "ECO";
            this.tileDescription = this.reason === "low-battery" ? "有効 · 自動" : "有効";
        } else {
            this.cssClass = "power-save off";
            this.dotClass = "ps-dot off";
            this.barLabel = "";
            this.tileDescription = this.cfgAutoOnLowBattery
                ? `無効 · ≤${this.cfgLowBatteryThreshold}%で自動`
                : "無効";
        }

        const lines: Array<string> = [
            `省電力モード: ${this.active ? (this.reason === "low-battery" ? "ON (バッテリー低下で自動)" : "ON") : "OFF"}`,
        ];
        if (this.active && this.appliedSummary) {
            lines.push(`適用中: ${this.appliedSummary}`);
        }
        lines.push(
            `自動切替: ≤${this.cfgLowBatteryThreshold}%でON=${this.cfgAutoOnLowBattery ? "有効" : "無効"} / AC接続でOFF=${this.cfgAutoOffOnAc ? "有効" : "無効"}`,
        );
        if (this.errorMessage) {
            lines.push(`エラー: ${this.errorMessage}`);
        }
        lines.push("", "左クリック: ON/OFF 切替 / 右クリック: コントロールセンター");
        this.tooltip = lines.join("\n");
    }

    public refresh(): void {
        if (!GLib.file_test(this.#statusPath, GLib.FileTest.EXISTS)) {
            this.active = false;
            this.reason = "off";
            this.errorMessage = "";
            this.#syncPresentation();
            return;
        }

        try {
            const [ok, bytes] = GLib.file_get_contents(this.#statusPath);
            if (!ok) {
                return;
            }
            const raw = decoder.decode(bytes).trim();
            if (!raw) {
                return;
            }
            const parsed = JSON.parse(raw) as PowerSavePayload;
            this.active = Boolean(parsed.active);
            this.reason = parsed.reason || (this.active ? "manual" : "off");
            this.errorMessage = parsed.error || "";

            const c = parsed.config;
            if (c) {
                if (typeof c.cpu === "boolean") this.cfgCpu = c.cpu;
                if (typeof c.hyprland === "boolean") this.cfgHyprland = c.hyprland;
                if (typeof c.brightness === "boolean") this.cfgBrightness = c.brightness;
                if (typeof c.brightness_cap === "number") this.cfgBrightnessCap = c.brightness_cap;
                if (typeof c.bluetooth === "boolean") this.cfgBluetooth = c.bluetooth;
                if (typeof c.services === "boolean") this.cfgServices = c.services;
                if (typeof c.auto_on_low_battery === "boolean") {
                    this.cfgAutoOnLowBattery = c.auto_on_low_battery;
                }
                if (typeof c.low_battery_threshold === "number") {
                    this.cfgLowBatteryThreshold = c.low_battery_threshold;
                }
                if (typeof c.auto_off_on_ac === "boolean") this.cfgAutoOffOnAc = c.auto_off_on_ac;
                if (typeof c.show_bar_icon === "boolean") this.showBarIcon = c.show_bar_icon;
            }

            this.#syncPresentation(parsed);
        } catch (err) {
            console.warn("Failed to parse power-save status:", err);
        }
    }

    #run(args: Array<string>): void {
        if (this.#busy) {
            return;
        }
        this.#busy = true;
        execAsync([this.#cmdBin(), "--json", ...args])
            .catch((err) => {
                console.warn(`power-save ${args.join(" ")} failed:`, err);
            })
            .finally(() => {
                this.#busy = false;
                this.refresh();
            });
    }

    public toggle(): void {
        this.#run(["toggle"]);
    }

    public turnOn(): void {
        this.#run(["on"]);
    }

    public turnOff(): void {
        this.#run(["off"]);
    }

    public setConfig(key: string, value: string): void {
        this.#run(["config", "set", key, value]);
    }
}

export default PowerSave;
