import { createBinding } from "ags";
import { Gdk, Gtk } from "ags/gtk4";
import StartupSoundMonitor from "../../../modules/startup-sound";

export const StartupSound = () => {
    const ss = StartupSoundMonitor.getDefault();

    return (
        <Gtk.Button
            class={createBinding(ss, "cssClass")}
            tooltipText={createBinding(ss, "tooltip")}
            onClicked={() => ss.openMenu()}
            $={(self) => {
                const rightClick = Gtk.GestureClick.new();
                rightClick.set_button(Gdk.BUTTON_SECONDARY);
                const rSig = rightClick.connect("released", () => {
                    ss.toggleGlobal();
                });
                self.add_controller(rightClick);

                const middleClick = Gtk.GestureClick.new();
                middleClick.set_button(Gdk.BUTTON_MIDDLE);
                const mSig = middleClick.connect("released", () => {
                    ss.playRandom();
                });
                self.add_controller(middleClick);

                self.connect("destroy", () => {
                    rightClick.disconnect(rSig);
                    middleClick.disconnect(mSig);
                });
            }}
        >
            <Gtk.Image
                iconName={createBinding(ss, "iconName")}
                halign={Gtk.Align.CENTER}
                valign={Gtk.Align.CENTER}
            />
        </Gtk.Button>
    );
};
