import Tile from "../Tile";
import PowerSaveModule from "../../../../modules/power-save";
import { createBinding } from "ags";
import type Pages from "../pages";

export const TilePowerSave = (pages: Pages) => {
    const ps = PowerSaveModule.getDefault();

    return (
        <Tile
            title="省電力モード"
            icon={createBinding(ps, "iconName")}
            description={createBinding(ps, "tileDescription")}
            hasArrow
            state={createBinding(ps, "active")}
            onEnabled={() => {
                if (!ps.active) {
                    ps.turnOn();
                }
            }}
            onDisabled={() => {
                if (ps.active) {
                    ps.turnOff();
                }
            }}
            onClicked={() => pages.toggle("power-save")}
        />
    );
};
