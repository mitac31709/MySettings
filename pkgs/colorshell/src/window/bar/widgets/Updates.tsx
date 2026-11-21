import { createBinding } from "ags";
import { Gdk, Gtk } from "ags/gtk4";
import FlakeUpdates from "../../../modules/updates";

export const Updates = () => {
    const updates = FlakeUpdates.getDefault();

    return (
        <Gtk.Button
            class={createBinding(updates, "cssClass")}
            tooltipText={createBinding(updates, "tooltip")}
            onClicked={() => updates.openFlakeUpdate()}
            $={(self) => {
                const rightClick = Gtk.GestureClick.new();
                rightClick.set_button(Gdk.BUTTON_SECONDARY);
                const sigId = rightClick.connect("released", () => {
                    updates.checkNow();
                });
                self.add_controller(rightClick);
                self.connect("destroy", () => {
                    rightClick.disconnect(sigId);
                });
            }}
        >
            <Gtk.Box spacing={4} halign={Gtk.Align.CENTER} valign={Gtk.Align.CENTER}>
                <Gtk.Image iconName={createBinding(updates, "iconName")} />
                <Gtk.Label
                    class="count number"
                    visible={createBinding(updates, "label").as((s) => s.length > 0)}
                    label={createBinding(updates, "label")}
                />
            </Gtk.Box>
        </Gtk.Button>
    );
};
