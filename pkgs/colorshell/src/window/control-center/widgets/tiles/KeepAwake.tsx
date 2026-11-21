import Tile from "../Tile";
import KeepAwakeModule from "../../../../modules/keep-awake";
import { createBinding } from "ags";
import type Pages from "../pages";

export const TileKeepAwake = (pages: Pages) => {
    const ka = KeepAwakeModule.getDefault();

    return (
        <Tile
            title="画面常時オン"
            icon={createBinding(ka, "iconName")}
            description={createBinding(ka, "tileDescription")}
            hasArrow
            state={createBinding(ka, "awakeOn")}
            onEnabled={() => {
                if (!ka.awakeOn) {
                    ka.turnOn();
                }
            }}
            onDisabled={() => {
                if (ka.awakeOn) {
                    ka.turnOff(false);
                }
            }}
            onClicked={() => pages.toggle("keep-awake")}
        />
    );
};
