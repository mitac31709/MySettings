import { Gtk } from "ags/gtk4";
import Page from "../Page";
import Windows from "../../../../window";
import Notifications from "../../../../modules/notifications";
import { openNmtui } from "../../../../modules/sysstats";
import { variableToBoolean } from "../../../../modules/utils";
import { createBinding, createComputed, createState, For, With } from "ags";
import { execAsync } from "ags/process";

import NM from "gi://NM";
import AstalNetwork from "gi://AstalNetwork";

const NM_AP_FLAGS_PRIVACY = 0x1;
const NM_AP_SEC_KEY_MGMT_802_1X = 0x200;

function isApSecured(ap: AstalNetwork.AccessPoint): boolean {
    const flags = ap.flags ?? 0;
    const wpa = ap.wpaFlags ?? 0;
    const rsn = ap.rsnFlags ?? 0;
    return (flags & NM_AP_FLAGS_PRIVACY) !== 0 || wpa !== 0 || rsn !== 0;
}

function isApEnterprise(ap: AstalNetwork.AccessPoint): boolean {
    const wpa = ap.wpaFlags ?? 0;
    const rsn = ap.rsnFlags ?? 0;
    return (wpa & NM_AP_SEC_KEY_MGMT_802_1X) !== 0 || (rsn & NM_AP_SEC_KEY_MGMT_802_1X) !== 0;
}

function formatBand(frequency: number): string {
    if (frequency >= 5925) return "6 GHz";
    if (frequency >= 4900) return "5 GHz";
    if (frequency >= 2400) return "2.4 GHz";
    return "";
}

function getSavedWifiMap(client: NM.Client): Map<string, string> {
    const map = new Map<string, string>();
    try {
        for (const conn of client.get_connections()) {
            const wifiSetting = conn.get_setting_wireless();
            if (!wifiSetting) continue;
            const ssidBytes = wifiSetting.get_ssid();
            if (!ssidBytes) continue;
            const raw = ssidBytes.get_data();
            if (!raw) continue;
            const ssid = NM.utils_ssid_to_utf8(raw);
            if (ssid && !map.has(ssid)) {
                map.set(ssid, conn.get_id() || ssid);
            }
        }
    } catch {
        // Ignore malformed profiles
    }
    return map;
}

function filterRelevantDevices(devices: NM.Device[]): NM.Device[] {
    return devices.filter((dev) => {
        const iface = dev.interface ?? "";
        if (!iface || iface === "lo" || iface.startsWith("/net/connman/")) return false;
        if (!dev.real) return false;
        if (dev.deviceType === NM.DeviceType.WIFI_P2P) return false;
        if (dev.state === NM.DeviceState.UNMANAGED) return false;
        return true;
    });
}

function deviceIconName(type: NM.DeviceType): string {
    switch (type) {
        case NM.DeviceType.WIFI:
            return "network-wireless-symbolic";
        case NM.DeviceType.TUN:
        case NM.DeviceType.WIREGUARD:
            return "network-vpn-symbolic";
        default:
            return "network-wired-symbolic";
    }
}

function deviceStateText(device: NM.Device): string {
    switch (device.state) {
        case NM.DeviceState.ACTIVATED: {
            const conId = device.activeConnection?.id;
            return conId && conId !== device.interface
                ? `接続済み · ${conId}`
                : "接続済み";
        }
        case NM.DeviceState.PREPARE:
        case NM.DeviceState.CONFIG:
        case NM.DeviceState.NEED_AUTH:
        case NM.DeviceState.IP_CONFIG:
        case NM.DeviceState.IP_CHECK:
        case NM.DeviceState.SECONDARIES:
            return "接続中...";
        case NM.DeviceState.UNAVAILABLE:
            return "利用不可";
        default:
            return "未接続";
    }
}

function dedupeAndSortAps(
    aps: AstalNetwork.AccessPoint[],
    activeSsid: string | null,
    savedMap: Map<string, string>,
): AstalNetwork.AccessPoint[] {
    const bySsid = new Map<string, AstalNetwork.AccessPoint>();
    for (const ap of aps) {
        const ssid = ap.ssid?.trim();
        if (!ssid) continue;
        const existing = bySsid.get(ssid);
        if (!existing || ap.strength > existing.strength) {
            bySsid.set(ssid, ap);
        }
    }
    return Array.from(bySsid.values()).sort((a, b) => {
        const aActive = activeSsid !== null && a.ssid === activeSsid ? 1 : 0;
        const bActive = activeSsid !== null && b.ssid === activeSsid ? 1 : 0;
        if (aActive !== bActive) return bActive - aActive;

        const aSaved = a.ssid && savedMap.has(a.ssid) ? 1 : 0;
        const bSaved = b.ssid && savedMap.has(b.ssid) ? 1 : 0;
        if (aSaved !== bSaved) return bSaved - aSaved;

        if (a.strength !== b.strength) return b.strength - a.strength;
        return (a.ssid ?? "").localeCompare(b.ssid ?? "");
    });
}

function notifyNetwork(summary: string, body: string): void {
    Notifications.getDefault().sendNotification({
        appName: "network",
        summary,
        body,
    });
}

export const PageNetwork = () => {
    const net = AstalNetwork.get_default();
    const [promptSsid, setPromptSsid] = createState<string | null>(null);
    const [busySsid, setBusySsid] = createState<string | null>(null);

    const devicesBinding = createBinding(net.client, "devices").as(filterRelevantDevices);
    const wifiBinding = createBinding(net, "wifi");

    const pageDescription = createComputed(
        [
            createBinding(net, "primary"),
            wifiBinding,
        ],
        (primary, wifi) => {
            if (primary === AstalNetwork.Primary.WIFI && wifi?.ssid) {
                return `Wi-Fi 接続中: ${wifi.ssid}`;
            }
            if (primary === AstalNetwork.Primary.WIRED) {
                return "有線ネットワーク接続中";
            }
            return "ネットワークと Wi-Fi の管理";
        },
    );

    const connectWithNmcli = async (ssid: string, args: string[]) => {
        setBusySsid(ssid);
        try {
            await execAsync(args);
            setPromptSsid(null);
        } catch (e: unknown) {
            const msg = e instanceof Error ? e.message : String(e);
            notifyNetwork(
                "Wi-Fi 接続に失敗しました",
                `「${ssid}」へ接続できませんでした。\n${msg}`,
            );
        } finally {
            setBusySsid((cur) => (cur === ssid ? null : cur));
        }
    };

    const passwordOverlay = (
        <Gtk.Box
            class={"net-pass-backdrop"}
            hexpand
            vexpand
            visible={promptSsid.as(Boolean)}
            $={(backdrop) => {
                const click = Gtk.GestureClick.new();
                click.connect("released", (_, __, x, y) => {
                    const card = backdrop.get_first_child();
                    if (!card) {
                        setPromptSsid(null);
                        return;
                    }
                    const alloc = card.get_allocation();
                    if (
                        x < alloc.x ||
                        x > alloc.x + alloc.width ||
                        y < alloc.y ||
                        y > alloc.y + alloc.height
                    ) {
                        setPromptSsid(null);
                    }
                });
                backdrop.add_controller(click);
            }}
        >
            <Gtk.Box
                halign={Gtk.Align.CENTER}
                valign={Gtk.Align.CENTER}
            >
                <With value={promptSsid}>
                    {(targetSsid: string | null) => {
                        if (!targetSsid) return <Gtk.Box visible={false} />;

                        let entryRef: Gtk.PasswordEntry | null = null;
                        const submit = () => {
                            const pw = entryRef?.get_text() ?? "";
                            if (!pw) return;
                            void connectWithNmcli(targetSsid, [
                                "nmcli",
                                "device",
                                "wifi",
                                "connect",
                                targetSsid,
                                "password",
                                pw,
                            ]);
                        };

                        return (
                            <Gtk.Box
                                class={"net-pass-box"}
                                orientation={Gtk.Orientation.VERTICAL}
                                spacing={8}
                                widthRequest={280}
                            >
                                <Gtk.Label
                                    class={"net-pass-title"}
                                    label={`「${targetSsid}」に接続`}
                                    xalign={0}
                                />
                                <Gtk.PasswordEntry
                                    class={"net-pass-entry"}
                                    showPeekIcon
                                    placeholderText={"パスワードを入力"}
                                    hexpand
                                    $={(self) => {
                                        entryRef = self;
                                    }}
                                    onMap={(self) => self.grab_focus()}
                                    onActivate={submit}
                                />
                                <Gtk.Box spacing={6} hexpand homogeneous>
                                    <Gtk.Button
                                        class={"net-pass-btn"}
                                        label={tr("cancel")}
                                        onClicked={() => setPromptSsid(null)}
                                    />
                                    <Gtk.Button
                                        class={"net-pass-btn primary"}
                                        label={"接続"}
                                        onClicked={submit}
                                    />
                                </Gtk.Box>
                            </Gtk.Box>
                        );
                    }}
                </With>
            </Gtk.Box>
        </Gtk.Box>
    ) as Gtk.Widget;

    return (
        <Page
            id={"network"}
            title={tr("control_center.pages.network.title")}
            description={pageDescription}
            spacing={10}
            overlay={passwordOverlay}
            headerButtons={wifiBinding.as((wifi) =>
                wifi
                    ? [
                        {
                            iconName: "view-refresh-symbolic",
                            tooltipText: "ネットワークを再スキャン",
                            actionClicked: () => wifi.scan(),
                        },
                    ]
                    : [],
            )}
            bottomButtons={[
                {
                    label: "nmtui を端末で開く",
                    actionClicked: () => {
                        Windows.getDefault().close("control-center");
                        openNmtui();
                    },
                },
            ]}
            onClosed={() => setPromptSsid(null)}
        >
            <Gtk.Box
                class={"devices"}
                hexpand
                orientation={Gtk.Orientation.VERTICAL}
                visible={variableToBoolean(devicesBinding)}
                spacing={4}
            >
                <Gtk.Label label={tr("devices")} xalign={0} class={"sub-header"} />
                <For each={devicesBinding}>
                    {(device: NM.Device) => (
                        <Page.DecoratedButton
                            class={createBinding(device, "state").as((state) =>
                                state === NM.DeviceState.ACTIVATED ? "device selected" : "device",
                            )}
                            title={createBinding(device, "interface").as(
                                (iface) => iface ?? tr("control_center.pages.network.interface"),
                            )}
                            description={createBinding(device, "state").as(() =>
                                deviceStateText(device),
                            )}
                            icon={createBinding(device, "deviceType").as(deviceIconName)}
                            actionClicked={() => {
                                Windows.getDefault().close("control-center");
                                openNmtui();
                            }}
                        />
                    )}
                </For>
            </Gtk.Box>

            <With value={wifiBinding}>
                {(wifi: AstalNetwork.Wifi | null) => {
                    if (!wifi) return <Gtk.Box visible={false} />;

                    const wifiEnabled = createBinding(wifi, "enabled");
                    const activeApBinding = createBinding(wifi, "activeAccessPoint");
                    const apsBinding = createComputed(
                        [
                            createBinding(wifi, "accessPoints"),
                            activeApBinding,
                        ],
                        (aps, activeAp) => {
                            const savedMap = getSavedWifiMap(net.client);
                            return dedupeAndSortAps(aps, activeAp?.ssid ?? null, savedMap);
                        },
                    );

                    return (
                        <Gtk.Box
                            class={"wireless-aps"}
                            hexpand
                            orientation={Gtk.Orientation.VERTICAL}
                            spacing={6}
                        >
                            <Gtk.Box class={"wifi-header"} hexpand spacing={8}>
                                <Gtk.Label
                                    class={"sub-header"}
                                    label={"Wi-Fi"}
                                    xalign={0}
                                    hexpand
                                    valign={Gtk.Align.CENTER}
                                />
                                <Gtk.Switch
                                    valign={Gtk.Align.CENTER}
                                    active={wifiEnabled}
                                    onStateSet={(_sw, state) => {
                                        if (wifi.enabled !== state) {
                                            wifi.set_enabled(state);
                                        }
                                        return false;
                                    }}
                                />
                            </Gtk.Box>

                            <Gtk.Label
                                class={"net-empty"}
                                label={"Wi-Fi はオフです"}
                                xalign={0}
                                visible={wifiEnabled.as((on) => !on)}
                            />

                            <Gtk.Box
                                orientation={Gtk.Orientation.VERTICAL}
                                spacing={2}
                                visible={wifiEnabled}
                                hexpand
                            >
                                <For each={apsBinding}>
                                    {(ap: AstalNetwork.AccessPoint) => {
                                        const ssid = ap.ssid ?? "";
                                        const secured = isApSecured(ap);
                                        const enterprise = isApEnterprise(ap);

                                        const isActive = activeApBinding.as(
                                            (active) => Boolean(active?.ssid && active.ssid === ssid),
                                        );

                                        const apDesc = createComputed(
                                            [
                                                isActive,
                                                busySsid,
                                                createBinding(ap, "strength"),
                                            ],
                                            (active, busy, strength) => {
                                                const parts: string[] = [];
                                                if (busy === ssid) {
                                                    parts.push("接続中...");
                                                } else if (active) {
                                                    parts.push("接続済み");
                                                } else if (getSavedWifiMap(net.client).has(ssid)) {
                                                    parts.push("保存済み");
                                                }
                                                parts.push(`${strength}%`);
                                                const band = formatBand(ap.frequency);
                                                if (band) parts.push(band);
                                                if (enterprise) parts.push("EAP");
                                                return parts.join(" · ");
                                            },
                                        );

                                        return (
                                            <Page.DecoratedButton
                                                class={isActive.as((active) =>
                                                    active ? "selected" : "",
                                                )}
                                                title={ssid}
                                                description={apDesc}
                                                icon={createBinding(ap, "iconName")}
                                                endWidget={
                                                    secured ? (
                                                        <Gtk.Image
                                                            iconName={"network-wireless-encrypted-symbolic"}
                                                            class={"net-lock-icon"}
                                                            tooltipText={
                                                                enterprise
                                                                    ? "WPA-Enterprise"
                                                                    : "暗号化済み"
                                                            }
                                                        />
                                                    ) : undefined
                                                }
                                                extraButtons={
                                                    <Gtk.Button
                                                        iconName={"window-close-symbolic"}
                                                        tooltipText={tr("disconnect")}
                                                        visible={isActive}
                                                        onClicked={() => {
                                                            const active = wifi.activeAccessPoint;
                                                            if (active?.ssid === ssid) {
                                                                wifi.deactivate_connection((_, res) => {
                                                                    try {
                                                                        wifi.deactivate_connection_finish(res);
                                                                    } catch (e: unknown) {
                                                                        const msg =
                                                                            e instanceof Error
                                                                                ? e.message
                                                                                : String(e);
                                                                        notifyNetwork(
                                                                            "Wi-Fi 切断に失敗しました",
                                                                            `「${ssid}」を切断できませんでした。\n${msg}`,
                                                                        );
                                                                    }
                                                                });
                                                            }
                                                        }}
                                                    />
                                                }
                                                actionClicked={() => {
                                                    if (!ssid) return;
                                                    if (wifi.activeAccessPoint?.ssid === ssid) return;

                                                    const savedMap = getSavedWifiMap(net.client);
                                                    const savedName = savedMap.get(ssid);
                                                    if (savedName) {
                                                        void connectWithNmcli(ssid, [
                                                            "nmcli",
                                                            "connection",
                                                            "up",
                                                            savedName,
                                                        ]);
                                                        return;
                                                    }

                                                    if (!secured) {
                                                        void connectWithNmcli(ssid, [
                                                            "nmcli",
                                                            "device",
                                                            "wifi",
                                                            "connect",
                                                            ssid,
                                                        ]);
                                                        return;
                                                    }

                                                    if (enterprise) {
                                                        Windows.getDefault().close("control-center");
                                                        openNmtui();
                                                        notifyNetwork(
                                                            "nmtui を開きました",
                                                            `「${ssid}」はエンタープライズ認証 (WPA-EAP) のため nmtui から設定してください。`,
                                                        );
                                                        return;
                                                    }

                                                    setPromptSsid(ssid);
                                                }}
                                            />
                                        );
                                    }}
                                </For>
                            </Gtk.Box>
                        </Gtk.Box>
                    );
                }}
            </With>
        </Page>
    );
};
