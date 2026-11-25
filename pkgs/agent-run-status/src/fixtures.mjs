// Hand-built status documents for Colorshell, matching the card schema
// `renderStatus` writes. `now` is milliseconds so the elapsed timer looks live.

function iso(ms) {
  return new Date(ms).toISOString();
}

function base(now, threads) {
  return {
    source: "mock",
    updatedAt: iso(now),
    connected: false,
    serverVersion: "0.1.11",
    detail: null,
    threads,
  };
}

export function mockDocument(name, now = Date.now()) {
  if (name === "running") return base(now, [runningThread(now)]);
  if (name === "approval") return base(now, [approvalThread(now)]);
  if (name === "done") return base(now, [doneThread(now)]);
  if (name === "multi") {
    return base(now, [approvalThread(now, "thread_mock_b"), runningThread(now - 20_000, "thread_mock_a")]);
  }
  throw new Error(`unknown mock "${name}" (running, approval, done, multi)`);
}

function runningThread(now, id = "thread_mock_run") {
  return {
    id,
    title: "Fix flaky checkout test",
    phase: "running",
    provider: "Claude",
    model: "Sonnet 5.5",
    action: "Editing src/billing/invoice.ts",
    actionKind: "edit",
    step: 3,
    segments: ["done", "done", "active"],
    startedAt: iso(now - 5_000),
    finishedAt: null,
    filesChanged: null,
    approval: null,
    runId: `${id}_run`,
    openUrl: `t3code://app/env_mock/${id}`,
    updatedAt: iso(now),
    rows: [
      { kind: "read", text: "Read 12 files", durationMs: 1900, state: "done" },
      { kind: "search", text: "Found 4 call sites", durationMs: 1500, state: "done" },
      { kind: "edit", text: "Editing src/billing/invoice.ts", durationMs: 1000, state: "active" },
    ],
  };
}

function approvalThread(now, id = "thread_mock_approval") {
  return {
    id,
    title: "Apply billing patch",
    phase: "approval",
    provider: "Cursor",
    model: "composer-2.5",
    action: "Run npm test",
    actionKind: "approval",
    step: 2,
    segments: ["done", "active"],
    startedAt: iso(now - 42_000),
    finishedAt: null,
    filesChanged: null,
    approval: { requestId: "approval_mock", summary: "Run npm test" },
    runId: `${id}_run`,
    openUrl: `t3code://app/env_mock/${id}`,
    updatedAt: iso(now),
    rows: [
      { kind: "edit", text: "Edited src/billing/invoice.ts", durationMs: 2400, state: "done" },
      { kind: "approval", text: "Run npm test", durationMs: 800, state: "approval" },
    ],
  };
}

function doneThread(now, id = "thread_mock_done") {
  const started = now - 13_000;
  return {
    id,
    title: "Fix flaky checkout test",
    phase: "done",
    provider: "Claude",
    model: "Sonnet 5.5",
    action: "Done in 13s · 6 files changed",
    actionKind: "done",
    step: 3,
    segments: ["done", "done", "done"],
    startedAt: iso(started),
    finishedAt: iso(now - 500),
    filesChanged: 6,
    approval: null,
    runId: `${id}_run`,
    openUrl: `t3code://app/env_mock/${id}`,
    updatedAt: iso(now),
    rows: [
      { kind: "read", text: "Read 12 files", durationMs: 1900, state: "done" },
      { kind: "search", text: "Found 4 call sites", durationMs: 1500, state: "done" },
      { kind: "edit", text: "Edited src/billing/invoice.ts", durationMs: 3200, state: "done" },
    ],
  };
}

export const MOCK_NAMES = ["running", "approval", "done", "multi"];
