import { createBinding, createComputed } from "ags";
import { Gdk, Gtk } from "ags/gtk4";
import PowerSaveModule from "../../../modules/power-save";
import { openControlCenterPage } from "../../../modules/cc-nav";

export const PowerSave = () => {
    const ps = PowerSaveModule.getDefault();

    const visible = createComputed(
        [
            createBinding(ps, "showBarIcon"),
            createBinding(ps, "active"),
            createBinding(ps, "errorMessage"),
        ],
        (show, on, err) => show || on || err.length > 0,
    );

    return (
        <Gtk.Button
            visible={visible}
            class={createBinding(ps, "cssClass")}
            tooltipText={createBinding(ps, "tooltip")}
            onClicked={() => ps.toggle()}
            $={(self) => {
                const rightClick = Gtk.GestureClick.new();
                rightClick.set_button(Gdk.BUTTON_SECONDARY);
                const rSig = rightClick.connect("released", () => {
                    openControlCenterPage("power-save");
                });
                self.add_controller(rightClick);

                self.connect("destroy", () => {
                    rightClick.disconnect(rSig);
                });
            }}
        >
            <Gtk.Box spacing={5} halign={Gtk.Align.CENTER} valign={Gtk.Align.CENTER}>
                <Gtk.Image iconName={createBinding(ps, "iconName")} />
                <Gtk.Box
                    class={createBinding(ps, "dotClass")}
                    valign={Gtk.Align.CENTER}
                    halign={Gtk.Align.CENTER}
                />
                <Gtk.Label
                    class="ps-label number"
                    visible={createBinding(ps, "barLabel").as((s) => s.length > 0)}
                    label={createBinding(ps, "barLabel")}
                />
            </Gtk.Box>
        </Gtk.Button>
    );
};
