import { createBinding } from "ags";
import { Gdk, Gtk } from "ags/gtk4";
import ResticBackupModule from "../../../modules/restic";
import { openControlCenterPage } from "../../../modules/cc-nav";

export const ResticBackup = () => {
    const restic = ResticBackupModule.getDefault();

    return (
        <Gtk.Button
            visible={createBinding(restic, "active")}
            class={createBinding(restic, "cssClass")}
            tooltipText={createBinding(restic, "tooltip")}
            onClicked={() => restic.openLog()}
            $={(self) => {
                const rightClick = Gtk.GestureClick.new();
                rightClick.set_button(Gdk.BUTTON_SECONDARY);
                const sigId = rightClick.connect("released", () => {
                    openControlCenterPage("services");
                });
                self.add_controller(rightClick);
                self.connect("destroy", () => {
                    rightClick.disconnect(sigId);
                });
            }}
        >
            <Gtk.Box spacing={5} halign={Gtk.Align.CENTER} valign={Gtk.Align.CENTER}>
                <Gtk.Image iconName={createBinding(restic, "iconName")} />
                <Gtk.Label class="restic-label number" label={createBinding(restic, "text")} />
            </Gtk.Box>
        </Gtk.Button>
    );
};
