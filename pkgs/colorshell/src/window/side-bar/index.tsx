import { Astal, Gtk } from "ags/gtk4";
import Windows from "..";
import { Tray } from "../bar/widgets/Tray";
import { Updates } from "../bar/widgets/Updates";
import { StartupSound } from "../bar/widgets/StartupSound";
import { JQuake } from "../bar/widgets/JQuake";
import { Services } from "../bar/widgets/Services";

export const SideBar = Windows.forMonitors(() => {
    const widgetSpacing = 4;

    return (
        <Astal.Window
            namespace={"side-bar"}
            layer={Astal.Layer.TOP}
            anchor={
                Astal.WindowAnchor.LEFT |
                Astal.WindowAnchor.TOP |
                Astal.WindowAnchor.BOTTOM
            }
            exclusivity={Astal.Exclusivity.EXCLUSIVE}
            widthRequest={80}
            canFocus={false}
        >
            <Gtk.Box
                class={"bar-container side-bar-container"}
                orientation={Gtk.Orientation.VERTICAL}
                hexpand
            >
                <Gtk.CenterBox
                    class={"side-bar-centerbox"}
                    orientation={Gtk.Orientation.VERTICAL}
                    hexpand
                    vexpand
                >
                    <Gtk.Box
                        class={"widgets-top"}
                        orientation={Gtk.Orientation.VERTICAL}
                        valign={Gtk.Align.START}
                        halign={Gtk.Align.FILL}
                        spacing={widgetSpacing}
                        $type="start"
                    >
                        <Updates />
                    </Gtk.Box>
                    <Gtk.Box
                        class={"widgets-bottom"}
                        orientation={Gtk.Orientation.VERTICAL}
                        valign={Gtk.Align.END}
                        halign={Gtk.Align.FILL}
                        spacing={widgetSpacing}
                        $type="end"
                    >
                        <StartupSound />
                        <JQuake />
                        <Services />
                        <Tray orientation={Gtk.Orientation.VERTICAL} />
                    </Gtk.Box>
                </Gtk.CenterBox>
            </Gtk.Box>
        </Astal.Window>
    );
});
