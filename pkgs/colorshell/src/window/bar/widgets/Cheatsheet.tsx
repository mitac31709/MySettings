import { Gtk } from "ags/gtk4";
import { openCheatsheet } from "../../../modules/sysstats";

export const Cheatsheet = () => (
    <Gtk.Button
        class="cheatsheet"
        iconName="help-about-symbolic"
        halign={Gtk.Align.CENTER}
        tooltipText="チートシートを開く (Super+/)"
        onClicked={() => openCheatsheet()}
    />
);
