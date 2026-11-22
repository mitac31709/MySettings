import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { HIDE_AFTER_MS, applyShellItem, applyThreadItem, createState, pastTense, renderStatus } from "./aggregate.mjs";
import { discoverServer, isAlive, loopbackOrigin, websocketUrl } from "./discover.mjs";
import { mockDocument } from "./fixtures.mjs";
import {
  approvalCommand,
  decodeIncoming,
  encodeAck,
  encodeRequest,
  interruptCommand,
  versionSupported,
} from "./rpc.mjs";

const NOW = Date.parse("2026-11-22T12:00:00.000Z");

function shellThread(overrides = {}) {
  return {
    id: "thread_1",
    projectId: "project_1",
    title: "Fix flaky checkout test",
    providerInstanceId: "claude",
    modelSelection: { instanceId: "claude", model: "sonnet" },
    status: "running",
    activityRunStatus: "running",
    activeRunId: "run_1",
    latestRunId: "run_1",
    latestRunStartedAt: "2026-11-22T11:59:47.000Z",
    pendingRuntimeRequest: null,
    latestVisibleMessage: null,
    updatedAt: "2026-11-22T11:59:55.000Z",
    createdAt: "2026-11-22T11:59:40.000Z",
    ...overrides,
  };
}

test("past tense rewrites a leading gerund and leaves finished wording", () => {
  assert.equal(pastTense("Editing src/billing/invoice.ts"), "Edited src/billing/invoice.ts");
  assert.equal(pastTense("Found 4 call sites"), "Found 4 call sites");
});

test("a running turn becomes a card and older tool rows are past tense", () => {
  const state = createState();
  applyShellItem(state, {
    kind: "snapshot",
    snapshot: {
      threads: [shellThread()],
      projects: [],
      snapshotSequence: 1,
      updatedAt: "2026-11-22T11:59:55.000Z",
    },
  });
  applyThreadItem(state, {
    kind: "snapshot",
    projection: {
      thread: { id: "thread_1", title: "Fix flaky checkout test" },
      turnItems: [
        {
          id: "a1",
          type: "file_search",
          title: "Reading 12 files",
          status: "completed",
          ordinal: 1,
          runId: "run_1",
          startedAt: "2026-11-22T11:59:48.000Z",
          completedAt: "2026-11-22T11:59:50.000Z",
        },
        {
          id: "a2",
          type: "file_change",
          fileName: "src/billing/invoice.ts",
          status: "running",
          ordinal: 2,
          runId: "run_1",
          startedAt: "2026-11-22T11:59:50.000Z",
          completedAt: null,
        },
      ],
      checkpoints: [],
      runtimeRequests: [],
    },
  });
  const doc = renderStatus(state, NOW, { connected: true, environmentId: "env_1", serverVersion: "0.1.8" });
  assert.equal(doc.threads.length, 1);
  const thread = doc.threads[0];
  assert.equal(thread.phase, "running");
  assert.equal(thread.provider, "Claude");
  assert.equal(thread.model, "sonnet");
  assert.equal(thread.step, 2);
  assert.deepEqual(thread.segments, ["done", "active"]);
  assert.equal(thread.rows[0].text, "Read 12 files");
  assert.equal(thread.rows[0].state, "done");
  assert.equal(thread.rows[1].text, "Editing src/billing/invoice.ts");
  assert.equal(thread.rows[1].state, "active");
  assert.equal(thread.rows[0].durationMs, 2000);
  assert.equal(thread.openUrl, "t3code://app/env_1/thread_1");
  assert.equal(thread.runId, "run_1");
});

test("a pending runtime request exposes approve and a resolution clears it", () => {
  const state = createState();
  applyShellItem(state, {
    kind: "thread.updated",
    location: "active",
    thread: shellThread({
      status: "waiting",
      pendingRuntimeRequest: { id: "req_9", kind: "command", createdAt: "2026-11-22T11:59:58.000Z" },
      updatedAt: "2026-11-22T11:59:58.000Z",
    }),
  });
  applyThreadItem(state, {
    kind: "event",
    event: {
      type: "turn-item.updated",
      occurredAt: "2026-11-22T11:59:58.000Z",
      payload: {
        id: "ap1",
        threadId: "thread_1",
        type: "approval_request",
        requestId: "req_9",
        prompt: "Run npm test",
        status: "waiting",
        ordinal: 3,
        runId: "run_1",
        startedAt: "2026-11-22T11:59:58.000Z",
      },
    },
  });
  const waiting = renderStatus(state, NOW, { connected: true });
  assert.equal(waiting.threads[0].phase, "approval");
  assert.equal(waiting.threads[0].approval.requestId, "req_9");
  assert.equal(waiting.threads[0].rows.at(-1).state, "approval");

  applyThreadItem(state, {
    kind: "event",
    event: {
      type: "runtime-request.updated",
      occurredAt: "2026-11-22T11:59:59.000Z",
      payload: { id: "req_9", threadId: "thread_1", status: "resolved", kind: "command" },
    },
  });
  applyShellItem(state, {
    kind: "thread.updated",
    location: "active",
    thread: shellThread({ pendingRuntimeRequest: null, status: "running", updatedAt: "2026-11-22T11:59:59.000Z" }),
  });
  const resumed = renderStatus(state, NOW, { connected: true });
  assert.equal(resumed.threads[0].phase, "running");
  assert.equal(resumed.threads[0].approval, null);
});

test("a checkpoint count and a finished run show a done card, then hide", () => {
  const state = createState();
  applyShellItem(state, { kind: "thread.updated", location: "active", thread: shellThread() });
  renderStatus(state, NOW, { connected: true });
  applyThreadItem(state, {
    kind: "event",
    event: {
      type: "checkpoint.captured",
      occurredAt: "2026-11-22T12:00:01.000Z",
      payload: { threadId: "thread_1", filesTotal: { count: 2, additions: 4, deletions: 1 } },
    },
  });
  applyShellItem(state, {
    kind: "thread.updated",
    location: "active",
    thread: shellThread({
      status: "completed",
      activityRunStatus: null,
      activeRunId: null,
      pendingRuntimeRequest: null,
      updatedAt: "2026-11-22T12:00:02.000Z",
    }),
  });
  const done = renderStatus(state, NOW + 1000, { connected: true });
  assert.equal(done.threads.length, 1);
  assert.equal(done.threads[0].phase, "done");
  assert.equal(done.threads[0].filesChanged, 2);
  assert.match(done.threads[0].action, /^Done in \d+s · 2 files changed$/);
  const hidden = renderStatus(state, NOW + 1000 + HIDE_AFTER_MS, { connected: true });
  assert.equal(hidden.threads.length, 0);
});

test("historical completed threads stay hidden until this process sees them run", () => {
  const state = createState();
  applyShellItem(state, {
    kind: "snapshot",
    snapshot: {
      threads: [
        shellThread({
          status: "completed",
          activityRunStatus: null,
          activeRunId: null,
          pendingRuntimeRequest: null,
        }),
      ],
    },
  });
  const doc = renderStatus(state, NOW, { connected: true });
  assert.equal(doc.threads.length, 0);
});

test("newer thread is listed first", () => {
  const state = createState();
  applyShellItem(state, {
    kind: "snapshot",
    snapshot: {
      threads: [
        shellThread({ id: "older", updatedAt: "2026-11-22T11:00:00.000Z" }),
        shellThread({ id: "newer", updatedAt: "2026-11-22T11:59:00.000Z" }),
      ],
    },
  });
  const doc = renderStatus(state, NOW, { connected: true });
  assert.deepEqual(
    doc.threads.map((thread) => thread.id),
    ["newer", "older"],
  );
});

test("rpc frames round-trip and commands match the v0.1.8 contract", () => {
  const raw = encodeRequest("7", "orchestration.subscribeShell", { requestCompletionMarker: true });
  const request = JSON.parse(raw);
  assert.equal(request._tag, "Request");
  assert.equal(request.tag, "orchestration.subscribeShell");
  assert.deepEqual(request.headers, []);
  const frames = decodeIncoming(
    JSON.stringify({
      _tag: "Chunk",
      requestId: "7",
      values: [{ kind: "synchronized" }],
    }),
  );
  assert.equal(frames[0].type, "chunk");
  assert.equal(encodeAck(frames[0].requestId), JSON.stringify({ _tag: "Ack", requestId: "7" }));
  const approval = approvalCommand("thread_1", "req_9", "decline");
  assert.equal(approval.type, "runtime-request.respond");
  assert.equal(approval.decision, "decline");
  assert.equal(approval.requestId, "req_9");
  assert.equal(approval.createdAt, undefined);
  const stop = interruptCommand("thread_1", "run_1");
  assert.equal(stop.type, "run.interrupt");
  assert.equal(stop.runId, "run_1");
  assert.equal(versionSupported("0.1.8"), true);
  assert.equal(versionSupported(""), true);
  assert.equal(versionSupported("0.0.42"), false);
});

test("server discovery keeps a live loopback record and skips a dead pid", async () => {
  assert.equal(loopbackOrigin("http://0.0.0.0:3773"), "http://127.0.0.1:3773");
  assert.equal(loopbackOrigin("http://192.168.1.20:3773"), null);
  assert.equal(isAlive(process.pid), true);
  const home = await mkdtemp(join(tmpdir(), "agent-run-"));
  const liveDir = join(home, "userdata");
  await mkdir(liveDir, { recursive: true });
  await writeFile(
    join(liveDir, "server-runtime.json"),
    `${JSON.stringify({
      version: 1,
      pid: process.pid,
      port: 3773,
      origin: "http://127.0.0.1:3773",
      startedAt: "2026-11-22T11:00:00.000Z",
      serverVersion: "0.1.8",
    })}\n`,
  );
  await mkdir(join(home, "dev"), { recursive: true });
  await writeFile(
    join(home, "dev", "server-runtime.json"),
    `${JSON.stringify({
      version: 1,
      pid: 2147483646,
      port: 1,
      origin: "http://127.0.0.1:1",
      startedAt: "2026-11-22T12:00:00.000Z",
      serverVersion: "0.1.8",
    })}\n`,
  );
  const found = await discoverServer({ T3CODE_HOME: home }, home);
  assert.equal(found.http, "http://127.0.0.1:3773");
  assert.equal(found.serverVersion, "0.1.8");
  const url = new URL(websocketUrl(found.http, "ticket value"));
  assert.equal(url.pathname, "/ws");
  assert.equal(url.searchParams.get("wsTicket"), "ticket value");
  assert.equal(url.searchParams.get("orchestrationProtocol"), "2");
});

test("mock documents cover the card phases", () => {
  const now = NOW;
  assert.equal(mockDocument("running", now).threads[0].phase, "running");
  assert.equal(mockDocument("approval", now).threads[0].phase, "approval");
  assert.equal(mockDocument("approval", now).threads[0].approval.requestId, "approval_mock");
  assert.match(mockDocument("done", now).threads[0].action, /Done in 13s · 6 files changed/);
  assert.equal(mockDocument("multi", now).threads.length, 2);
  assert.equal(mockDocument("multi", now).source, "mock");
});
