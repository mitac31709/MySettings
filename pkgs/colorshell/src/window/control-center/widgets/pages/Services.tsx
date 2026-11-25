import Page from "../Page";
import { Gtk } from "ags/gtk4";
import { createBinding, For } from "ags";
import ServicesMonitor, { ServiceItem } from "../../../../modules/services";
import Windows from "../../../../window";

function ServiceCard({ item, svc }: { item: ServiceItem; svc: ServicesMonitor }) {
    return (
        <Gtk.Box class={`svc-card ${item.level}`} orientation={Gtk.Orientation.VERTICAL} spacing={6} hexpand>
            <Gtk.Box spacing={8} hexpand>
                <Gtk.Box class={`svc-dot ${item.level}`} valign={Gtk.Align.CENTER} />
                <Gtk.Box orientation={Gtk.Orientation.VERTICAL} hexpand>
                    <Gtk.Label class="svc-name" label={item.name} xalign={0} />
                    <Gtk.Label class="svc-status" label={item.statusText} xalign={0} wrap />
                </Gtk.Box>
            </Gtk.Box>

            <Gtk.Box class="svc-actions" spacing={4} hexpand>
                {item.unitScope === "user" && (
                    <Gtk.Button
                        class="svc-btn"
                        label="再起動"
                        onClicked={() => svc.restartUserUnits(item.units)}
                    />
                )}
                {item.unitScope === "user" && item.canToggle && (
                    <Gtk.Button
                        class="svc-btn"
                        label={item.isActive ? "停止" : "開始"}
                        onClicked={() => svc.toggleUserUnit(item.units[0], item.isActive)}
                    />
                )}
                {item.id === "tailscale" && item.canToggle && (
                    <Gtk.Button
                        class="svc-btn"
                        label={item.isActive ? "切断" : "接続"}
                        onClicked={() => svc.toggleTailscale(item.isActive)}
                    />
                )}
                {item.id === "tailscale" && (
                    <Gtk.Button
                        class="svc-btn"
                        label="再起動 (sudo)"
                        onClicked={() => {
                            Windows.getDefault().close("control-center");
                            svc.restartTailscale();
                        }}
                    />
                )}
                {item.id === "restic" && (
                    <Gtk.Button
                        class="svc-btn"
                        label="今すぐ実行"
                        onClicked={() => {
                            Windows.getDefault().close("control-center");
                            svc.runBackupNow();
                        }}
                    />
                )}
                {item.extraLabel && item.extraAction && (
                    <Gtk.Button
                        class="svc-btn"
                        label={item.extraLabel}
                        onClicked={() => {
                            Windows.getDefault().close("control-center");
                            item.extraAction?.();
                        }}
                    />
                )}
            </Gtk.Box>
        </Gtk.Box>
    );
}

export const PageServices = () => {
    const svc = ServicesMonitor.getDefault();

    return (
        <Page
            id="services"
            title="バックグラウンドサービス"
            description="裏方デーモン 6 系統の稼働状態と操作"
            headerButtons={[
                {
                    iconName: "view-refresh-symbolic",
                    tooltipText: "今すぐ再確認",
                    actionClicked: () => svc.refreshNow(),
                },
            ]}
            bottomButtons={[
                {
                    label: "Rofi サービスメニューを開く",
                    actionClicked: () => {
                        Windows.getDefault().close("control-center");
                        svc.openRofiMenu();
                    },
                },
            ]}
        >
            <Gtk.Box orientation={Gtk.Orientation.VERTICAL} spacing={6} hexpand>
                <For each={createBinding(svc, "items")}>
                    {(item: ServiceItem) => <ServiceCard item={item} svc={svc} />}
                </For>
            </Gtk.Box>
        </Page>
    );
};
