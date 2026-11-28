import { createBinding } from "ags";
import { Gdk, Gtk } from "ags/gtk4";
import ServicesMonitor, { SERVICE_DEFS, ServiceDef, ServiceItem } from "../../../modules/services";
import { openControlCenterPage } from "../../../modules/cc-nav";

function formatServiceTooltip(def: ServiceDef, item?: ServiceItem): string {
    if (!item) {
        return `${def.name}\n状態を確認中…`;
    }
    const hint = item.extraLabel
        ? `左クリック: 管理 / 中クリック: ${item.extraLabel} / 右クリック: Rofi メニュー`
        : "左クリック: 管理 / 右クリック: Rofi メニュー";
    return `${item.name}\n状態: ${item.statusText}\n${hint}`;
}

function ServiceIconButton({ def, svc }: { def: ServiceDef; svc: ServicesMonitor }) {
    const itemBinding = createBinding(svc, "items").as((items) =>
        items.find((it) => it.id === def.id),
    );

    return (
        <Gtk.Button
            class={itemBinding.as((it) => `service-item ${it ? it.level : "active"}`)}
            tooltipText={itemBinding.as((it) => formatServiceTooltip(def, it))}
            onClicked={() => openControlCenterPage("services")}
            $={(self) => {
                const rightClick = Gtk.GestureClick.new();
                rightClick.set_button(Gdk.BUTTON_SECONDARY);
                const rSig = rightClick.connect("released", () => {
                    svc.openRofiMenu();
                });
                self.add_controller(rightClick);

                const middleClick = Gtk.GestureClick.new();
                middleClick.set_button(Gdk.BUTTON_MIDDLE);
                const mSig = middleClick.connect("released", () => {
                    const current = svc.items.find((it) => it.id === def.id);
                    current?.extraAction?.();
                });
                self.add_controller(middleClick);

                self.connect("destroy", () => {
                    rightClick.disconnect(rSig);
                    middleClick.disconnect(mSig);
                });
            }}
        >
            <Gtk.Box
                orientation={Gtk.Orientation.HORIZONTAL}
                spacing={3}
                halign={Gtk.Align.CENTER}
                valign={Gtk.Align.CENTER}
            >
                <Gtk.Image iconName={def.iconName} />
                <Gtk.Box
                    class={itemBinding.as((it) => `svc-dot ${it ? it.level : "active"}`)}
                    valign={Gtk.Align.CENTER}
                />
            </Gtk.Box>
        </Gtk.Button>
    );
}

export const Services = () => {
    const svc = ServicesMonitor.getDefault();

    return (
        <Gtk.Box
            class="services-list transparent"
            orientation={Gtk.Orientation.VERTICAL}
            spacing={4}
            halign={Gtk.Align.FILL}
        >
            {SERVICE_DEFS.map((def) => (
                <ServiceIconButton def={def} svc={svc} />
            ))}
        </Gtk.Box>
    );
};
