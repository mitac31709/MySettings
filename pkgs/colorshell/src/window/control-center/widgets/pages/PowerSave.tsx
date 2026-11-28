import Page from "../Page";
import { Gtk } from "ags/gtk4";
import { createBinding, createComputed } from "ags";
import PowerSaveModule, {
    BRIGHTNESS_CAP_PRESETS,
    LOW_BATTERY_PRESETS,
} from "../../../../modules/power-save";

function ToggleRow(props: {
    title: string;
    subtitle: string;
    active: ReturnType<typeof createBinding<PowerSaveModule, any>>;
    onToggle: (next: boolean) => void;
}) {
    return (
        <Gtk.Box class="ps-row" spacing={8} hexpand>
            <Gtk.Box orientation={Gtk.Orientation.VERTICAL} hexpand valign={Gtk.Align.CENTER}>
                <Gtk.Label class="ps-row-title" label={props.title} xalign={0} wrap />
                <Gtk.Label class="ps-row-sub" label={props.subtitle} xalign={0} wrap />
            </Gtk.Box>
            <Gtk.Switch
                valign={Gtk.Align.CENTER}
                active={props.active}
                onStateSet={(_sw, state) => {
                    props.onToggle(state);
                    return false;
                }}
            />
        </Gtk.Box>
    );
}

export const PagePowerSave = () => {
    const ps = PowerSaveModule.getDefault();

    const statusHeadline = createComputed(
        [
            createBinding(ps, "active"),
            createBinding(ps, "reason"),
            createBinding(ps, "errorMessage"),
        ],
        (on, reason, err) => {
            if (err && !on) return "エラー";
            if (!on) return "OFF（通常モード）";
            return reason === "low-battery"
                ? "ON（バッテリー低下で自動有効化）"
                : "ON（省電力モード稼働中）";
        },
    );

    const statusMeta = createComputed(
        [
            createBinding(ps, "active"),
            createBinding(ps, "appliedSummary"),
            createBinding(ps, "errorMessage"),
        ],
        (on, summary, err) => {
            const base = on
                ? (summary || "省電力設定を適用中")
                : "ON にすると CPU・描画・輝度・BT・裏方サービスを一括抑制します";
            return err ? `${base}\n${err}` : base;
        },
    );

    return (
        <Page
            id="power-save"
            title="省電力モード"
            description="CPU・描画・輝度・BT・裏方サービスの一括省電力化"
        >
            <Gtk.Box class="ps-hero" orientation={Gtk.Orientation.VERTICAL} spacing={8} hexpand>
                <Gtk.Box spacing={8} hexpand>
                    <Gtk.Box
                        class={createBinding(ps, "dotClass")}
                        valign={Gtk.Align.CENTER}
                    />
                    <Gtk.Box orientation={Gtk.Orientation.VERTICAL} hexpand>
                        <Gtk.Label class="ps-headline" label={statusHeadline} xalign={0} wrap />
                        <Gtk.Label class="ps-meta" label={statusMeta} xalign={0} wrap />
                    </Gtk.Box>
                </Gtk.Box>

                <Gtk.Button
                    class={createBinding(ps, "active").as((on) =>
                        on ? "ps-action primary active" : "ps-action primary",
                    )}
                    label={createBinding(ps, "active").as((on) =>
                        on ? "通常モードに戻す (OFF)" : "省電力モードにする (ON)",
                    )}
                    onClicked={() => ps.toggle()}
                />
            </Gtk.Box>

            <Gtk.Label class="sub-header" label="省電力の内容" xalign={0} />
            <Gtk.Box class="ps-section" orientation={Gtk.Orientation.VERTICAL} spacing={6} hexpand>
                <ToggleRow
                    title="CPU 省電力化"
                    subtitle="auto-cpufreq powersave 固定・Turbo 無効・EPP=power"
                    active={createBinding(ps, "cfgCpu")}
                    onToggle={(next) => {
                        if (next !== ps.cfgCpu) {
                            ps.setConfig("cpu", next ? "true" : "false");
                        }
                    }}
                />
                <ToggleRow
                    title="Hyprland 描画軽量化"
                    subtitle="アニメーション・ぼかし・影をオフ"
                    active={createBinding(ps, "cfgHyprland")}
                    onToggle={(next) => {
                        if (next !== ps.cfgHyprland) {
                            ps.setConfig("hyprland", next ? "true" : "false");
                        }
                    }}
                />
                <ToggleRow
                    title="画面輝度の上限を設定"
                    subtitle="ON時に上限まで下げ、OFF時に元の輝度へ復帰"
                    active={createBinding(ps, "cfgBrightness")}
                    onToggle={(next) => {
                        if (next !== ps.cfgBrightness) {
                            ps.setConfig("brightness", next ? "true" : "false");
                        }
                    }}
                />
                <Gtk.FlowBox
                    visible={createBinding(ps, "cfgBrightness")}
                    class="ps-presets"
                    minChildrenPerLine={5}
                    maxChildrenPerLine={5}
                    rowSpacing={4}
                    columnSpacing={4}
                    homogeneous
                    selectionMode={Gtk.SelectionMode.NONE}
                >
                    {BRIGHTNESS_CAP_PRESETS.map((pct) => (
                        <Gtk.Button
                            class={createBinding(ps, "cfgBrightnessCap").as((cur) =>
                                cur === pct ? "ps-chip selected" : "ps-chip",
                            )}
                            label={`${pct}%`}
                            onClicked={() => ps.setConfig("brightness_cap", `${pct}`)}
                        />
                    ))}
                </Gtk.FlowBox>
                <ToggleRow
                    title="未接続の Bluetooth をオフ"
                    subtitle="接続中の機器がない場合のみオフ（解除時に復帰）"
                    active={createBinding(ps, "cfgBluetooth")}
                    onToggle={(next) => {
                        if (next !== ps.cfgBluetooth) {
                            ps.setConfig("bluetooth", next ? "true" : "false");
                        }
                    }}
                />
                <ToggleRow
                    title="裏方サービスを一時停止"
                    subtitle="ActivityWatch / WhatPulse / LAN Mouse / UniClipboard 等"
                    active={createBinding(ps, "cfgServices")}
                    onToggle={(next) => {
                        if (next !== ps.cfgServices) {
                            ps.setConfig("services", next ? "true" : "false");
                        }
                    }}
                />
            </Gtk.Box>

            <Gtk.Label class="sub-header" label="自動切替" xalign={0} />
            <Gtk.Box class="ps-section" orientation={Gtk.Orientation.VERTICAL} spacing={6} hexpand>
                <ToggleRow
                    title="バッテリー低下時に自動 ON"
                    subtitle="放電中にしきい値以下になったら自動で省電力モードへ"
                    active={createBinding(ps, "cfgAutoOnLowBattery")}
                    onToggle={(next) => {
                        if (next !== ps.cfgAutoOnLowBattery) {
                            ps.setConfig("auto_on_low_battery", next ? "true" : "false");
                        }
                    }}
                />
                <Gtk.FlowBox
                    visible={createBinding(ps, "cfgAutoOnLowBattery")}
                    class="ps-presets"
                    minChildrenPerLine={4}
                    maxChildrenPerLine={4}
                    rowSpacing={4}
                    columnSpacing={4}
                    homogeneous
                    selectionMode={Gtk.SelectionMode.NONE}
                >
                    {LOW_BATTERY_PRESETS.map((pct) => (
                        <Gtk.Button
                            class={createBinding(ps, "cfgLowBatteryThreshold").as((cur) =>
                                cur === pct ? "ps-chip selected" : "ps-chip",
                            )}
                            label={`≤${pct}%`}
                            onClicked={() => ps.setConfig("low_battery_threshold", `${pct}`)}
                        />
                    ))}
                </Gtk.FlowBox>
                <ToggleRow
                    title="AC 接続時に自動 OFF"
                    subtitle="充電器を挿したら自動で通常モードへ復帰"
                    active={createBinding(ps, "cfgAutoOffOnAc")}
                    onToggle={(next) => {
                        if (next !== ps.cfgAutoOffOnAc) {
                            ps.setConfig("auto_off_on_ac", next ? "true" : "false");
                        }
                    }}
                />
            </Gtk.Box>
        </Page>
    );
};
