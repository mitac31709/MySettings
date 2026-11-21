import Page from "../Page";
import { Gtk } from "ags/gtk4";
import { createBinding, createComputed } from "ags";
import KeepAwakeModule, { AUTO_OFF_PRESETS } from "../../../../modules/keep-awake";
import Windows from "../../../../window";

function ToggleRow(props: {
    title: string;
    subtitle: string;
    active: ReturnType<typeof createBinding<KeepAwakeModule, any>>;
    onToggle: (next: boolean) => void;
}) {
    return (
        <Gtk.Box class="ka-row" spacing={8} hexpand>
            <Gtk.Box orientation={Gtk.Orientation.VERTICAL} hexpand valign={Gtk.Align.CENTER}>
                <Gtk.Label class="ka-row-title" label={props.title} xalign={0} wrap />
                <Gtk.Label class="ka-row-sub" label={props.subtitle} xalign={0} wrap />
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

export const PageKeepAwake = () => {
    const ka = KeepAwakeModule.getDefault();

    const statusHeadline = createComputed(
        [
            createBinding(ka, "awakeOn"),
            createBinding(ka, "statusError"),
            createBinding(ka, "timerActive"),
            createBinding(ka, "remainingFormatted"),
        ],
        (on, err, tActive, rem) => {
            if (err) return "エラー（抑止検証を再試行中）";
            if (!on) return "OFF（通常のスリープ・自動消灯）";
            return tActive && rem
                ? `ON · 残り ${rem}`
                : "ON（画面常時オン・蓋閉じ処理継続）";
        },
    );

    const statusMeta = createComputed(
        [
            createBinding(ka, "lidLabel"),
            createBinding(ka, "shortcut"),
            createBinding(ka, "errorMessage"),
        ],
        (lid, shortcut, err) => {
            const base = `蓋: ${lid}  │  ショートカット: ${shortcut}`;
            return err ? `${base}\n${err}` : base;
        },
    );

    return (
        <Page
            id="keep-awake"
            title="画面常時オン"
            description="Caps Lock 切替・蓋閉じ処理継続・自動オフタイマー"
            bottomButtons={[
                {
                    label: "詳細設定を開く",
                    actionClicked: () => {
                        Windows.getDefault().close("control-center");
                        ka.openSettings();
                    },
                },
            ]}
        >
            <Gtk.Box class="ka-hero" orientation={Gtk.Orientation.VERTICAL} spacing={8} hexpand>
                <Gtk.Box spacing={8} hexpand>
                    <Gtk.Box
                        class={createBinding(ka, "dotClass")}
                        valign={Gtk.Align.CENTER}
                    />
                    <Gtk.Box orientation={Gtk.Orientation.VERTICAL} hexpand>
                        <Gtk.Label class="ka-headline" label={statusHeadline} xalign={0} wrap />
                        <Gtk.Label class="ka-meta" label={statusMeta} xalign={0} wrap />
                    </Gtk.Box>
                </Gtk.Box>

                <Gtk.Box spacing={6} hexpand homogeneous>
                    <Gtk.Button
                        class={createBinding(ka, "awakeOn").as((on) =>
                            on ? "ka-action primary active" : "ka-action primary",
                        )}
                        label={createBinding(ka, "awakeOn").as((on) =>
                            on ? "OFF にする" : "ON にする",
                        )}
                        onClicked={() => ka.toggle()}
                    />
                    <Gtk.Button
                        class="ka-action"
                        visible={createBinding(ka, "awakeOn")}
                        label="OFF してスリープ"
                        onClicked={() => {
                            Windows.getDefault().close("control-center");
                            ka.turnOff(true);
                        }}
                    />
                </Gtk.Box>
            </Gtk.Box>

            <Gtk.Label class="sub-header" label="機能設定" xalign={0} />
            <Gtk.Box class="ka-section" orientation={Gtk.Orientation.VERTICAL} spacing={6} hexpand>
                <ToggleRow
                    title="Caps Lock でオン/オフ"
                    subtitle="大文字固定を防ぎ、物理キーとランプで切替"
                    active={createBinding(ka, "dedicatedCapsLock")}
                    onToggle={(next) => {
                        if (next !== ka.dedicatedCapsLock) {
                            ka.setSetting("dedicated-caps-lock-mode", next ? "true" : "false");
                        }
                    }}
                />
                <ToggleRow
                    title="蓋閉じ中も画面セッション維持"
                    subtitle="ON: 最小輝度で維持 / OFF: 消灯して処理継続"
                    active={createBinding(ka, "keepDisplayAwake")}
                    onToggle={(next) => {
                        if (next !== ka.keepDisplayAwake) {
                            ka.setSetting("keep-display-awake", next ? "true" : "false");
                        }
                    }}
                />
                <ToggleRow
                    title="蓋を開けたら画面をロック"
                    subtitle="蓋を閉→開にしたときに hyprlock でロック"
                    active={createBinding(ka, "lockOnLidOpen")}
                    onToggle={(next) => {
                        if (next !== ka.lockOnLidOpen) {
                            ka.setSetting("lock-on-lid-open", next ? "true" : "false");
                        }
                    }}
                />
                <ToggleRow
                    title="テザリング接続を維持"
                    subtitle="共有ゲートウェイへ1分ごとに疎通確認"
                    active={createBinding(ka, "keepHotspotAlive")}
                    onToggle={(next) => {
                        if (next !== ka.keepHotspotAlive) {
                            ka.setSetting("keep-hotspot-alive", next ? "true" : "false");
                        }
                    }}
                />
            </Gtk.Box>

            <Gtk.Label class="sub-header" label="自動オフタイマー" xalign={0} />
            <Gtk.Box class="ka-section" orientation={Gtk.Orientation.VERTICAL} spacing={6} hexpand>
                <Gtk.FlowBox
                    class="ka-presets"
                    minChildrenPerLine={4}
                    maxChildrenPerLine={4}
                    rowSpacing={4}
                    columnSpacing={4}
                    homogeneous
                    selectionMode={Gtk.SelectionMode.NONE}
                >
                    {AUTO_OFF_PRESETS.map((preset) => (
                        <Gtk.Button
                            class={createBinding(ka, "savedDefaultMinutes").as((cur) =>
                                cur === preset.minutes ? "ka-chip selected" : "ka-chip",
                            )}
                            label={preset.label}
                            onClicked={() => ka.setAutoOffMinutes(preset.minutes)}
                        />
                    ))}
                </Gtk.FlowBox>

                <Gtk.Box
                    visible={createBinding(ka, "timerActive")}
                    spacing={6}
                    hexpand
                    homogeneous
                >
                    <Gtk.Button
                        class="ka-action"
                        label="タイマー再計測"
                        onClicked={() => ka.restartTimer()}
                    />
                    <Gtk.Button
                        class="ka-action"
                        label="タイマー解除"
                        onClicked={() => ka.cancelTimer()}
                    />
                </Gtk.Box>
            </Gtk.Box>
        </Page>
    );
};
