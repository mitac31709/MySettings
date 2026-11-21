import GObject, { property, register } from "ags/gobject";
import { execApp } from "./apps";
import { decoder } from "./utils";
import GLib from "gi://GLib?version=2.0";
import Gio from "gi://Gio?version=2.0";

const STATUS_FILENAME = "restic-home-status";

interface ResticStatusPayload {
    text?: string;
    tooltip?: string;
    class?: string;
}

@register({ GTypeName: "ClshResticBackup" })
class ResticBackup extends GObject.Object {
    private static instance: ResticBackup | null = null;

    #statusPath: string;
    #monitor: Gio.FileMonitor | null = null;
    #pollId: number | null = null;

    @property(Boolean)
    active = false;

    @property(String)
    text = "";

    @property(String)
    tooltip = "";

    @property(String)
    cssClass = "restic-backup";

    @property(String)
    iconName = "drive-harddisk-symbolic";

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
                if (n1 === STATUS_FILENAME || n2 === STATUS_FILENAME) {
                    this.refresh();
                }
            });
        } catch (err) {
            console.warn("Failed to watch restic-home-status:", err);
        }

        this.#pollId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 15, () => {
            this.refresh();
            return GLib.SOURCE_CONTINUE;
        });
    }

    public static getDefault(): ResticBackup {
        if (!this.instance) {
            this.instance = new ResticBackup();
        }
        return this.instance;
    }

    public refresh(): void {
        if (!GLib.file_test(this.#statusPath, GLib.FileTest.EXISTS)) {
            this.active = false;
            this.text = "";
            this.tooltip = "";
            this.cssClass = "restic-backup";
            return;
        }

        try {
            const [ok, bytes] = GLib.file_get_contents(this.#statusPath);
            if (!ok) {
                return;
            }
            const raw = decoder.decode(bytes).trim();
            if (!raw) {
                this.active = false;
                this.text = "";
                return;
            }
            const parsed = JSON.parse(raw) as ResticStatusPayload;
            const cls = parsed.class || "running";
            const text = (parsed.text || "バックアップ中").trim();
            const tip = parsed.tooltip || text;

            this.active = true;
            this.text = text;
            this.tooltip = `${tip}\n\n左クリック: ログ表示 / 右クリック: サービス管理`;
            this.cssClass = `restic-backup ${cls}`;
            this.iconName = cls === "failed"
                ? "dialog-error-symbolic"
                : "drive-harddisk-symbolic";
        } catch (err) {
            console.warn("Failed to parse restic-home-status:", err);
        }
    }

    public openLog(): void {
        const ghostty = GLib.getenv("COLORSHELL_GHOSTTY_CMD") || "ghostty";
        execApp(`${ghostty} -e bash -lc "backup log; printf '\\n[Enter で閉じる] '; IFS= read -r _ || true"`);
    }

    public openStatus(): void {
        const ghostty = GLib.getenv("COLORSHELL_GHOSTTY_CMD") || "ghostty";
        execApp(`${ghostty} -e bash -lc "backup status; printf '\\n[Enter で閉じる] '; IFS= read -r _ || true"`);
    }
}

export default ResticBackup;
