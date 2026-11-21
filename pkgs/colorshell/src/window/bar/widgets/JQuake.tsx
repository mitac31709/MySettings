import { createBinding } from "ags";
import { Gdk, Gtk } from "ags/gtk4";
import JQuakeMonitor from "../../../modules/jquake";

export const JQuake = () => {
    const jq = JQuakeMonitor.getDefault();

    return (
        <Gtk.Button
            class={createBinding(jq, "cssClass")}
            tooltipText={createBinding(jq, "tooltip")}
            onClicked={() => jq.openWindow()}
            $={(self) => {
                const rightClick = Gtk.GestureClick.new();
                rightClick.set_button(Gdk.BUTTON_SECONDARY);
                const sigId = rightClick.connect("released", () => {
                    jq.openMenu();
                });
                self.add_controller(rightClick);
                self.connect("destroy", () => {
                    rightClick.disconnect(sigId);
                });
            }}
        >
            <Gtk.Image
                iconName={createBinding(jq, "iconName")}
                halign={Gtk.Align.CENTER}
                valign={Gtk.Align.CENTER}
            />
        </Gtk.Button>
    );
};
