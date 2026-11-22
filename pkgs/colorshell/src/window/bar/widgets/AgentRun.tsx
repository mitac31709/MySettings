import { createBinding } from "ags";
import { Gtk } from "ags/gtk4";
import AgentRunMonitor from "../../../modules/agent-run";
import Windows from "../..";

export const AgentRun = () => {
    const agent = AgentRunMonitor.getDefault();

    return (
        <Gtk.Button
            visible={createBinding(agent, "active")}
            class={createBinding(agent, "cssClass")}
            tooltipText={createBinding(agent, "tooltip")}
            onClicked={() => {
                if (!agent.active) return;
                Windows.getDefault().toggle("agent-run");
            }}
        >
            <Gtk.Box spacing={5} halign={Gtk.Align.CENTER} valign={Gtk.Align.CENTER}>
                <Gtk.Label class="agent-star" label="★" />
                <Gtk.Label class="agent-label number" label={createBinding(agent, "label")} />
            </Gtk.Box>
        </Gtk.Button>
    );
};
