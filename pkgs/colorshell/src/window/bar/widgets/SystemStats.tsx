import { Gtk } from "ags/gtk4";
import { openBtop, sysStats } from "../../../modules/sysstats";

export const SystemStats = () => (
    <Gtk.Button
        class={sysStats((s) => s.cssClass)}
        tooltipText={sysStats((s) => s.tooltip)}
        onClicked={() => openBtop()}
    >
        <Gtk.Box spacing={4} halign={Gtk.Align.CENTER} valign={Gtk.Align.CENTER}>
            <Gtk.Image iconName="computer-symbolic" />
            <Gtk.Label class="stats-label number" label={sysStats((s) => s.label)} />
        </Gtk.Box>
    </Gtk.Button>
);
