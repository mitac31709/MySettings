import { createBinding, createComputed } from "ags";
import { Gdk, Gtk } from "ags/gtk4";
import KeepAwakeModule from "../../../modules/keep-awake";
import { openControlCenterPage } from "../../../modules/cc-nav";

export const KeepAwake = () => {
    const ka = KeepAwakeModule.getDefault();

    const visible = createComputed(
        [
            createBinding(ka, "showBarIcon"),
            createBinding(ka, "awakeOn"),
            createBinding(ka, "statusError"),
        ],
        (show, on, err) => show || on || err,
    );

    return (
        <Gtk.Button
            visible={visible}
            class={createBinding(ka, "cssClass")}
            tooltipText={createBinding(ka, "tooltip")}
            onClicked={() => ka.toggle()}
            $={(self) => {
                const rightClick = Gtk.GestureClick.new();
                rightClick.set_button(Gdk.BUTTON_SECONDARY);
                const rSig = rightClick.connect("released", () => {
                    openControlCenterPage("keep-awake");
                });
                self.add_controller(rightClick);

                const middleClick = Gtk.GestureClick.new();
                middleClick.set_button(Gdk.BUTTON_MIDDLE);
                const mSig = middleClick.connect("released", () => {
                    ka.openSettings();
                });
                self.add_controller(middleClick);

                self.connect("destroy", () => {
                    rightClick.disconnect(rSig);
                    middleClick.disconnect(mSig);
                });
            }}
        >
            <Gtk.Box spacing={5} halign={Gtk.Align.CENTER} valign={Gtk.Align.CENTER}>
                <Gtk.Image iconName={createBinding(ka, "iconName")} />
                <Gtk.Box
                    class={createBinding(ka, "dotClass")}
                    valign={Gtk.Align.CENTER}
                    halign={Gtk.Align.CENTER}
                />
                <Gtk.Label
                    class="ka-label number"
                    visible={createBinding(ka, "barLabel").as((s) => s.length > 0)}
                    label={createBinding(ka, "barLabel")}
                />
            </Gtk.Box>
        </Gtk.Button>
    );
};
