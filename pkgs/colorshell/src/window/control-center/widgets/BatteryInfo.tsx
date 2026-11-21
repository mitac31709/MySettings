import { Gtk } from "ags/gtk4";
import { sysfsBattery } from "../../../modules/sysfs-battery";

export const BatteryInfo = () => (
    <Gtk.Box
        class={sysfsBattery((b) =>
            `battery-info-card${b.gaugeAnomaly ? " anomaly" : b.cssClass.includes("critical") ? " critical" : b.cssClass.includes("warning") ? " warning" : ""}`,
        )}
        orientation={Gtk.Orientation.VERTICAL}
        spacing={4}
        visible={sysfsBattery((b) => b.present)}
    >
        <Gtk.Box spacing={6}>
            <Gtk.Image iconName={sysfsBattery((b) => b.iconName)} />
            <Gtk.Label
                class="headline"
                xalign={0}
                hexpand
                label={sysfsBattery((b) => b.headline)}
            />
        </Gtk.Box>
        <Gtk.Label
            class="detail number"
            xalign={0}
            wrap
            visible={sysfsBattery((b) => b.powerLine.length > 0)}
            label={sysfsBattery((b) => b.powerLine)}
        />
        <Gtk.Label
            class="detail number"
            xalign={0}
            wrap
            visible={sysfsBattery((b) => b.capacityLine.length > 0)}
            label={sysfsBattery((b) => b.capacityLine)}
        />
        <Gtk.Label
            class="detail number"
            xalign={0}
            wrap
            visible={sysfsBattery((b) => b.voltageLine.length > 0)}
            label={sysfsBattery((b) => b.voltageLine)}
        />
        <Gtk.Label
            class="note"
            xalign={0}
            wrap
            visible={sysfsBattery((b) => b.noteLine.length > 0)}
            label={sysfsBattery((b) => b.noteLine)}
        />
    </Gtk.Box>
);
