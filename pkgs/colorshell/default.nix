# Customizes upstream Colorshell with MySettings native integrations:
# - 1-1: Flake / .deb updates indicator (bar Updates widget watching XDG_RUNTIME_DIR/flake-update-status)
# - 1-2: Multi-timezone + GPST (tzdata leap-seconds) + UNIX clock tooltip, CenterWindow world clocks & NTP sync
# - 1-3: Direct sysfs battery telemetry (voltage / Wh / health / W / ETA / 0% gauge anomaly detection) in Bar & Control Center
# - 2-1: Restic backup live progress pill (bar ResticBackup widget watching XDG_RUNTIME_DIR/restic-home-status)
# - 2-2: Background daemons (6 services) bar health pill + Control Center PageServices
# - 2-3: JQuake live status indicator (systemd units + Hyprland open-window detection)
# - 2-4: Unified Keep Screen On + Capsomnia (bar KeepAwake pill + Control Center TileKeepAwake & PageKeepAwake)
# - 2-5: Startup sound bar indicator (state watcher + menu / toggle / play)
# - 2-6: Direct bar launchers (Cheatsheet `?`, CPU/Mem -> btop, Network right-click & PageNetwork -> nmtui)
# - 2-7: T3 Code agent-run pill + card (watches XDG_RUNTIME_DIR/agent-run-status.json)
{
  baseColorshell,
  glib,
}:

baseColorshell.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    cp ${./src/modules/worldclock.ts} src/modules/worldclock.ts
    cp ${./src/modules/sysfs-battery.ts} src/modules/sysfs-battery.ts
    cp ${./src/modules/updates.ts} src/modules/updates.ts
    cp ${./src/modules/cc-nav.ts} src/modules/cc-nav.ts
    cp ${./src/modules/keep-awake.ts} src/modules/keep-awake.ts
    cp ${./src/modules/restic.ts} src/modules/restic.ts
    cp ${./src/modules/services.ts} src/modules/services.ts
    cp ${./src/modules/jquake.ts} src/modules/jquake.ts
    cp ${./src/modules/startup-sound.ts} src/modules/startup-sound.ts
    cp ${./src/modules/sysstats.ts} src/modules/sysstats.ts
    cp ${./src/modules/agent-run.ts} src/modules/agent-run.ts

    cp ${./src/window/bar/widgets/Cheatsheet.tsx} src/window/bar/widgets/Cheatsheet.tsx
    cp ${./src/window/bar/widgets/Clock.tsx} src/window/bar/widgets/Clock.tsx
    cp ${./src/window/bar/widgets/JQuake.tsx} src/window/bar/widgets/JQuake.tsx
    cp ${./src/window/bar/widgets/KeepAwake.tsx} src/window/bar/widgets/KeepAwake.tsx
    cp ${./src/window/bar/widgets/ResticBackup.tsx} src/window/bar/widgets/ResticBackup.tsx
    cp ${./src/window/bar/widgets/Services.tsx} src/window/bar/widgets/Services.tsx
    cp ${./src/window/bar/widgets/StartupSound.tsx} src/window/bar/widgets/StartupSound.tsx
    cp ${./src/window/bar/widgets/Status.tsx} src/window/bar/widgets/Status.tsx
    cp ${./src/window/bar/widgets/SystemStats.tsx} src/window/bar/widgets/SystemStats.tsx
    cp ${./src/window/bar/widgets/Updates.tsx} src/window/bar/widgets/Updates.tsx
    cp ${./src/window/bar/widgets/AgentRun.tsx} src/window/bar/widgets/AgentRun.tsx
    mkdir -p src/window/agent-run
    cp ${./src/window/agent-run/index.tsx} src/window/agent-run/index.tsx

    cp ${./src/window/center-window/index.tsx} src/window/center-window/index.tsx

    cp ${./src/window/control-center/widgets/BatteryInfo.tsx} src/window/control-center/widgets/BatteryInfo.tsx
    cp ${./src/window/control-center/widgets/tiles/KeepAwake.tsx} src/window/control-center/widgets/tiles/KeepAwake.tsx
    cp ${./src/window/control-center/widgets/pages/KeepAwake.tsx} src/window/control-center/widgets/pages/KeepAwake.tsx
    cp ${./src/window/control-center/widgets/pages/Services.tsx} src/window/control-center/widgets/pages/Services.tsx

    # Prevent pywal16 from broadcasting OSC 4/10/11 sequences to open PTYs (/dev/pts/*),
    # which overwrote Ghostty's Nocturne Slate palette with low-contrast dark blue whenever
    # colorshell restarted (e.g. during `rebuild`) or switched wallpapers. Also skip wal's
    # redundant wallpaper setter (-n; hyprpaper manages it) and unrelated app reloads (-e).
    substituteInPlace src/modules/color/engine/pywal16.ts \
      --replace-fail \
        '}" -t --cols16 ' \
        '}" -s -t -n -e --cols16 '

    substituteInPlace src/windows.ts \
      --replace-fail \
        'import { OSD } from "./window/osd";' \
        $'import { OSD } from "./window/osd";\nimport { AgentRunCard } from "./window/agent-run";' \
      --replace-fail \
        '"osd": OSD,' \
        $'"osd": OSD,\n    "agent-run": AgentRunCard,'

    substituteInPlace src/window/bar/index.tsx \
      --replace-fail \
        'import { Tray } from "./widgets/Tray";' \
        $'import { Tray } from "./widgets/Tray";\nimport { Cheatsheet } from "./widgets/Cheatsheet";\nimport { ResticBackup } from "./widgets/ResticBackup";\nimport { SystemStats } from "./widgets/SystemStats";\nimport { KeepAwake } from "./widgets/KeepAwake";\nimport { Services } from "./widgets/Services";\nimport { JQuake } from "./widgets/JQuake";\nimport { StartupSound } from "./widgets/StartupSound";\nimport { Updates } from "./widgets/Updates";\nimport { AgentRun } from "./widgets/AgentRun";' \
      --replace-fail \
        '<Apps />' \
        $'<Apps />\n                    <Cheatsheet />' \
      --replace-fail \
        '<Tray />' \
        $'<AgentRun />\n                    <ResticBackup />\n                    <SystemStats />\n                    <KeepAwake />\n                    <Services />\n                    <JQuake />\n                    <StartupSound />\n                    <Updates />\n                    <Tray />'

    substituteInPlace src/widget/Notification.tsx \
      --replace-fail \
        '@register({ GTypeName: "ClshNotification" })' \
        $'function safeNotificationMarkup(raw: string | null): string {\n    const text = raw ?? "";\n    if (!text) return "";\n    try {\n        Pango.parse_markup(text, -1, String.fromCharCode(0));\n        return text;\n    } catch {\n        return GLib.markup_escape_text(text, -1);\n    }\n}\n\n@register({ GTypeName: "ClshNotification" })' \
      --replace-fail \
        'label={createBinding(this, "body").as(s => s ?? "")} useMarkup' \
        'label={createBinding(this, "body").as(safeNotificationMarkup)} useMarkup'

    substituteInPlace src/window/control-center/index.tsx \
      --replace-fail \
        'import { Sliders } from "./widgets/Sliders";' \
        $'import { Sliders } from "./widgets/Sliders";\nimport { BatteryInfo } from "./widgets/BatteryInfo";\nimport { PageKeepAwake } from "./widgets/pages/KeepAwake";\nimport { PageServices } from "./widgets/pages/Services";\nimport { registerControlCenterPages } from "../../modules/cc-nav";' \
      --replace-fail \
        '<PageMicrophone $type="page" />' \
        $'<PageMicrophone $type="page" />\n                                <PageKeepAwake $type="page" />\n                                <PageServices $type="page" />' \
      --replace-fail \
        '<Sliders ccWindow={this as ControlCenterWindow} />' \
        $'<Sliders ccWindow={this as ControlCenterWindow} />\n                                    <BatteryInfo />' \
      --replace-fail \
        '        );' \
        $'        );\n\n        const unregisterPages = registerControlCenterPages(this.#pages);\n        this.connect("destroy", () => unregisterPages());'

    substituteInPlace src/window/control-center/widgets/tiles/index.tsx \
      --replace-fail \
        'import { TileNightLight } from "./NightLight";' \
        $'import { TileNightLight } from "./NightLight";\nimport { TileKeepAwake } from "./KeepAwake";' \
      --replace-fail \
        '    TileNightLight' \
        $'    TileNightLight,\n    TileKeepAwake'

    substituteInPlace src/window/control-center/widgets/pages/Network.tsx \
      --replace-fail \
        'import { execApp } from "../../../../modules/apps";' \
        $'import { execApp } from "../../../../modules/apps";\nimport { openNmtui } from "../../../../modules/sysstats";' \
      --replace-fail \
        '      bottomButtons={[{' \
        $'      bottomButtons={[{\n          label: "nmtui を端末で開く",\n          actionClicked: () => {\n              Windows.getDefault().close("control-center");\n              openNmtui();\n          }\n      }, {'

    substituteInPlace src/compositor/interface/hyprland/compositor.ts \
      --replace-fail \
        'this.hyprctl(`dispatch hl.dsp.exec_cmd("''${cmd}")`);' \
        'this.hyprctl(`dispatch hl.dsp.exec_cmd(''${JSON.stringify(cmd)})`);'

    substituteInPlace src/widget/BackgroundWindow.tsx \
      --replace-fail \
        $'                    setTimeout(() => { // just in case (gtk can freeze when doing this too fast)\n                        if(this.attachedLayer)\n                            this.attachedLayer.visible = true;\n                    }, 50);' \
        $'                    setTimeout(() => { // just in case (gtk can freeze when doing this too fast)\n                        if(this.visible && this.attachedLayer)\n                            this.attachedLayer.visible = true;\n                    }, 50);' \
      --replace-fail \
        $'    /** attach a main window to this background layer */' \
        $'    on_close_request(): boolean {\n        const layer = this.attachedLayer;\n        this.deattach();\n        layer?.close();\n        return false;\n    }\n\n    /** attach a main window to this background layer */'

    printf '\n' >> data/css/main.css
    cat ${./css/main-extra.css} >> data/css/main.css
    printf '\n' >> data/css/main.css
    cat ${./css/agent-run-extra.css} >> data/css/main.css

    printf '\n' >> data/css/osd.css
    cat ${./css/osd-extra.css} >> data/css/osd.css

    printf '\n' >> data/css/bar.css
    cat ${./css/bar-extra.css} >> data/css/bar.css

    printf '\n' >> data/css/center-window.css
    cat ${./css/center-window-extra.css} >> data/css/center-window.css

    printf '\n' >> data/css/control-center.css
    cat ${./css/control-center-extra.css} >> data/css/control-center.css
  '';

  postBuild = (old.postBuild or "") + ''
    ${glib.dev}/bin/glib-compile-resources data/io.github.retrozinndev.Colorshell.gresource.xml \
      --sourcedir ./data \
      --target ./build/resources.gresource
  '';

  postInstall = (old.postInstall or "") + ''
    cp -f ./build/resources.gresource "$out/share/colorshell/resources.gresource"
  '';
})
