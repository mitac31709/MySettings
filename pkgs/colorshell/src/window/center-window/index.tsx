import { Gdk, Gtk } from "ags/gtk4";
import { Separator } from "../../widget/Separator";
import { PopupWindow } from "../../widget/PopupWindow";
import { BigMedia } from "./widgets/BigMedia";
import { time, variableToBoolean } from "../../modules/utils";
import { getWorldClockSnapshot, triggerNtpSync } from "../../modules/worldclock";
import { createBinding } from "ags";
import { generalConfig } from "../../config";
import Windows from "..";
import Media from "../../modules/media";
import AstalMpris from "gi://AstalMpris";

export const CenterWindow = Windows.forFocusedMonitor(() => {
    const notifPopupHPos = generalConfig.getProperty("notifications.position_h", "string");
    const worldSnap = time((dt) => getWorldClockSnapshot(dt));

    return (
        <PopupWindow
            namespace={"center-window"}
            marginTop={10}
            class={"center-window"}
            onKeyPressed={(_, keyval) => {
                if (keyval === Gdk.KEY_space) {
                    Media.getDefault().player?.available
                        && Media.getDefault().player!.play_pause();
                    return true;
                }
            }}
            $={() => {
                if (notifPopupHPos !== "center") return;

                generalConfig.setProperty("notifications.position_h", "left", false);
            }}
            onClosed={() => {
                const currentNotifPopupHPos = generalConfig.getProperty(
                    "notifications.position_h",
                    "string",
                );
                if (currentNotifPopupHPos === notifPopupHPos) return;

                generalConfig.setProperty("notifications.position_h", notifPopupHPos, false);
            }}
        >
            <Gtk.Box
                class={"container"}
                spacing={6}
                valign={Gtk.Align.START}
                halign={Gtk.Align.CENTER}
            >
                <Gtk.Box class={"left"} orientation={Gtk.Orientation.VERTICAL} spacing={8}>
                    <Gtk.Box
                        class={"datetime"}
                        orientation={Gtk.Orientation.VERTICAL}
                        halign={Gtk.Align.CENTER}
                        valign={Gtk.Align.CENTER}
                    >
                        <Gtk.Label
                            class={"time number"}
                            label={time((t) => t.format("%H:%M:%S")!)}
                        />
                        <Gtk.Label
                            class={"date"}
                            label={time((d) => d.format("%Y-%m-%d (%a)")!)}
                        />
                    </Gtk.Box>
                    <Gtk.Box class={"calendar-box"} hexpand={true} valign={Gtk.Align.START}>
                        <Gtk.Calendar
                            showHeading={true}
                            showDayNames={true}
                            showWeekNumbers={false}
                        />
                    </Gtk.Box>

                    <Gtk.Box
                        class={"world-clocks"}
                        orientation={Gtk.Orientation.VERTICAL}
                        spacing={3}
                    >
                        {[0, 1, 2, 3].map((idx) => (
                            <Gtk.Box class={"wc-row"} spacing={8}>
                                <Gtk.Label
                                    class={"wc-tag"}
                                    xalign={0}
                                    label={worldSnap((s) => s.zones[idx]?.tag ?? "")}
                                />
                                <Gtk.Label
                                    class={"wc-value number"}
                                    xalign={0}
                                    hexpand
                                    label={worldSnap((s) => s.zones[idx]?.datetime ?? "")}
                                />
                                <Gtk.Label
                                    class={"wc-meta number"}
                                    xalign={1}
                                    label={worldSnap((s) => s.zones[idx]?.meta ?? "")}
                                />
                            </Gtk.Box>
                        ))}
                        <Gtk.Box class={"wc-row wc-gpst"} spacing={8}>
                            <Gtk.Label class={"wc-tag"} xalign={0} label="GPST" />
                            <Gtk.Label
                                class={"wc-value number"}
                                xalign={0}
                                hexpand
                                label={worldSnap((s) => s.gpst.datetime)}
                            />
                            <Gtk.Label
                                class={"wc-meta number"}
                                xalign={1}
                                label={worldSnap((s) => s.gpst.meta)}
                            />
                        </Gtk.Box>
                        <Gtk.Box class={"wc-row wc-unix"} spacing={8}>
                            <Gtk.Label class={"wc-tag"} xalign={0} label="UNIX" />
                            <Gtk.Label
                                class={"wc-value number"}
                                xalign={0}
                                hexpand
                                label={worldSnap((s) => s.unix.datetime)}
                            />
                            <Gtk.Label class={"wc-meta"} xalign={1} label="sec" />
                        </Gtk.Box>
                        <Gtk.Box class={"wc-ntp-bar"} spacing={8}>
                            <Gtk.Label
                                class={worldSnap((s) =>
                                    `wc-ntp-state ${s.ntpSynced ? "synced" : "waiting"}`,
                                )}
                                xalign={0}
                                hexpand
                                label={worldSnap((s) =>
                                    s.ntpSynced ? "NTP: 同期済み" : "NTP: 同期待ち",
                                )}
                            />
                            <Gtk.Button
                                class={"wc-ntp-button reactive-secondary"}
                                tooltipText={"systemd-timesyncd を再起動して時刻を即時同期"}
                                onClicked={() => triggerNtpSync()}
                            >
                                <Gtk.Box spacing={4}>
                                    <Gtk.Image iconName={"view-refresh-symbolic"} />
                                    <Gtk.Label label={"NTP 同期"} />
                                </Gtk.Box>
                            </Gtk.Button>
                        </Gtk.Box>
                    </Gtk.Box>
                </Gtk.Box>

                <Separator
                    orientation={Gtk.Orientation.HORIZONTAL}
                    cssColor="gray"
                    margin={5}
                    spacing={8}
                    alpha={0.3}
                    visible={variableToBoolean(
                        createBinding(AstalMpris.get_default(), "players"),
                    )}
                />
                <BigMedia />
            </Gtk.Box>
        </PopupWindow>
    );
});
