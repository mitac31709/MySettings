import { Gdk, Gtk } from "ags/gtk4";
import Windows from "../../../window";
import { createBinding } from "ags";
import { time } from "../../../modules/utils";
import { generalConfig } from "../../../config";
import { getWorldClockSnapshot, triggerNtpSync } from "../../../modules/worldclock";

export const Clock = () => (
    <Gtk.Button
        class={createBinding(Windows.getDefault(), "openWindows").as(
            (wins) => `clock number ${wins.includes("center-window") ? "open" : ""}`,
        )}
        tooltipText={time((dt) => getWorldClockSnapshot(dt).tooltip)}
        onClicked={() => Windows.getDefault().toggle("center-window")}
        label={time(
            (dt) =>
                dt.format(generalConfig.getProperty("clock.date_format", "string"))
                ?? "An error occurred",
        )}
        $={(self) => {
            const rightClick = Gtk.GestureClick.new();
            rightClick.set_button(Gdk.BUTTON_SECONDARY);
            const sigId = rightClick.connect("released", () => {
                triggerNtpSync();
            });
            self.add_controller(rightClick);
            self.connect("destroy", () => {
                rightClick.disconnect(sigId);
            });
        }}
    />
);
