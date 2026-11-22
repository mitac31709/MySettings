import { Astal, Gdk, Gtk } from "ags/gtk4";
import GLib from "gi://GLib?version=2.0";
import Pango from "gi://Pango?version=1.0";
import AgentRunMonitor, { AgentRunThread } from "../../modules/agent-run";
import Windows from "..";

const { TOP, RIGHT } = Astal.WindowAnchor;

type Clock = {
    label: Gtk.Label;
    startedAt: string | null;
    finishedAt: string | null;
    phase: string;
};

type Star = {
    label: Gtk.Label;
    phase: string;
};

function formatClock(ms: number): string {
    const total = Math.max(0, Math.floor(ms / 1000));
    const minutes = Math.floor(total / 60);
    const seconds = total % 60;
    return `${minutes}:${String(seconds).padStart(2, "0")}`;
}

function formatDuration(ms: number | null | undefined): string {
    if (ms == null || !Number.isFinite(ms) || ms < 0) return "";
    if (ms < 10_000) {
        const seconds = ms / 1000;
        const text = seconds < 10 ? seconds.toFixed(1).replace(/\.0$/, "") : String(Math.round(seconds));
        return `${text}s`;
    }
    const total = Math.round(ms / 1000);
    const minutes = Math.floor(total / 60);
    const seconds = total % 60;
    if (minutes <= 0) return `${seconds}s`;
    return `${minutes}m ${seconds}s`;
}

function elapsedMs(startedAt: string | null, finishedAt: string | null, phase: string): number {
    const start = Date.parse(startedAt || "");
    if (!Number.isFinite(start)) return 0;
    const end = phase === "done" || phase === "error"
        ? Date.parse(finishedAt || "") || Date.now()
        : Date.now();
    return Math.max(0, end - start);
}

function headerMark(thread: AgentRunThread): string {
    if (thread.phase === "done") return "✓";
    if (thread.phase === "error") return "!";
    return "★";
}

function kindIcon(kind: string | undefined): string {
    switch (kind) {
        case "read":
            return "document-open-symbolic";
        case "edit":
            return "document-edit-symbolic";
        case "command":
            return "utilities-terminal-symbolic";
        case "search":
            return "system-search-symbolic";
        case "approval":
            return "dialog-question-symbolic";
        case "error":
            return "dialog-error-symbolic";
        case "done":
            return "object-select-symbolic";
        default:
            return "emblem-system-symbolic";
    }
}

function ellipsize(label: Gtk.Label): void {
    label.ellipsize = Pango.EllipsizeMode.END;
    label.xalign = 0;
}

function textButton(label: string, css: string, onClick: () => void): Gtk.Button {
    const button = new Gtk.Button({ label });
    button.add_css_class("agent-btn");
    button.add_css_class(css);
    button.connect("clicked", onClick);
    return button;
}

function renderSection(
    thread: AgentRunThread,
    agent: AgentRunMonitor,
    clocks: Clock[],
    stars: Star[],
): Gtk.Box {
    const section = new Gtk.Box({ orientation: Gtk.Orientation.VERTICAL, spacing: 8 });
    section.add_css_class("agent-section");
    section.add_css_class(thread.phase || "running");

    const header = new Gtk.Box({ spacing: 8 });
    const star = new Gtk.Label({ label: headerMark(thread) });
    star.add_css_class("agent-mark");
    star.add_css_class(thread.phase || "running");
    stars.push({ label: star, phase: thread.phase || "running" });
    const action = new Gtk.Label({
        label: thread.action || thread.title || "Working",
        hexpand: true,
    });
    action.add_css_class("agent-action");
    ellipsize(action);
    const clock = new Gtk.Label({ label: "0:00" });
    clock.add_css_class("agent-clock");
    clocks.push({
        label: clock,
        startedAt: thread.startedAt || null,
        finishedAt: thread.finishedAt || null,
        phase: thread.phase || "running",
    });
    header.append(star);
    header.append(action);
    header.append(clock);

    const sub = new Gtk.Box({ spacing: 8 });
    const who = [thread.provider, thread.model].filter((part) => part && part.trim()).join(" · ");
    const meta = new Gtk.Label({
        label: who || thread.title || "",
        hexpand: true,
    });
    meta.add_css_class("agent-meta");
    ellipsize(meta);
    const step = new Gtk.Label({ label: `Step ${thread.step ?? 0}` });
    step.add_css_class("agent-step");
    sub.append(meta);
    sub.append(step);

    const bar = new Gtk.Box({ spacing: 4, homogeneous: true });
    bar.add_css_class("agent-bar");
    const segments = thread.segments && thread.segments.length > 0 ? thread.segments : ["active"];
    for (const segment of segments) {
        const piece = new Gtk.Box();
        piece.add_css_class("agent-seg");
        piece.add_css_class(segment);
        piece.set_size_request(8, 5);
        bar.append(piece);
    }

    const log = new Gtk.Box({ orientation: Gtk.Orientation.VERTICAL, spacing: 2 });
    for (const row of thread.rows || []) {
        const line = new Gtk.Box({ spacing: 8 });
        line.add_css_class("agent-row");
        line.add_css_class(row.state || "done");
        const icon = new Gtk.Image({ iconName: kindIcon(row.kind) });
        icon.add_css_class("agent-row-icon");
        const text = new Gtk.Label({ label: row.text || "", hexpand: true });
        text.add_css_class("agent-row-text");
        ellipsize(text);
        const duration = new Gtk.Label({ label: formatDuration(row.durationMs) });
        duration.add_css_class("agent-row-time");
        line.append(icon);
        line.append(text);
        line.append(duration);
        log.append(line);
    }

    const footer = new Gtk.Box({ spacing: 8, halign: Gtk.Align.END });
    footer.add_css_class("agent-footer");
    const id = thread.id || "";
    if (thread.phase === "approval" && thread.approval?.requestId) {
        footer.append(textButton("Approve", "approve", () => agent.command(["approve", id])));
        footer.append(textButton("Deny", "deny", () => agent.command(["deny", id])));
    }
    if (thread.phase === "running" || thread.phase === "approval") {
        footer.append(textButton("Stop", "stop", () => agent.command(["stop", id])));
    }
    footer.append(textButton("Open run ↗", "open", () => agent.command(["open", id])));

    section.append(header);
    section.append(sub);
    section.append(bar);
    if ((thread.rows || []).length > 0) section.append(log);
    section.append(footer);
    return section;
}

export const AgentRunCard = Windows.forFocusedMonitor(() => {
    const agent = AgentRunMonitor.getDefault();

    return (
        <Astal.Window
            namespace="agent-run"
            class="agent-run-window"
            layer={Astal.Layer.TOP}
            anchor={TOP | RIGHT}
            exclusivity={Astal.Exclusivity.IGNORE}
            keymode={Astal.Keymode.ON_DEMAND}
            marginTop={54}
            marginRight={10}
            $={(self) => {
                const controller = Gtk.EventControllerKey.new();
                self.add_controller(controller);
                const keyId = controller.connect("key-released", (_controller, keyval) => {
                    if (keyval === Gdk.KEY_Escape) self.close();
                });
                const activeId = agent.connect("notify::active", () => {
                    if (!agent.active && Windows.getDefault().isOpen("agent-run")) {
                        Windows.getDefault().close("agent-run");
                    }
                });
                self.connect("destroy", () => {
                    try {
                        controller.disconnect(keyId);
                    } catch {
                        /* controller already dropped */
                    }
                    try {
                        agent.disconnect(activeId);
                    } catch {
                        /* monitor already dropped */
                    }
                });
            }}
        >
            <Gtk.Box
                orientation={Gtk.Orientation.VERTICAL}
                class="agent-run-card"
                widthRequest={360}
                $={(box) => {
                    const clocks: Clock[] = [];
                    const stars: Star[] = [];

                    const paint = () => {
                        for (const clock of clocks) {
                            clock.label.set_label(formatClock(
                                elapsedMs(clock.startedAt, clock.finishedAt, clock.phase),
                            ));
                        }
                        for (const star of stars) {
                            const pulse = agent.pulseDim && star.phase !== "done" && star.phase !== "error";
                            if (pulse) star.label.add_css_class("pulse-dim");
                            else star.label.remove_css_class("pulse-dim");
                        }
                    };

                    const rebuild = () => {
                        let child = box.get_first_child();
                        while (child) {
                            const next = child.get_next_sibling();
                            box.remove(child);
                            child = next;
                        }
                        clocks.length = 0;
                        stars.length = 0;
                        agent.threads.forEach((thread, index) => {
                            if (index > 0) {
                                const gap = new Gtk.Box();
                                gap.add_css_class("agent-gap");
                                box.append(gap);
                            }
                            box.append(renderSection(thread, agent, clocks, stars));
                        });
                        paint();
                    };

                    const payloadId = agent.connect("notify::payload", rebuild);
                    const timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 250, () => {
                        paint();
                        return GLib.SOURCE_CONTINUE;
                    });
                    rebuild();
                    box.connect("destroy", () => {
                        try {
                            agent.disconnect(payloadId);
                        } catch {
                            /* monitor already dropped */
                        }
                        GLib.source_remove(timer);
                    });
                }}
            />
        </Astal.Window>
    );
});
