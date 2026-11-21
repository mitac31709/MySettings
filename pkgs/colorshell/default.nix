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

    cp ${./src/window/center-window/index.tsx} src/window/center-window/index.tsx

    cp ${./src/window/control-center/widgets/BatteryInfo.tsx} src/window/control-center/widgets/BatteryInfo.tsx
    cp ${./src/window/control-center/widgets/tiles/KeepAwake.tsx} src/window/control-center/widgets/tiles/KeepAwake.tsx
    cp ${./src/window/control-center/widgets/pages/KeepAwake.tsx} src/window/control-center/widgets/pages/KeepAwake.tsx
    cp ${./src/window/control-center/widgets/pages/Services.tsx} src/window/control-center/widgets/pages/Services.tsx

    substituteInPlace src/window/bar/index.tsx \
      --replace-fail \
        'import { Tray } from "./widgets/Tray";' \
        $'import { Tray } from "./widgets/Tray";\nimport { Cheatsheet } from "./widgets/Cheatsheet";\nimport { ResticBackup } from "./widgets/ResticBackup";\nimport { SystemStats } from "./widgets/SystemStats";\nimport { KeepAwake } from "./widgets/KeepAwake";\nimport { Services } from "./widgets/Services";\nimport { JQuake } from "./widgets/JQuake";\nimport { StartupSound } from "./widgets/StartupSound";\nimport { Updates } from "./widgets/Updates";' \
      --replace-fail \
        '<Apps />' \
        $'<Apps />\n                    <Cheatsheet />' \
      --replace-fail \
        '<Tray />' \
        $'<ResticBackup />\n                    <SystemStats />\n                    <KeepAwake />\n                    <Services />\n                    <JQuake />\n                    <StartupSound />\n                    <Updates />\n                    <Tray />'

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

    printf '\n' >> data/css/main.css
    cat ${./css/main-extra.css} >> data/css/main.css

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
