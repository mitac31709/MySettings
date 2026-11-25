// Effect RPC JSON envelopes used by t3code 0.1.11.
// The websocket frame is one JSON value. The upgrade URL must carry
// orchestrationProtocol=2. Streams must be Ack'd or the server latch stays closed.

export const SUPPORTED_T3_VERSION = "0.1.11";
export const ORCHESTRATION_PROTOCOL = "2";

export const SHELL_METHOD = "orchestration.subscribeShell";
export const THREAD_METHOD = "orchestration.subscribeThread";
export const DISPATCH_METHOD = "orchestration.dispatchCommand";

export function versionSupported(version) {
  if (version == null || version === "") return true;
  return version === SUPPORTED_T3_VERSION;
}

export function encodeRequest(id, tag, payload) {
  return JSON.stringify({
    _tag: "Request",
    id,
    tag,
    payload,
    headers: [],
  });
}

export function encodeAck(requestId) {
  return JSON.stringify({ _tag: "Ack", requestId });
}

export function encodeInterrupt(requestId) {
  return JSON.stringify({ _tag: "Interrupt", requestId });
}

/**
 * Split one websocket message into protocol frames.
 * @returns {Array<{ type: string, requestId?: string|number, values?: unknown[], exit?: unknown, raw: unknown }>}
 */
export function decodeIncoming(data) {
  const text = typeof data === "string" ? data : Buffer.from(data).toString("utf8");
  const trimmed = text.trim();
  if (!trimmed) return [];
  const parsed = JSON.parse(trimmed);
  const messages = Array.isArray(parsed) ? parsed : [parsed];
  const frames = [];
  for (const raw of messages) {
    if (!raw || typeof raw !== "object") continue;
    if (raw._tag === "Chunk") {
      frames.push({
        type: "chunk",
        requestId: raw.requestId,
        values: Array.isArray(raw.values) ? raw.values : [],
        raw,
      });
    } else if (raw._tag === "Exit") {
      frames.push({
        type: "exit",
        requestId: raw.requestId,
        exit: raw.exit,
        raw,
      });
    } else if (raw._tag === "Pong" || raw._tag === "Defect" || raw._tag === "ClientProtocolError") {
      frames.push({ type: raw._tag, raw });
    }
  }
  return frames;
}

export function exitError(exit) {
  if (!exit || exit._tag === "Success") return null;
  try {
    return JSON.stringify(exit.cause ?? exit);
  } catch {
    return "command failed";
  }
}

export function commandId() {
  return `colorshell-${crypto.randomUUID()}`;
}

export function approvalCommand(threadId, requestId, decision) {
  return {
    type: "runtime-request.respond",
    commandId: commandId(),
    threadId,
    requestId,
    decision,
  };
}

export function interruptCommand(threadId, runId) {
  return {
    type: "run.interrupt",
    commandId: commandId(),
    threadId,
    runId,
  };
}
