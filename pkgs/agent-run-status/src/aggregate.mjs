// Fold t3code 0.1.8 orchestration v2 shell + thread RPC items into the
// Colorshell status card. Method and command names match
// packages/contracts/src/orchestrationV2.ts at tag v0.1.8.

export const HIDE_AFTER_MS = 8000;
export const MAX_ROWS = 5;
export const MAX_SEGMENTS = 12;
export const MAX_ITEMS = 40;

const LIVE_STATUSES = new Set(["preparing", "queued", "starting", "running", "waiting"]);
const APPROVAL_KINDS = new Set([
  "command",
  "file-read",
  "file-change",
  "dynamic_tool_call",
  "mcp-elicitation",
]);
const STEP_TYPES = new Set(["file_change", "command_execution", "file_search", "web_search"]);

const PAST = [
  [/^reading\b/i, "Read"],
  [/^editing\b/i, "Edited"],
  [/^writing\b/i, "Wrote"],
  [/^running\b/i, "Ran"],
  [/^searching\b/i, "Searched"],
  [/^finding\b/i, "Found"],
  [/^planning\b/i, "Planned"],
  [/^checking\b/i, "Checked"],
  [/^looking\b/i, "Looked"],
  [/^creating\b/i, "Created"],
  [/^updating\b/i, "Updated"],
  [/^deleting\b/i, "Deleted"],
  [/^applying\b/i, "Applied"],
  [/^testing\b/i, "Tested"],
  [/^opening\b/i, "Opened"],
  [/^listing\b/i, "Listed"],
  [/^analyzing\b/i, "Analyzed"],
  [/^thinking\b/i, "Thought"],
  [/^waiting\b/i, "Waited"],
];

export function pastTense(summary) {
  const text = String(summary ?? "").trim();
  for (const [pattern, replacement] of PAST) {
    if (pattern.test(text)) return text.replace(pattern, replacement);
  }
  return text;
}

export function createState() {
  return { threads: new Map() };
}

function ensure(state, id) {
  let thread = state.threads.get(id);
  if (!thread) {
    thread = {
      id,
      title: "",
      model: "",
      instanceId: "",
      status: "idle",
      activityRunStatus: null,
      activeRunId: null,
      latestRunId: null,
      startedAt: null,
      pending: null,
      settledAt: null,
      items: [],
      filesChanged: null,
      headline: "",
      updatedAt: null,
      createdAt: null,
      seenActive: false,
      finishedAtMs: null,
      phaseHold: null,
      removed: false,
    };
    state.threads.set(id, thread);
  }
  return thread;
}

function providerLabel(instanceId) {
  const id = String(instanceId || "");
  if (!id) return "";
  const key = id.toLowerCase();
  if (key === "claude" || key.startsWith("claude")) return "Claude";
  if (key === "cursor" || key.startsWith("cursor")) return "Cursor";
  if (key === "opencode" || key.startsWith("opencode")) return "OpenCode";
  if (key === "codex" || key.startsWith("codex")) return "Codex";
  return id;
}

function firstLine(value) {
  const text = String(value || "").trim();
  if (!text) return "";
  return text.split("\n", 1)[0].slice(0, 160);
}

export function itemText(item) {
  if (!item || typeof item !== "object") return "";
  if (typeof item.title === "string" && item.title.trim()) return item.title.trim();
  switch (item.type) {
    case "file_change":
      return `Editing ${item.fileName || "a file"}`;
    case "command_execution":
      return `Running ${firstLine(item.input) || "a command"}`;
    case "file_search":
      return `Searching ${item.pattern || "files"}`;
    case "web_search":
      return "Searching the web";
    case "approval_request":
      return firstLine(item.prompt || item.reason) || "Waiting for approval";
    case "user_input_request":
      return "Waiting for input";
    case "error":
      return firstLine(item.failure?.message) || "Something failed";
    default:
      return "";
  }
}

export function rowKind(item) {
  const type = String(item?.type || "");
  if (type === "approval_request" || type === "user_input_request") return "approval";
  if (type === "error") return "error";
  if (type === "command_execution") return "command";
  if (type === "file_change") return "edit";
  if (type === "file_search" || type === "web_search") return "search";
  if (type.includes("read")) return "read";
  if (item?.toolSurface || item?.toolIcon) return "tool";
  return "info";
}

function countsAsStep(item) {
  if (STEP_TYPES.has(item?.type)) return true;
  return rowKind(item) === "tool" || rowKind(item) === "read";
}

function isApprovalKind(kind) {
  return APPROVAL_KINDS.has(kind);
}

export function isLive(thread) {
  if (!thread || thread.removed) return false;
  if (thread.pending && thread.pending.status !== "resolved") return true;
  if (LIVE_STATUSES.has(thread.status)) return true;
  if (LIVE_STATUSES.has(thread.activityRunStatus)) return true;
  return false;
}

function normalizePending(raw) {
  if (!raw || typeof raw !== "object" || typeof raw.id !== "string" || !raw.id) return null;
  const status = typeof raw.status === "string" ? raw.status : "pending";
  if (status !== "pending") return null;
  return {
    id: raw.id,
    kind: typeof raw.kind === "string" ? raw.kind : "",
    status,
    summary: "",
  };
}

function mergeShell(state, shell) {
  if (!shell || typeof shell.id !== "string" || !shell.id) return;
  const thread = ensure(state, shell.id);
  if (typeof shell.title === "string" && shell.title) thread.title = shell.title;
  if (shell.modelSelection && typeof shell.modelSelection === "object") {
    if (typeof shell.modelSelection.model === "string") thread.model = shell.modelSelection.model;
  }
  if (typeof shell.providerInstanceId === "string") thread.instanceId = shell.providerInstanceId;
  if (typeof shell.status === "string") thread.status = shell.status;
  if ("activityRunStatus" in shell) thread.activityRunStatus = shell.activityRunStatus ?? null;
  if ("activeRunId" in shell) thread.activeRunId = shell.activeRunId ?? null;
  if ("latestRunId" in shell) thread.latestRunId = shell.latestRunId ?? null;
  const started =
    shell.activityRunStartedAt || shell.latestRunStartedAt || shell.latestRunRequestedAt || null;
  if (typeof started === "string") thread.startedAt = started;
  if ("pendingRuntimeRequest" in shell) {
    thread.pending = normalizePending(shell.pendingRuntimeRequest);
  }
  if ("settledAt" in shell) thread.settledAt = shell.settledAt ?? null;
  if (shell.latestVisibleMessage && typeof shell.latestVisibleMessage.text === "string") {
    thread.headline = firstLine(shell.latestVisibleMessage.text);
  }
  if (typeof shell.updatedAt === "string") thread.updatedAt = shell.updatedAt;
  if (typeof shell.createdAt === "string") thread.createdAt = shell.createdAt;
  if (shell.archivedAt) thread.removed = false;
}

function upsertItem(thread, raw) {
  const text = itemText(raw);
  if (!raw || typeof raw.id !== "string" || !text) return;
  const item = {
    id: raw.id,
    type: typeof raw.type === "string" ? raw.type : "",
    text,
    status: typeof raw.status === "string" ? raw.status : "",
    ordinal: Number.isFinite(raw.ordinal) ? raw.ordinal : thread.items.length,
    startedAt: typeof raw.startedAt === "string" ? raw.startedAt : null,
    completedAt: typeof raw.completedAt === "string" ? raw.completedAt : null,
    runId: typeof raw.runId === "string" ? raw.runId : null,
    toolSurface: raw.toolSurface ?? null,
    toolIcon: raw.toolIcon ?? null,
    requestId: typeof raw.requestId === "string" ? raw.requestId : null,
  };
  const index = thread.items.findIndex((entry) => entry.id === item.id);
  if (index >= 0) thread.items[index] = item;
  else thread.items.push(item);
  thread.items.sort((a, b) => a.ordinal - b.ordinal);
  if (thread.items.length > MAX_ITEMS) thread.items.splice(0, thread.items.length - MAX_ITEMS);
  if (item.type === "approval_request" && item.requestId && item.status !== "completed") {
    thread.pending = {
      id: item.requestId,
      kind: "command",
      status: "pending",
      summary: item.text,
    };
  }
}

function rememberFiles(thread, payload) {
  if (!payload || typeof payload !== "object") return;
  if (payload.filesTotal && Number.isFinite(payload.filesTotal.count)) {
    thread.filesChanged = payload.filesTotal.count;
    return;
  }
  if (Array.isArray(payload.files)) thread.filesChanged = payload.files.length;
}

export function applyShellItem(state, item) {
  if (!item || typeof item !== "object") return;
  if (item.kind === "snapshot" && item.snapshot && typeof item.snapshot === "object") {
    const ids = new Set();
    const threads = [
      ...(Array.isArray(item.snapshot.threads) ? item.snapshot.threads : []),
      ...(Array.isArray(item.snapshot.archivedThreads) ? item.snapshot.archivedThreads : []),
    ];
    for (const shell of threads) {
      if (!shell?.id) continue;
      ids.add(shell.id);
      mergeShell(state, shell);
      const thread = state.threads.get(shell.id);
      if (thread) thread.removed = false;
    }
    for (const [id, thread] of state.threads) {
      if (!ids.has(id)) thread.removed = true;
    }
    return;
  }
  if (item.kind === "thread.updated" && item.thread) {
    mergeShell(state, item.thread);
    const thread = state.threads.get(item.thread.id);
    if (thread) thread.removed = item.location === "archive" ? thread.removed : false;
    if (thread && item.location !== "archive") thread.removed = false;
    return;
  }
  if (item.kind === "thread.removed" && typeof item.threadId === "string") {
    const thread = state.threads.get(item.threadId);
    if (thread) thread.removed = true;
  }
}

export function applyThreadItem(state, item) {
  if (!item || typeof item !== "object") return;
  if (item.kind === "snapshot" && item.projection && typeof item.projection === "object") {
    const projection = item.projection;
    const meta = projection.thread;
    if (meta?.id) mergeShell(state, meta);
    const thread = meta?.id ? ensure(state, meta.id) : null;
    if (!thread) return;
    thread.items = [];
    const turnItems = Array.isArray(projection.turnItems) ? projection.turnItems : [];
    for (const raw of turnItems) upsertItem(thread, raw);
    if (Array.isArray(projection.checkpoints)) {
      const latest = [...projection.checkpoints].reverse().find((entry) => entry && entry.filesTotal);
      if (latest) rememberFiles(thread, latest);
    }
    if (Array.isArray(projection.runtimeRequests)) {
      const pending = [...projection.runtimeRequests].reverse().find((entry) => entry?.status === "pending");
      if (pending) thread.pending = normalizePending(pending);
    }
    return;
  }
  if (item.kind !== "event" || !item.event || typeof item.event !== "object") return;
  const event = item.event;
  const payload = event.payload && typeof event.payload === "object" ? event.payload : {};
  const threadId = typeof payload.threadId === "string" ? payload.threadId : null;
  if (!threadId) return;
  const thread = ensure(state, threadId);
  switch (event.type) {
    case "turn-item.updated":
      upsertItem(thread, payload);
      break;
    case "runtime-request.updated":
      if (payload.status === "pending") thread.pending = normalizePending(payload);
      else if (thread.pending && thread.pending.id === payload.id) thread.pending = null;
      break;
    case "checkpoint.captured":
      rememberFiles(thread, payload);
      break;
    case "run.updated":
      if (typeof payload.status === "string" && (payload.id === thread.activeRunId || payload.id === thread.latestRunId)) {
        thread.status = payload.status;
      }
      break;
    default:
      break;
  }
  if (typeof event.occurredAt === "string") thread.updatedAt = event.occurredAt;
}

export function observe(state, now) {
  for (const thread of state.threads.values()) {
    if (isLive(thread)) {
      thread.seenActive = true;
      thread.finishedAtMs = null;
      thread.phaseHold = null;
      continue;
    }
    if (thread.seenActive && thread.finishedAtMs == null) {
      thread.finishedAtMs = now;
      thread.phaseHold = thread.status === "failed" ? "error" : "done";
    }
  }
}

function runItems(thread) {
  const runId = thread.activeRunId || thread.latestRunId;
  if (!runId) return thread.items;
  const scoped = thread.items.filter((item) => item.runId === runId || item.runId == null);
  return scoped.length > 0 ? scoped : thread.items;
}

function durationMs(item, next, now, live) {
  const start = Date.parse(item.startedAt || "");
  if (!Number.isFinite(start)) return null;
  if (item.completedAt) {
    const end = Date.parse(item.completedAt);
    if (Number.isFinite(end) && end >= start) return end - start;
  }
  if (next?.startedAt) {
    const end = Date.parse(next.startedAt);
    if (Number.isFinite(end) && end >= start) return end - start;
  }
  if (live) return Math.max(0, now - start);
  return null;
}

function doneHeadline(startedAt, finishedAtMs, filesChanged) {
  const start = Date.parse(startedAt ?? "");
  const end = finishedAtMs ?? Date.now();
  const seconds =
    Number.isFinite(start) && end >= start ? Math.max(1, Math.round((end - start) / 1000)) : null;
  const time =
    seconds == null ? null : seconds < 60 ? `${seconds}s` : `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  const head = time ? `Done in ${time}` : "Done";
  if (typeof filesChanged !== "number") return head;
  const noun = filesChanged === 1 ? "file" : "files";
  return `${head} · ${filesChanged} ${noun} changed`;
}

function presentThread(thread, now, environmentId) {
  const live = isLive(thread);
  const pending = thread.pending;
  const waiting = live && pending;
  const approval = waiting && isApprovalKind(pending.kind);
  const phase = waiting ? "approval" : live ? "running" : thread.phaseHold === "error" ? "error" : "done";
  const items = runItems(thread).filter(countsAsStep);
  const last = items.length > 0 ? items[items.length - 1] : null;
  const currentIsStep = last ? last.status === "running" || last.status === "waiting" || last.status === "pending" : false;
  let completed = items.length;
  let active = false;
  if (phase === "running" || phase === "approval") {
    active = true;
    if (currentIsStep) completed = Math.max(0, items.length - 1);
  }
  const segments = [];
  if (phase === "done" || phase === "error") {
    const filled = Math.max(items.length, 1);
    for (let i = 0; i < filled; i += 1) segments.push("done");
  } else {
    for (let i = 0; i < completed; i += 1) segments.push("done");
    if (active) segments.push("active");
  }
  const visibleSegments = segments.length > MAX_SEGMENTS ? segments.slice(segments.length - MAX_SEGMENTS) : segments;
  const tail = items.slice(-MAX_ROWS);
  const tailOffset = items.length - tail.length;
  const rows = tail.map((item, index) => {
    const absolute = tailOffset + index;
    const current = live && absolute === items.length - 1;
    const kind = rowKind(item);
    const highlighted = current && phase === "approval";
    return {
      kind,
      text: current || highlighted ? item.text : pastTense(item.text),
      durationMs: durationMs(item, items[absolute + 1], now, current),
      state: highlighted ? "approval" : current ? "active" : "done",
    };
  });
  if (phase === "approval" && pending && !rows.some((row) => row.state === "approval")) {
    rows.push({
      kind: "approval",
      text: pending.summary || (approval ? "Waiting for approval" : "Waiting for input"),
      durationMs: null,
      state: "approval",
    });
    if (rows.length > MAX_ROWS) rows.shift();
  }

  let action = last?.text || thread.headline || thread.title || "Working";
  let actionKind = last ? rowKind(last) : "info";
  if (phase === "approval") {
    action = pending.summary || last?.text || (approval ? "Waiting for approval" : "Waiting for input");
    actionKind = "approval";
  } else if (phase === "error") {
    action = last?.text || thread.headline || "Stopped";
    actionKind = "error";
  } else if (phase === "done") {
    action = doneHeadline(thread.startedAt, thread.finishedAtMs, thread.filesChanged);
    actionKind = "done";
  }

  const step =
    phase === "done" || phase === "error" ? Math.max(items.length, 1) : Math.max(items.length, active ? 1 : 0);

  return {
    id: thread.id,
    title: thread.title,
    phase,
    provider: providerLabel(thread.instanceId),
    model: thread.model,
    action,
    actionKind,
    step,
    segments: visibleSegments,
    startedAt: thread.startedAt || thread.createdAt,
    finishedAt: thread.finishedAtMs == null ? null : new Date(thread.finishedAtMs).toISOString(),
    filesChanged: thread.filesChanged,
    approval: approval ? { requestId: pending.id, summary: action } : null,
    runId: thread.activeRunId || thread.latestRunId,
    openUrl: environmentId
      ? `t3code://app/${encodeURIComponent(environmentId)}/${encodeURIComponent(thread.id)}`
      : null,
    updatedAt: thread.updatedAt,
    rows,
  };
}

function showing(thread, now) {
  if (isLive(thread)) return true;
  if (!thread.seenActive || thread.finishedAtMs == null) return false;
  return now - thread.finishedAtMs < HIDE_AFTER_MS;
}

export function projectThreads(state, now, environmentId) {
  const threads = [];
  for (const thread of state.threads.values()) {
    if (!showing(thread, now)) continue;
    threads.push(presentThread(thread, now, environmentId));
  }
  threads.sort((a, b) => String(b.updatedAt || "").localeCompare(String(a.updatedAt || "")));
  return threads;
}

export function renderStatus(state, now, context = {}) {
  observe(state, now);
  return {
    source: context.source || "t3",
    updatedAt: new Date(now).toISOString(),
    connected: Boolean(context.connected),
    serverVersion: context.serverVersion || null,
    detail: context.detail || null,
    threads: projectThreads(state, now, context.environmentId || null),
  };
}
