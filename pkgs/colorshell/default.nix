# Customizes upstream Colorshell with MySettings native integrations:
# - 1-1: Flake / .deb updates indicator (bar Updates widget watching XDG_RUNTIME_DIR/flake-update-status)
# - 1-2: Multi-timezone + GPST (tzdata leap-seconds) + UNIX clock tooltip, CenterWindow world clocks & NTP sync
# - 1-3: Direct sysfs battery telemetry (voltage / Wh / health / W / ETA / 0% gauge anomaly detection) in Bar & Control Center
{
  baseColorshell,
  glib,
}:

baseColorshell.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    cp ${./src/modules/worldclock.ts} src/modules/worldclock.ts
    cp ${./src/modules/sysfs-battery.ts} src/modules/sysfs-battery.ts
    cp ${./src/modules/updates.ts} src/modules/updates.ts
    cp ${./src/window/bar/widgets/Updates.tsx} src/window/bar/widgets/Updates.tsx
    cp ${./src/window/bar/widgets/Clock.tsx} src/window/bar/widgets/Clock.tsx
    cp ${./src/window/bar/widgets/Status.tsx} src/window/bar/widgets/Status.tsx
    cp ${./src/window/center-window/index.tsx} src/window/center-window/index.tsx
    cp ${./src/window/control-center/widgets/BatteryInfo.tsx} src/window/control-center/widgets/BatteryInfo.tsx

    substituteInPlace src/window/bar/index.tsx \
      --replace-fail \
        'import { Tray } from "./widgets/Tray";' \
        $'import { Tray } from "./widgets/Tray";\nimport { Updates } from "./widgets/Updates";' \
      --replace-fail \
        '<Tray />' \
        $'<Updates />\n                    <Tray />'

    substituteInPlace src/window/control-center/index.tsx \
      --replace-fail \
        'import { Sliders } from "./widgets/Sliders";' \
        $'import { Sliders } from "./widgets/Sliders";\nimport { BatteryInfo } from "./widgets/BatteryInfo";' \
      --replace-fail \
        '<Sliders ccWindow={this as ControlCenterWindow} />' \
        $'<Sliders ccWindow={this as ControlCenterWindow} />\n                                    <BatteryInfo />'

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
