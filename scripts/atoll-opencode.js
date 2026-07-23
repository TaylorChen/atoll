// Atoll integration for OpenCode. This file is installed by install-hooks.py.
// It uses OpenCode's plugin events and Atoll's existing authenticated loopback
// gateway; no npm package or additional daemon is required.
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";

const endpointPath = `${homedir()}/.atoll/run/endpoint`;

async function endpoint() {
  const text = await readFile(endpointPath, "utf8");
  const values = Object.fromEntries(text.split("\n").filter(Boolean).map((line) => line.split("=", 2)));
  if (!values.ATOLL_PORT || !values.ATOLL_TOKEN) throw new Error("Atoll endpoint is incomplete");
  return values;
}

async function send(payload, hold = false) {
  const target = await endpoint();
  const body = new URLSearchParams({
    v: "1",
    bridge: "opencode-plugin-1",
    source: "opencode",
    cwd: payload.cwd || "",
    payload: JSON.stringify(payload),
  });
  if (hold) body.set("hold", "1");
  const response = await fetch(`http://127.0.0.1:${target.ATOLL_PORT}/hook/opencode`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "X-Atoll-Token": target.ATOLL_TOKEN,
    },
    body,
  });
  if (!response.ok) throw new Error(`Atoll returned ${response.status}`);
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

function hook(eventName, sessionID, cwd, extra = {}) {
  return {
    hook_event_name: eventName,
    session_id: `opencode-${sessionID}`,
    cwd: cwd || "",
    ...extra,
  };
}

function permissionBehavior(response) {
  return response?.hookSpecificOutput?.permissionDecision || "";
}

export default async ({ client, serverUrl }) => {
  const cwdBySession = new Map();
  const roles = new Map();
  const internalFetch = client?._client?.getConfig?.()?.fetch;
  const port = Number(serverUrl?.port) || 4096;

  async function replyPermission(id, response) {
    const behavior = permissionBehavior(response);
    if (!internalFetch || !behavior) return;
    const allow = behavior === "allow";
    const message = response?.hookSpecificOutput?.permissionDecisionReason;
    await internalFetch(new Request(`http://localhost:${port}/permission/${id}/reply`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ reply: allow ? "once" : "reject", message }),
    }));
  }

  return {
    event: async ({ event }) => {
      try {
        const p = event.properties || {};
        if (event.type === "session.created" && p.info?.id) {
          cwdBySession.set(p.info.id, p.info.directory || "");
          await send(hook("SessionStart", p.info.id, p.info.directory));
          return;
        }
        if (event.type === "session.deleted" && p.info?.id) {
          await send(hook("SessionEnd", p.info.id, cwdBySession.get(p.info.id)));
          cwdBySession.delete(p.info.id);
          return;
        }
        if (event.type === "session.status" && p.sessionID && p.status?.type === "idle") {
          await send(hook("Stop", p.sessionID, cwdBySession.get(p.sessionID)));
          return;
        }
        if (event.type === "message.updated" && p.info?.id) {
          roles.set(p.info.id, { role: p.info.role, sessionID: p.info.sessionID });
          return;
        }
        if (event.type === "message.part.updated" && p.part?.type === "text") {
          const meta = roles.get(p.part.messageID);
          if (meta?.role === "user" && p.part.text) {
            await send(hook("UserPromptSubmit", meta.sessionID, cwdBySession.get(meta.sessionID), {
              prompt: p.part.text,
            }));
          }
          return;
        }
        if (event.type === "message.part.updated" && p.part?.type === "tool" && p.part.sessionID) {
          const state = p.part.state?.status;
          const eventName = state === "running" || state === "pending" ? "PreToolUse"
            : state === "completed" || state === "error" ? "PostToolUse" : "";
          if (eventName) {
            await send(hook(eventName, p.part.sessionID, cwdBySession.get(p.part.sessionID), {
              tool_name: p.part.tool || "Tool",
              tool_input: p.part.state?.input || {},
            }));
          }
          return;
        }
        if (event.type === "permission.asked" && p.id && p.sessionID) {
          const toolName = p.permission || "Tool";
          const input = { patterns: p.patterns || [], metadata: p.metadata || {} };
          if (toolName === "bash") input.command = (p.patterns || []).join(" && ");
          // Keep OpenCode's own approval UI responsive while Atoll waits. Either
          // surface may resolve first; the later permission.replied event clears
          // the other side's stale card.
          void send(hook("PermissionRequest", p.sessionID,
            cwdBySession.get(p.sessionID), { tool_name: toolName, tool_input: input }), true)
            .then((response) => replyPermission(p.id, response))
            .catch((error) => console.error(`[Atoll] ${error instanceof Error ? error.message : String(error)}`));
          return;
        }
        if (event.type === "permission.replied" && p.sessionID) {
          await send(hook("PostToolUse", p.sessionID, cwdBySession.get(p.sessionID), {
            tool_name: p.permission || "Tool",
          }));
        }
      } catch (error) {
        // OpenCode remains authoritative when Atoll is unavailable. Report the
        // integration failure without breaking the user's agent session.
        console.error(`[Atoll] ${error instanceof Error ? error.message : String(error)}`);
      }
    },
  };
};
