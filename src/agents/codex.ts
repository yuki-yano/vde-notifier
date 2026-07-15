import { closeSync, existsSync, openSync, readSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { env as processEnv } from "node:process";
import {
  asNonEmptyString,
  defaultAgentTitle,
  extractCodexMessage,
  resolveCodexSound,
  type AgentContext
} from "./context";

const CODEX_THREAD_ID_PATTERN = /^[0-9a-f-]{16,128}$/i;
const MAX_SESSION_META_READ_BYTES = 128 * 1024;

export const isCodexTitleGenerationPayload = (payload: Record<string, unknown>): boolean => {
  if (payload.type !== "agent-turn-complete") {
    return false;
  }

  const message = asNonEmptyString(payload["last-assistant-message"]);
  if (message === undefined) {
    return false;
  }

  try {
    const parsed = JSON.parse(message);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      return false;
    }

    const record = parsed as Record<string, unknown>;
    return Object.keys(record).length === 1 && asNonEmptyString(record.title) !== undefined;
  } catch {
    return false;
  }
};

const asCodexThreadId = (value: unknown): string | undefined => {
  const threadId = asNonEmptyString(value);
  if (typeof threadId !== "string") {
    return undefined;
  }
  return CODEX_THREAD_ID_PATTERN.test(threadId) ? threadId : undefined;
};

const extractCodexThreadId = (payload: Record<string, unknown>): string | undefined => {
  return (
    asCodexThreadId(payload["thread-id"]) ??
    asCodexThreadId((payload as { thread_id?: unknown }).thread_id) ??
    asCodexThreadId((payload as { threadId?: unknown }).threadId)
  );
};

const findCodexSessionRolloutPath = (threadId: string): string | undefined => {
  const home = asNonEmptyString(processEnv.HOME);
  if (typeof home !== "string") {
    return undefined;
  }

  const sessionsRoot = resolve(home, ".codex", "sessions");
  if (!existsSync(sessionsRoot)) {
    return undefined;
  }

  try {
    const years = readdirSync(sessionsRoot, { withFileTypes: true });
    for (const year of years) {
      if (!year.isDirectory()) {
        continue;
      }
      const yearPath = join(sessionsRoot, year.name);
      const months = readdirSync(yearPath, { withFileTypes: true });
      for (const month of months) {
        if (!month.isDirectory()) {
          continue;
        }
        const monthPath = join(yearPath, month.name);
        const days = readdirSync(monthPath, { withFileTypes: true });
        for (const day of days) {
          if (!day.isDirectory()) {
            continue;
          }
          const dayPath = join(monthPath, day.name);
          const files = readdirSync(dayPath, { withFileTypes: true });
          for (const file of files) {
            if (!file.isFile()) {
              continue;
            }
            if (!file.name.startsWith("rollout-") || !file.name.endsWith(`${threadId}.jsonl`)) {
              continue;
            }
            return join(dayPath, file.name);
          }
        }
      }
    }
  } catch {
    return undefined;
  }

  return undefined;
};

const readFirstJsonLine = (filePath: string): string | undefined => {
  let fd: number | undefined;
  try {
    fd = openSync(filePath, "r");
    const chunkSize = 4096;
    const buffer = Buffer.alloc(chunkSize);
    let position = 0;
    let line = "";
    while (position < MAX_SESSION_META_READ_BYTES) {
      const bytesToRead = Math.min(chunkSize, MAX_SESSION_META_READ_BYTES - position);
      const bytesRead = readSync(fd, buffer, 0, bytesToRead, position);
      if (bytesRead <= 0) {
        break;
      }
      const chunk = buffer.toString("utf8", 0, bytesRead);
      const newlineIndex = chunk.indexOf("\n");
      if (newlineIndex >= 0) {
        line += chunk.slice(0, newlineIndex);
        break;
      }
      line += chunk;
      position += bytesRead;
    }
    const trimmed = line.trim();
    return trimmed.length > 0 ? trimmed : undefined;
  } catch {
    return undefined;
  } finally {
    if (typeof fd === "number") {
      try {
        closeSync(fd);
      } catch {
        // Ignore close failures after a read failure.
      }
    }
  }
};

const isSubagentSessionSource = (source: unknown): boolean => {
  if (typeof source === "string") {
    return source.toLowerCase().startsWith("subagent");
  }
  if (source === null || typeof source !== "object") {
    return false;
  }
  const record = source as Record<string, unknown>;
  return (
    Object.prototype.hasOwnProperty.call(record, "subagent") || Object.prototype.hasOwnProperty.call(record, "subAgent")
  );
};

const isNonInteractiveSessionSource = (source: unknown): boolean => {
  if (typeof source !== "string") {
    return false;
  }
  const normalized = source.toLowerCase();
  return normalized === "exec" || normalized === "review";
};

const resolveCodexSessionSource = (threadId: string): unknown => {
  const rolloutPath = findCodexSessionRolloutPath(threadId);
  if (typeof rolloutPath !== "string") {
    return undefined;
  }

  const firstLine = readFirstJsonLine(rolloutPath);
  if (typeof firstLine !== "string") {
    return undefined;
  }

  try {
    const parsed = JSON.parse(firstLine) as { payload?: unknown };
    if (parsed === null || typeof parsed !== "object") {
      return undefined;
    }
    const payload = parsed.payload;
    if (payload === null || typeof payload !== "object") {
      return undefined;
    }
    return (payload as { source?: unknown }).source;
  } catch {
    return undefined;
  }
};

const resolveCodexSessionContext = (threadId: string): Pick<AgentContext, "isSubagent" | "isNonInteractive"> => {
  const source = resolveCodexSessionSource(threadId);
  if (source === undefined) {
    return {};
  }

  return {
    isSubagent: isSubagentSessionSource(source),
    isNonInteractive: isNonInteractiveSessionSource(source)
  };
};

export const parseCodexContext = (rawPayload: string): AgentContext | undefined => {
  try {
    const parsed = JSON.parse(rawPayload);
    if (parsed === null || typeof parsed !== "object") {
      return undefined;
    }
    const record = parsed as Record<string, unknown>;
    const threadId = extractCodexThreadId(record);
    const sessionContext = typeof threadId === "string" ? resolveCodexSessionContext(threadId) : {};
    return {
      rawPayload,
      message: extractCodexMessage(record),
      title: defaultAgentTitle("codex"),
      sound: resolveCodexSound(record),
      threadId,
      isTitleGeneration: isCodexTitleGenerationPayload(record),
      ...sessionContext
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Failed to parse Codex payload JSON: ${message}`);
  }
};
