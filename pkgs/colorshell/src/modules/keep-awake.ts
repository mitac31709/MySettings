import GObject, { property, register } from "ags/gobject";
import { execAsync } from "ags/process";
import { execApp } from "./apps";
import { decoder } from "./utils";
import GLib from "gi://GLib?version=2.0";
import Gio from "gi://Gio?version=2.0";

const CAPS_DIRNAME = "capsomnia";
const STATUS_FILENAME = "waybar.json";

export const AUTO_OFF_PRESETS: ReadonlyArray<{ minutes: number; label: string }> = [
    { minutes: 0, label: "∞" },
    { minutes: 15, label: "15m" },
    { minutes: 30, label: "30m" },
    { minutes: 60, label: "1h" },
    { minutes: 120, label: "2h" },
    { minutes: 240, label: "4h" },
    { minutes: 480, label: "8h" },
];

interface CapsStatusPayload {
    text?: string;
    tooltip?: string;
    class?: string;
    awake_on?: boolean;
    sleep_inhibited?: boolean;
    status_error?: boolean;
    error_message?: string | null;
    lid_closed?: boolean | null;
    hotspot_active?: boolean;
    timer?: {
        active?: boolean;
        saved_default_minutes?: number;
        one_shot?: boolean;
        duration_seconds?: number | null;
        remaining_seconds?: number | null;
        remaining_formatted?: string | null;
    };
    settings?: {
        dedicated_caps_lock_mode?: boolean;
        show_menu_bar_icon?: boolean;
        keep_display_awake?: boolean;
        lock_on_lid_open?: boolean;
        keep_hotspot_alive?: boolean;
        auto_off_minutes?: number;
        shortcut?: string;
    };
}

@register({ GTypeName: "ClshKeepAwake" })
class KeepAwake extends GObject.Object {
    private static instance: KeepAwake | null = null;

    #capsDir: string;
    #statusPath: string;
    #capsMonitor: Gio.FileMonitor | null = null;
    #runtimeMonitor: Gio.FileMonitor | null = null;
    #pollId: number | null = null;
    #busy = false;

    @property(Boolean)
    awakeOn = false;

    @property(Boolean)
    sleepInhibited = false;

    @property(Boolean)
    statusError = false;

    @property(String)
    errorMessage = "";

    @property(String)
    lidLabel = "不明";

    @property(Boolean)
    timerActive = false;

    @property(String)
    remainingFormatted = "";

    @property(Number)
    savedDefaultMinutes = 0;

    @property(Boolean)
    dedicatedCapsLock = true;

    @property(Boolean)
    keepDisplayAwake = true;

    @property(Boolean)
    lockOnLidOpen = false;

    @property(Boolean)
    keepHotspotAlive = false;

    @property(Boolean)
    showBarIcon = true;

    @property(String)
    shortcut = "SUPER + ALT + C";

    @property(String)
    barLabel = "";

    @property(String)
    iconName = "video-display-symbolic";

    @property(String)
    cssClass = "keep-awake off";

    @property(String)
    dotClass = "led-dot off";

    @property(String)
    tileDescription = "無効";

    @property(String)
    tooltip = "画面常時オン (Capsomnia): OFF\n左クリック: ON/OFF 切替 / 右クリック: コントロールセンター / 中クリック: 詳細設定";

    constructor() {
        super();
        const runtimeRoot = GLib.get_user_runtime_dir() || "/tmp";
        this.#capsDir = `${runtimeRoot}/${CAPS_DIRNAME}`;
        this.#statusPath = `${this.#capsDir}/${STATUS_FILENAME}`;

        this.refresh();
        this.#attachCapsMonitor();

        try {
            const rtDir = Gio.File.new_for_path(runtimeRoot);
            this.#runtimeMonitor = rtDir.monitor_directory(Gio.FileMonitorFlags.NONE, null);
            this.#runtimeMonitor.connect("changed", (_mon, file, otherFile) => {
                const n1 = file?.get_basename();
                const n2 = otherFile?.get_basename();
                if (n1 === CAPS_DIRNAME || n2 === CAPS_DIRNAME) {
                    this.#attachCapsMonitor();
                    this.refresh();
                }
            });
        } catch (err) {
            console.warn("Failed to watch runtime dir for capsomnia:", err);
        }

        // Light fallback poll so initial daemon startup or missed rename events converge.
        this.#pollId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 5, () => {
            if (!this.#capsMonitor) {
                this.#attachCapsMonitor();
            }
            this.refresh();
            return GLib.SOURCE_CONTINUE;
        });
    }

    public static getDefault(): KeepAwake {
        if (!this.instance) {
            this.instance = new KeepAwake();
        }
        return this.instance;
    }

    #attachCapsMonitor(): void {
        if (this.#capsMonitor || !GLib.file_test(this.#capsDir, GLib.FileTest.IS_DIR)) {
            return;
        }
        try {
            const dir = Gio.File.new_for_path(this.#capsDir);
            this.#capsMonitor = dir.monitor_directory(Gio.FileMonitorFlags.NONE, null);
            this.#capsMonitor.connect("changed", (_mon, file, otherFile) => {
                const n1 = file?.get_basename();
                const n2 = otherFile?.get_basename();
                if (n1 === STATUS_FILENAME || n2 === STATUS_FILENAME) {
                    this.refresh();
                }
            });
        } catch (err) {
            console.warn("Failed to watch capsomnia status dir:", err);
        }
    }

    #cpsmBin(): string {
        return GLib.getenv("COLORSHELL_CAPS_CMD") || "cpsm";
    }

    #syncPresentation(rawTooltip?: string): void {
        if (this.statusError) {
            this.iconName = "dialog-error-symbolic";
            this.cssClass = "keep-awake error";
            this.dotClass = "led-dot error";
            this.barLabel = "ERR";
            this.tileDescription = "エラー";
        } else if (this.awakeOn) {
            this.iconName = "video-display-symbolic";
            this.cssClass = "keep-awake on";
            this.dotClass = "led-dot on";
            this.barLabel = this.timerActive && this.remainingFormatted
                ? this.remainingFormatted
                : "ON";
            this.tileDescription = this.timerActive && this.remainingFormatted
                ? `有効 · ${this.remainingFormatted}`
                : "有効";
        } else {
            this.iconName = "video-display-symbolic";
            this.cssClass = "keep-awake off";
            this.dotClass = "led-dot off";
            this.barLabel = "";
            this.tileDescription = "無効";
        }

        if (rawTooltip && rawTooltip.trim().length > 0) {
            this.tooltip = rawTooltip;
        } else {
            const stateStr = this.statusError ? "エラー" : (this.awakeOn ? "ON" : "OFF");
            this.tooltip = [
                `画面常時オン (Capsomnia): ${stateStr}`,
                `蓋閉じ処理継続: ${this.awakeOn ? "有効" : "通常（スリープ）"}`,
                `蓋の状態: ${this.lidLabel}`,
                "",
                "左クリック: ON/OFF 切替 / 右クリック: コントロールセンター / 中クリック: 詳細設定",
            ].join("\n");
        }
    }

    public refresh(): void {
        if (!GLib.file_test(this.#statusPath, GLib.FileTest.EXISTS)) {
            this.awakeOn = false;
            this.sleepInhibited = false;
            this.statusError = false;
            this.errorMessage = "";
            this.timerActive = false;
            this.remainingFormatted = "";
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
            const parsed = JSON.parse(raw) as CapsStatusPayload;
            const awake = typeof parsed.awake_on === "boolean"
                ? parsed.awake_on
                : parsed.class === "on";
            const err = typeof parsed.status_error === "boolean"
                ? parsed.status_error
                : parsed.class === "error";

            this.awakeOn = awake;
            this.sleepInhibited = Boolean(parsed.sleep_inhibited);
            this.statusError = err;
            this.errorMessage = parsed.error_message || "";
            this.lidLabel = parsed.lid_closed === true
                ? "閉"
                : (parsed.lid_closed === false ? "開" : "不明");

            const timer = parsed.timer;
            this.timerActive = Boolean(timer?.active);
            this.remainingFormatted = timer?.remaining_formatted || "";
            if (typeof timer?.saved_default_minutes === "number") {
                this.savedDefaultMinutes = timer.saved_default_minutes;
            }

            const s = parsed.settings;
            if (s) {
                if (typeof s.dedicated_caps_lock_mode === "boolean") {
                    this.dedicatedCapsLock = s.dedicated_caps_lock_mode;
                }
                if (typeof s.show_menu_bar_icon === "boolean") {
                    this.showBarIcon = s.show_menu_bar_icon;
                }
                if (typeof s.keep_display_awake === "boolean") {
                    this.keepDisplayAwake = s.keep_display_awake;
                }
                if (typeof s.lock_on_lid_open === "boolean") {
                    this.lockOnLidOpen = s.lock_on_lid_open;
                }
                if (typeof s.keep_hotspot_alive === "boolean") {
                    this.keepHotspotAlive = s.keep_hotspot_alive;
                }
                if (typeof s.auto_off_minutes === "number") {
                    this.savedDefaultMinutes = s.auto_off_minutes;
                }
                if (typeof s.shortcut === "string" && s.shortcut.length > 0) {
                    this.shortcut = s.shortcut;
                }
            }

            this.#syncPresentation(parsed.tooltip);
        } catch (err) {
            console.warn("Failed to parse capsomnia status:", err);
        }
    }

    #runCpsm(args: Array<string>): void {
        if (this.#busy) {
            return;
        }
        this.#busy = true;
        execAsync([this.#cpsmBin(), "--json", ...args])
            .catch((err) => {
                console.warn(`cpsm ${args.join(" ")} failed:`, err);
            })
            .finally(() => {
                this.#busy = false;
                this.refresh();
            });
    }

    public toggle(): void {
        this.#runCpsm(["toggle", "--no-sleep"]);
    }

    public turnOn(): void {
        this.#runCpsm(["on"]);
    }

    public turnOff(sleepNow = false): void {
        this.#runCpsm(sleepNow ? ["off"] : ["off", "--no-sleep"]);
    }

    public setSetting(key: string, value: string): void {
        this.#runCpsm(["settings", "set", key, value]);
    }

    public setAutoOffMinutes(minutes: number): void {
        this.setSetting("auto-off-minutes", `${minutes}`);
    }

    public restartTimer(): void {
        this.#runCpsm(["timer", "restart"]);
    }

    public cancelTimer(): void {
        this.#runCpsm(["timer", "cancel"]);
    }

    public openSettings(): void {
        const cmd = GLib.getenv("COLORSHELL_CAPS_SETTINGS_CMD") || "capsomnia-settings";
        execApp(cmd);
    }

    public openMenu(): void {
        const cmd = GLib.getenv("COLORSHELL_CAPS_MENU_CMD") || "capsomnia-menu";
        execApp(cmd);
    }
}

export default KeepAwake;
