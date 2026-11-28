import { createBinding } from "ags";
import { Gdk, Gtk } from "ags/gtk4";
import ServicesMonitor from "../../../modules/services";
import { openControlCenterPage } from "../../../modules/cc-nav";

export const Services = () => {
    const svc = ServicesMonitor.getDefault();

    return (
        <Gtk.Button
            class={createBinding(svc, "cssClass")}
            tooltipText={createBinding(svc, "tooltip")}
            onClicked={() => openControlCenterPage("services")}
            $={(self) => {
                const rightClick = Gtk.GestureClick.new();
                rightClick.set_button(Gdk.BUTTON_SECONDARY);
                const sigId = rightClick.connect("released", () => {
                    svc.openRofiMenu();
                });
                self.add_controller(rightClick);
                self.connect("destroy", () => {
                    rightClick.disconnect(sigId);
                });
            }}
        >
            <Gtk.Box
                orientation={Gtk.Orientation.VERTICAL}
                spacing={3}
                halign={Gtk.Align.CENTER}
                valign={Gtk.Align.CENTER}
            >
                <Gtk.Image iconName="network-server-symbolic" />
                <Gtk.Box
                    class="svc-dots-grid"
                    orientation={Gtk.Orientation.VERTICAL}
                    spacing={2}
                    halign={Gtk.Align.CENTER}
                    valign={Gtk.Align.CENTER}
                >
                    <Gtk.Box spacing={2}>
                        <Gtk.Box class={createBinding(svc, "dot0Class")} />
                        <Gtk.Box class={createBinding(svc, "dot1Class")} />
                        <Gtk.Box class={createBinding(svc, "dot2Class")} />
                    </Gtk.Box>
                    <Gtk.Box spacing={2}>
                        <Gtk.Box class={createBinding(svc, "dot3Class")} />
                        <Gtk.Box class={createBinding(svc, "dot4Class")} />
                        <Gtk.Box class={createBinding(svc, "dot5Class")} />
                    </Gtk.Box>
                </Gtk.Box>
            </Gtk.Box>
        </Gtk.Button>
    );
};
