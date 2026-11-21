import GObject, { property, register } from "ags/gobject";
import { execAsync } from "ags/process";
import { execApp } from "./apps";
import { decoder } from "./utils";
import GLib from "gi://GLib?version=2.0";
import Gio from "gi://Gio?version=2.0";

const STATUS_FILENAME = "flake-update-status";

interface StatusPayload {
    text?: string;
    class?: string;
    tooltip?: string;
    count?: number;
    fetch_ok?: boolean;
    items?: Array<string>;
}

@register({ GTypeName: "ClshFlakeUpdates" })
class FlakeUpdates extends GObject.Object {
    private static instance: FlakeUpdates | null = null;

    #statusPath: string;
    #monitor: Gio.FileMonitor | null = null;
    #pollId: number | null = null;

    @property(Boolean)
    available = false;

    @property(Boolean)
    checking = false;

    @property(Number)
    count = 0;

    @property(String)
    label = "";

    @property(String)
    iconName = "view-refresh-symbolic";

    @property(String)
    cssClass = "updates idle";

    @property(String)
    tooltip = "更新チェック待ち\n左クリックで flake-update / 右クリックで今すぐ確認";

    constructor() {
        super();
        const runtimeRoot = GLib.get_user_runtime_dir() || "/tmp";
        this.#statusPath = `${runtimeRoot}/${STATUS_FILENAME}`;

        this.refresh();

        try {
            const dir = Gio.File.new_for_path(runtimeRoot);
            this.#monitor = dir.monitor_directory(Gio.FileMonitorFlags.NONE, null);
            this.#monitor.connect("changed", (_mon, file, otherFile) => {
                const name1 = file?.get_basename();
                const name2 = otherFile?.get_basename();
                if (name1 === STATUS_FILENAME || name2 === STATUS_FILENAME) {
                    this.refresh();
                }
            });
        } catch (err) {
            console.warn("Failed to watch flake-update-status:", err);
        }

        this.#pollId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 60, () => {
            this.refresh();
            return GLib.SOURCE_CONTINUE;
        });
    }

    public static getDefault(): FlakeUpdates {
        if (!this.instance) {
            this.instance = new FlakeUpdates();
        }
        return this.instance;
    }

    #syncPresentation(): void {
        if (this.checking) {
            this.iconName = "view-refresh-symbolic";
            this.label = "…";
            this.cssClass = "updates checking";
            return;
        }
        if (this.available) {
            this.iconName = "software-update-available-symbolic";
            this.label = this.count > 0 ? `${this.count}` : "!";
            this.cssClass = "updates available";
        } else {
            this.iconName = "view-refresh-symbolic";
            this.label = "";
            this.cssClass = "updates idle";
        }
    }

    public refresh(): void {
        if (!GLib.file_test(this.#statusPath, GLib.FileTest.EXISTS)) {
            this.available = false;
            this.count = 0;
            this.tooltip = "更新チェック待ち\n左クリックで flake-update / 右クリックで今すぐ確認";
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
            const parsed = JSON.parse(raw) as StatusPayload;
            const isAvailable = parsed.class === "available";
            let count = typeof parsed.count === "number" ? parsed.count : 0;
            if (isAvailable && count <= 0) {
                if (Array.isArray(parsed.items) && parsed.items.length > 0) {
                    count = parsed.items.length;
                } else if (typeof parsed.tooltip === "string") {
                    count = parsed.tooltip
                        .split("\n\n")[0]
                        .split("\n")
                        .filter((l) => l.trim().length > 0).length;
                }
            }

            this.available = isAvailable;
            this.count = isAvailable ? count : 0;
            this.tooltip = parsed.tooltip
                || (isAvailable
                    ? `更新が ${this.count} 件あります\n左クリックで flake-update / 右クリックで再確認`
                    : "更新なし\n左クリックで flake-update / 右クリックで再確認");
            this.#syncPresentation();
        } catch (err) {
            console.warn("Failed to parse flake-update-status:", err);
        }
    }

    public openFlakeUpdate(): void {
        const cmd = GLib.getenv("COLORSHELL_FLAKE_UPDATE_CMD") || "open-flake-update";
        execApp(cmd);
    }

    public checkNow(): void {
        if (this.checking) {
            return;
        }
        this.checking = true;
        this.#syncPresentation();

        const cmd = GLib.getenv("COLORSHELL_FLAKE_UPDATE_CHECK_CMD") || "flake-update-check";
        execAsync([cmd])
            .catch((err) => {
                console.warn("flake-update-check failed:", err);
            })
            .finally(() => {
                this.checking = false;
                this.refresh();
            });
    }
}

export default FlakeUpdates;
