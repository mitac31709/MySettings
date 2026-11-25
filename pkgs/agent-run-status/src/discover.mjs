import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export function isAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return Boolean(error && error.code === "EPERM");
  }
}

export function candidateRuntimePaths(env = process.env, home = homedir()) {
  const roots = [];
  const fromEnv = typeof env.T3CODE_HOME === "string" ? env.T3CODE_HOME.trim() : "";
  if (fromEnv) roots.push(fromEnv);
  const fallback = join(home, ".t3");
  if (!roots.includes(fallback)) roots.push(fallback);
  const paths = [];
  for (const root of roots) {
    paths.push(join(root, "userdata", "server-runtime.json"));
    paths.push(join(root, "dev", "server-runtime.json"));
  }
  return paths;
}

/** Bearer tokens stay on loopback. Wildcard binds are rewritten to 127.0.0.1. */
export function loopbackOrigin(origin) {
  let url;
  try {
    url = new URL(origin);
  } catch {
    return null;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  if (url.hostname === "0.0.0.0" || url.hostname === "::" || url.hostname === "[::]") {
    url.hostname = "127.0.0.1";
  }
  const host = url.hostname.replace(/^\[|\]$/g, "");
  if (host !== "127.0.0.1" && host !== "localhost" && host !== "::1") return null;
  url.pathname = "";
  url.search = "";
  url.hash = "";
  return url.toString().replace(/\/$/, "");
}

export function websocketUrl(httpOrigin, ticket) {
  const url = new URL(httpOrigin);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  url.pathname = "/ws";
  url.search = "";
  url.searchParams.set("wsTicket", ticket);
  url.searchParams.set("orchestrationProtocol", "2");
  return url.toString();
}

export async function readRuntimeFile(path) {
  let raw;
  try {
    raw = JSON.parse(await readFile(path, "utf8"));
  } catch {
    return null;
  }
  if (!raw || raw.version !== 1 || typeof raw.origin !== "string" || !Number.isInteger(raw.pid)) {
    return null;
  }
  if (!isAlive(raw.pid)) return null;
  const http = loopbackOrigin(raw.origin);
  if (!http) return null;
  return {
    pid: raw.pid,
    origin: raw.origin,
    http,
    port: raw.port,
    startedAt: typeof raw.startedAt === "string" ? raw.startedAt : "",
    serverVersion: typeof raw.serverVersion === "string" ? raw.serverVersion : "",
    path,
  };
}

export async function discoverServer(env = process.env, home = homedir()) {
  const found = [];
  for (const path of candidateRuntimePaths(env, home)) {
    const state = await readRuntimeFile(path);
    if (state) found.push(state);
  }
  found.sort((a, b) => b.startedAt.localeCompare(a.startedAt));
  return found[0] ?? null;
}

export async function readEnvironmentId(runtime) {
  if (!runtime?.path) return null;
  try {
    const text = (await readFile(join(dirname(runtime.path), "environment-id"), "utf8")).trim();
    if (!text || /[\s/]/.test(text) || text.length > 200) return null;
    return text;
  } catch {
    return null;
  }
}
