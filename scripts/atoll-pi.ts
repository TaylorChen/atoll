// @atoll-managed-pi-extension
// Atoll integration for Pi (pi-coding-agent). Installed by install-hooks.py
// into ~/.pi/agent/extensions/, where Pi auto-discovers it. Monitoring only:
// Pi has no native permission prompt, so this never blocks a tool call.
//
// Events are translated into Claude-compatible hook payloads and posted to
// Atoll's authenticated loopback gateway (/hook/pi); the app parses them with
// the shared Claude parser. No npm package or extra daemon is required.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, resolve } from "node:path";

const ENDPOINT_PATH = `${homedir()}/.atoll/run/endpoint`;
const POST_TIMEOUT_MS = 1000;
// Events must stay ordered (PreToolUse before PostToolUse), so this is a FIFO
// rather than a latest-only slot. The cap keeps a stalled gateway from growing
// the queue without bound; the oldest events are dropped first.
const MAX_QUEUE = 64;

type Payload = Record<string, unknown>;

const queue: Payload[] = [];
let draining: Promise<void> | null = null;
let warned = false;

function warnOnce(message: string): void {
  if (warned) return;
  warned = true;
  console.warn(`[atoll] ${message}`);
}

function endpoint(): { port: string; token: string } | null {
  let text: string;
  try {
    text = readFileSync(ENDPOINT_PATH, "utf8");
  } catch (error) {
    // Atoll isn't running: Pi simply works without the island.
    if ((error as { code?: string }).code === "ENOENT") return null;
    throw error;
  }
  const values: Record<string, string> = {};
  for (const line of text.split("\n")) {
    const i = line.indexOf("=");
    if (i > 0) values[line.slice(0, i)] = line.slice(i + 1).trim();
  }
  if (!values.ATOLL_PORT || !values.ATOLL_TOKEN) throw new Error("Atoll endpoint file is incomplete");
  return { port: values.ATOLL_PORT, token: values.ATOLL_TOKEN };
}

async function post(payload: Payload): Promise<void> {
  const target = endpoint();
  if (!target) return;
  const body = new URLSearchParams({
    v: "1",
    bridge: "pi-extension-1",
    source: "pi",
    cwd: String(payload.cwd ?? ""),
    payload: JSON.stringify(payload),
  });
  let response: Response;
  try {
    response = await fetch(`http://127.0.0.1:${target.port}/hook/pi`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded", "X-Atoll-Token": target.token },
      body,
      signal: AbortSignal.timeout(POST_TIMEOUT_MS),
    });
  } catch (error) {
    // A stale endpoint file after Atoll quit: same as "not running".
    const code = (error as { cause?: { code?: string } }).cause?.code;
    if (code === "ECONNREFUSED") return;
    throw error;
  }
  if (!response.ok) throw new Error(`Atoll gateway returned ${response.status}`);
}

function drain(): Promise<void> {
  if (!draining) {
    draining = (async () => {
      while (queue.length) {
        const next = queue.shift()!;
        try {
          await post(next);
        } catch (error) {
          warnOnce(`event delivery failed: ${error instanceof Error ? error.message : String(error)}`);
        }
      }
      draining = null;
    })();
  }
  return draining;
}

function enqueue(payload: Payload): void {
  if (queue.length >= MAX_QUEUE) {
    queue.shift();
    warnOnce("Atoll gateway is not keeping up; dropping oldest events");
  }
  queue.push(payload);
  // Off Pi's critical path: handlers return without awaiting delivery.
  void drain();
}

// Pi's built-in tools → the Claude tool names/arguments Atoll already renders.
const TOOL_NAMES: Record<string, string> = {
  bash: "Bash", read: "Read", edit: "Edit", write: "Write", grep: "Grep", find: "Glob", ls: "Glob",
};

function toolInput(tool: string, args: Payload, cwd: string): Payload {
  const path = typeof args.path === "string" ? args.path : "";
  const absolute = path && !isAbsolute(path) ? resolve(cwd, path) : path;
  switch (tool) {
    case "read": case "edit": case "write": return { file_path: absolute };
    case "grep": case "find": return { pattern: args.pattern };
    case "ls": return { pattern: absolute || cwd };
    default: return args;
  }
}

function resultText(result: unknown): string {
  const content = (result as { content?: Array<{ type?: string; text?: string }> } | null)?.content;
  if (!Array.isArray(content)) return "";
  return content.filter((part) => part.type === "text" && part.text).map((part) => part.text).join("\n");
}

export default function (pi: any): void {
  function hook(eventName: string, ctx: any, extra: Payload = {}): void {
    const sessionID = ctx?.sessionManager?.getSessionId?.();
    if (typeof sessionID !== "string" || !sessionID) return;
    const model = ctx?.model?.name ?? ctx?.model?.id;
    enqueue({
      hook_event_name: eventName,
      session_id: `pi-${sessionID}`,
      cwd: ctx?.cwd ?? "",
      ...(model ? { model: { display_name: String(model) } } : {}),
      ...extra,
    });
  }

  pi.on("session_start", (_event: any, ctx: any) => hook("SessionStart", ctx));
  pi.on("before_agent_start", (event: any, ctx: any) =>
    hook("UserPromptSubmit", ctx, { prompt: String(event?.prompt ?? "") }));
  pi.on("tool_execution_start", (event: any, ctx: any) => {
    const tool = String(event?.toolName ?? "");
    hook("PreToolUse", ctx, {
      tool_name: TOOL_NAMES[tool] ?? tool,
      tool_use_id: event?.toolCallId,
      tool_input: toolInput(tool, event?.args ?? {}, ctx?.cwd ?? ""),
    });
  });
  pi.on("tool_execution_end", (event: any, ctx: any) => {
    const tool = String(event?.toolName ?? "");
    hook(event?.isError ? "PostToolUseFailure" : "PostToolUse", ctx, {
      tool_name: TOOL_NAMES[tool] ?? tool,
      tool_use_id: event?.toolCallId,
      tool_response: resultText(event?.result),
    });
  });
  pi.on("session_before_compact", (_event: any, ctx: any) => hook("PreCompact", ctx));
  // agent_end may be followed by an auto-retry or queued follow-up; settled
  // is the point where Pi is really waiting on the user again.
  pi.on("agent_settled", (_event: any, ctx: any) => hook("Stop", ctx));
  pi.on("session_shutdown", async (_event: any, ctx: any) => {
    hook("SessionEnd", ctx);
    // Pi may exit right after shutdown; give queued events one bounded chance.
    await Promise.race([drain(), new Promise((r) => setTimeout(r, POST_TIMEOUT_MS).unref?.())]);
  });
}
