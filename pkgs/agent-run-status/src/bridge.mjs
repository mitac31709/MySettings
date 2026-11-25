#!/usr/bin/env node
// Bridge between the local T3 Code server (v0.1.11 orchestration v2) and Colorshell.
// The daemon subscribes to orchestration shell/thread streams and writes
// $XDG_RUNTIME_DIR/agent-run-status.json. One-shot subcommands open their own
// short-lived socket so Approve / Deny / Stop do not depend on the daemon
// still holding the right request.

import { spawn } from "node:child_process";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { applyShellItem, applyThreadItem, createState, isLive, renderStatus } from "./aggregate.mjs";
import { discoverServer, readEnvironmentId, websocketUrl } from "./discover.mjs";
import { MOCK_NAMES, mockDocument } from "./fixtures.mjs";
import {
  DISPATCH_METHOD,
  SHELL_METHOD,
  THREAD_METHOD,
  SUPPORTED_T3_VERSION,
  approvalCommand,
  decodeIncoming,
  encodeAck,
  encodeInterrupt,
  encodeRequest,
  exitError,
  interruptCommand,
  versionSupported,
} from "./rpc.mjs";

const STATUS_NAME = "agent-run-status.json";
const SESSION_TTL = "30m";

function statusPath() {
  const root = process.env.XDG_RUNTIME_DIR || join(tmpdir(), `agent-run-status-${process.getuid?.() ?? "user"}`);
  return join(root, STATUS_NAME);
}

function bin(name, fallback) {
  const value = process.env[name];
  return value && value.trim() ? value.trim() : fallback;
}

function t3Bin() {
  return bin("AGENT_RUN_T3", "t3");
}

function desktopBin() {
  return bin("AGENT_RUN_T3_DESKTOP", "t3code-desktop");
}

function xdgOpenBin() {
  return bin("AGENT_RUN_XDG_OPEN", "xdg-open");
}

function run(argv, { timeoutMs = 20_000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(argv[0], argv.slice(1), { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error(`${argv[0]} timed out`));
    }, timeoutMs);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        const detail = stderr.trim() || stdout.trim() || `exit ${code}`;
        reject(new Error(`${argv[0]} ${argv.slice(1, 3).join(" ")} failed: ${detail}`));
        return;
      }
      resolve({ stdout, stderr });
    });
  });
}

async function issueSession() {
  const { stdout } = await run([
    t3Bin(),
    "auth",
    "session",
    "issue",
    "--json",
    "--ttl",
    SESSION_TTL,
    "--label",
    "colorshell-agent-run",
    "--subject",
    "colorshell",
  ]);
  const session = JSON.parse(stdout);
  if (!session?.token || !session?.sessionId) throw new Error("t3 auth session issue returned no token");
  return session;
}

async function revokeSession(sessionId) {
  if (!sessionId) return;
  try {
    await run([t3Bin(), "auth", "session", "revoke", sessionId], { timeoutMs: 10_000 });
  } catch (error) {
    console.error(`agent-run-status: revoke ${sessionId}: ${error.message}`);
  }
}

async function websocketTicket(http, token) {
  const headers = {
    authorization: `Bearer ${token}`,
    "content-type": "application/json",
  };
  let response = await fetch(`${http}/api/auth/websocket-ticket/rpc`, {
    method: "POST",
    headers,
    body: "{}",
  });
  if (response.status === 404) {
    response = await fetch(`${http}/api/auth/websocket-ticket`, {
      method: "POST",
      headers,
      body: "{}",
    });
  }
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`websocket ticket HTTP ${response.status}: ${text.slice(0, 200)}`);
  }
  const body = await response.json();
  if (!body?.ticket) throw new Error("websocket ticket response had no ticket");
  return body.ticket;
}

function connectSocket(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const fail = (error) => {
      ws.close();
      reject(error instanceof Error ? error : new Error(String(error)));
    };
    ws.addEventListener("open", () => resolve(ws), { once: true });
    ws.addEventListener("error", () => fail(new Error("websocket connection failed")), { once: true });
  });
}

function createRpc(ws) {
  let next = 1;
  const exits = new Map();
  const streams = new Map();
  ws.addEventListener("message", (event) => {
    let frames;
    try {
      frames = decodeIncoming(event.data);
    } catch (error) {
      console.error(`agent-run-status: bad rpc frame: ${error.message}`);
      return;
    }
    for (const frame of frames) {
      if (frame.type === "chunk") {
        ws.send(encodeAck(frame.requestId));
        const handler = streams.get(String(frame.requestId));
        if (handler) {
          for (const value of frame.values) handler(value);
        }
      } else if (frame.type === "exit") {
        const pending = exits.get(String(frame.requestId));
        if (pending) {
          exits.delete(String(frame.requestId));
          pending(frame.exit);
        }
      } else if (frame.type === "Defect" || frame.type === "ClientProtocolError") {
        console.error(`agent-run-status: ${frame.type}`);
      }
    }
  });
  return {
    stream(tag, payload, onValue) {
      const id = String(next);
      next += 1;
      streams.set(id, onValue);
      ws.send(encodeRequest(id, tag, payload));
      return id;
    },
    call(tag, payload, timeoutMs = 15_000) {
      const id = String(next);
      next += 1;
      ws.send(encodeRequest(id, tag, payload));
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          exits.delete(id);
          reject(new Error(`timed out waiting for ${tag}`));
        }, timeoutMs);
        exits.set(id, (exit) => {
          clearTimeout(timer);
          const error = exitError(exit);
          if (error) reject(new Error(error));
          else resolve(exit?.value);
        });
      });
    },
    interrupt(id) {
      if (!id) return;
      streams.delete(String(id));
      ws.send(encodeInterrupt(id));
    },
  };
}

async function readStatus() {
  try {
    return JSON.parse(await readFile(statusPath(), "utf8"));
  } catch {
    return null;
  }
}

async function writeStatus(doc, { replaceMock = false } = {}) {
  const path = statusPath();
  if (!replaceMock) {
    const current = await readStatus();
    if (current?.source === "mock" && doc.source !== "mock") return;
  }
  await mkdir(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.tmp`;
  await writeFile(tmp, `${JSON.stringify(doc)}\n`);
  await rename(tmp, path);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function withServer(fn) {
  const runtime = await discoverServer();
  if (!runtime) throw new Error("T3 Code server is not running ($T3CODE_HOME/userdata/server-runtime.json)");
  if (!versionSupported(runtime.serverVersion)) {
    throw new Error(
      `T3 Code ${runtime.serverVersion} is not the pinned RPC (expected ${SUPPORTED_T3_VERSION}). Update the bridge before using it.`,
    );
  }
  const session = await issueSession();
  let ws;
  try {
    const ticket = await websocketTicket(runtime.http, session.token);
    ws = await connectSocket(websocketUrl(runtime.http, ticket));
    const rpc = createRpc(ws);
    return await fn({ runtime, rpc, ws });
  } finally {
    try {
      ws?.close();
    } catch {
      /* already closed */
    }
    await revokeSession(session.sessionId);
  }
}

async function dispatchStored(threadId, build) {
  const doc = await readStatus();
  const thread = doc?.threads?.find((item) => item.id === threadId);
  if (!thread) throw new Error(`thread ${threadId} is not in ${statusPath()}`);
  const createdAt = new Date().toISOString();
  const command = build(thread, createdAt);
  await withServer(async ({ rpc }) => {
    await rpc.call(DISPATCH_METHOD, command);
  });
}

function spawnDetached(argv) {
  const child = spawn(argv[0], argv.slice(1), { detached: true, stdio: "ignore" });
  child.on("error", (error) => {
    console.error(`agent-run-status: ${argv[0]}: ${error.message}`);
  });
  child.unref();
  return child;
}

async function openThread(threadId) {
  const doc = await readStatus();
  const thread = doc?.threads?.find((item) => item.id === threadId);
  const url = thread?.openUrl;
  if (url) {
    spawnDetached([xdgOpenBin(), url]);
    return;
  }
  spawnDetached([desktopBin()]);
}

async function daemon() {
  let stopped = false;
  let activeSession = null;
  let activeSocket = null;
  const stop = () => {
    stopped = true;
    try {
      activeSocket?.close();
    } catch {
      /* already closed */
    }
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);

  while (!stopped) {
    try {
      await runDaemonSession({
        setSession(session) {
          activeSession = session;
        },
        setSocket(ws) {
          activeSocket = ws;
        },
      });
    } catch (error) {
      if (!stopped) console.error(`agent-run-status: ${error.message}`);
    } finally {
      if (activeSession) {
        await revokeSession(activeSession);
        activeSession = null;
      }
    }
    if (stopped) break;
    await sleep(2000);
  }

  const current = await readStatus();
  if (current?.source !== "mock") {
    await writeStatus(
      {
        source: "t3",
        updatedAt: new Date().toISOString(),
        connected: false,
        serverVersion: null,
        detail: null,
        threads: [],
      },
      { replaceMock: true },
    );
  }
}

async function writeIdle(detail, serverVersion = null) {
  const current = await readStatus();
  if (current?.source === "mock") return;
  const same =
    current?.source === "t3" &&
    current.connected === false &&
    (current.detail ?? null) === detail &&
    (current.serverVersion ?? null) === serverVersion &&
    Array.isArray(current.threads) &&
    current.threads.length === 0;
  if (same) return;
  await writeStatus({
    source: "t3",
    updatedAt: new Date().toISOString(),
    connected: false,
    serverVersion,
    detail,
    threads: [],
  });
}

async function runDaemonSession(hooks) {
  const runtime = await discoverServer();
  if (!runtime) {
    await writeIdle("T3 Code server is not running");
    throw new Error("T3 Code server is not running");
  }
  if (!versionSupported(runtime.serverVersion)) {
    await writeIdle(
      `RPC mismatch: server ${runtime.serverVersion}, bridge expects ${SUPPORTED_T3_VERSION}`,
      runtime.serverVersion,
    );
    throw new Error(`refusing T3 Code ${runtime.serverVersion}; bridge expects ${SUPPORTED_T3_VERSION}`);
  }

  const session = await issueSession();
  hooks.setSession(session.sessionId);
  const environmentId = await readEnvironmentId(runtime);
  const ticket = await websocketTicket(runtime.http, session.token);
  const ws = await connectSocket(websocketUrl(runtime.http, ticket));
  hooks.setSocket(ws);
  const rpc = createRpc(ws);
  const state = createState();
  const subscriptions = new Map();
  let publishTimer = null;

  const publish = () => {
    if (publishTimer) return;
    publishTimer = setTimeout(() => {
      publishTimer = null;
      const doc = renderStatus(state, Date.now(), {
        connected: true,
        serverVersion: runtime.serverVersion || SUPPORTED_T3_VERSION,
        environmentId,
        source: "t3",
      });
      writeStatus(doc, { replaceMock: true }).catch((error) => {
        console.error(`agent-run-status: write status: ${error.message}`);
      });
    }, 40);
  };

  const ensureThread = (threadId) => {
    if (!threadId || subscriptions.has(threadId)) return;
    const id = rpc.stream(THREAD_METHOD, { threadId, requestCompletionMarker: true }, (item) => {
      applyThreadItem(state, item);
      publish();
    });
    subscriptions.set(threadId, id);
  };

  const syncSubscriptions = () => {
    for (const thread of state.threads.values()) {
      if (isLive(thread) || (thread.seenActive && thread.finishedAtMs == null)) ensureThread(thread.id);
    }
  };

  rpc.stream(SHELL_METHOD, { requestCompletionMarker: true }, (item) => {
    applyShellItem(state, item);
    syncSubscriptions();
    publish();
  });

  await new Promise((resolve, reject) => {
    ws.addEventListener("close", () => resolve(), { once: true });
    ws.addEventListener("error", () => reject(new Error("websocket closed")), { once: true });
  });
  if (publishTimer) clearTimeout(publishTimer);
}

async function mock(name) {
  if (name === "clear") {
    await rm(statusPath(), { force: true });
    console.log(`cleared ${statusPath()}`);
    return;
  }
  const doc = mockDocument(name, Date.now());
  await writeStatus(doc, { replaceMock: true });
  console.log(`wrote ${doc.threads.length} mock thread(s) to ${statusPath()}`);
  console.log("Stop the bridge first if it is connected to T3, or the next event replaces this file:");
  console.log("  systemctl --user stop agent-run-status");
}

function usage() {
  console.log(`agent-run-status — T3 Code run card bridge for Colorshell

  daemon
  mock <${MOCK_NAMES.join("|")}|clear>
  approve <thread>
  deny <thread>
  stop <thread>
  open <thread>
  status

Status file: ${statusPath()}
Speaks t3code 0.1.11 orchestration RPC (protocol 2) only.
`);
}

const [command, arg] = process.argv.slice(2);

try {
  if (command === "daemon") {
    await daemon();
  } else if (command === "mock") {
    await mock(arg || "");
  } else if (command === "approve" && arg) {
    await dispatchStored(arg, (thread, createdAt) => {
      if (!thread.approval?.requestId) throw new Error(`${arg} has no pending approval`);
      return approvalCommand(thread.id, thread.approval.requestId, "accept");
    });
  } else if (command === "deny" && arg) {
    await dispatchStored(arg, (thread, createdAt) => {
      if (!thread.approval?.requestId) throw new Error(`${arg} has no pending approval`);
      return approvalCommand(thread.id, thread.approval.requestId, "decline");
    });
  } else if (command === "stop" && arg) {
    await dispatchStored(arg, (thread) => {
      if (!thread.runId) throw new Error(`${arg} has no active run`);
      return interruptCommand(thread.id, thread.runId);
    });
  } else if (command === "open" && arg) {
    await openThread(arg);
  } else if (command === "status") {
    const doc = await readStatus();
    console.log(JSON.stringify(doc ?? { threads: [] }, null, 2));
  } else {
    usage();
    process.exit(command ? 1 : 0);
  }
} catch (error) {
  console.error(`agent-run-status: ${error.message}`);
  process.exit(1);
}
