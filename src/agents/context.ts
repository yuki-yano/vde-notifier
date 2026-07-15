import { basename } from "node:path";
import { env as processEnv, stdin as processStdin } from "node:process";

export type AgentContext = {
  readonly rawPayload?: string;
  readonly title?: string;
  readonly message?: string;
  readonly sound?: string;
  readonly threadId?: string;
  readonly isTitleGeneration?: boolean;
  readonly isSubagent?: boolean;
  readonly isNonInteractive?: boolean;
};

export const asNonEmptyString = (value: unknown): string | undefined => {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
};

export const readStdin = async (): Promise<string> => {
  if (processStdin.isTTY) {
    return "";
  }

  const chunks: string[] = [];
  for await (const chunk of processStdin) {
    chunks.push(typeof chunk === "string" ? chunk : chunk.toString("utf8"));
  }

  return chunks.join("").trim();
};

const resolveRepositoryDisplayName = (): string => {
  try {
    const cwd = process.cwd();
    const name = basename(cwd);
    if (typeof name === "string" && name.length > 0 && name !== "." && name !== "/") {
      return name;
    }
  } catch {
    // Ignore resolution failures and use the stable fallback title.
  }
  return "Repository";
};

export const defaultAgentTitle = (agent: "codex" | "claude"): string => {
  const repo = resolveRepositoryDisplayName();
  return agent === "codex" ? `Codex: ${repo}` : `Claude: ${repo}`;
};

export const extractCodexMessage = (payload: Record<string, unknown>): string | undefined => {
  const direct = asNonEmptyString(payload["last-assistant-message"]);
  if (typeof direct === "string") {
    return direct;
  }

  const lastAgentMessage = asNonEmptyString((payload as { last_agent_message?: unknown }).last_agent_message);
  if (typeof lastAgentMessage === "string") {
    return lastAgentMessage;
  }

  const messageField = asNonEmptyString(payload.message);
  if (typeof messageField === "string") {
    return messageField;
  }

  const messages = payload.messages;
  if (Array.isArray(messages)) {
    for (let index = messages.length - 1; index >= 0; index -= 1) {
      const entry = messages[index];
      if (entry === null || typeof entry !== "object") {
        continue;
      }

      const roleValue = (entry as { role?: unknown }).role;
      const role = typeof roleValue === "string" ? roleValue.trim() : "";
      if (role !== "assistant") {
        continue;
      }

      const contentValue = (entry as { content?: unknown }).content;
      if (typeof contentValue === "string") {
        const text = asNonEmptyString(contentValue);
        if (typeof text === "string") {
          return text;
        }
      }

      if (Array.isArray(contentValue)) {
        for (const part of contentValue) {
          if (part === null || typeof part !== "object") {
            continue;
          }
          const text = asNonEmptyString((part as { text?: string }).text);
          if (typeof text === "string") {
            return text;
          }
        }
      }
    }
  }

  const transcript = payload.transcript;
  if (transcript !== null && typeof transcript === "object") {
    const messageObject = (transcript as { message?: unknown }).message;
    if (messageObject !== null && typeof messageObject === "object") {
      const contentArray = (messageObject as { content?: unknown }).content;
      if (Array.isArray(contentArray) && contentArray.length > 0) {
        const lastPart = contentArray[contentArray.length - 1];
        if (lastPart !== null && typeof lastPart === "object") {
          const text = asNonEmptyString((lastPart as { text?: string }).text);
          if (typeof text === "string") {
            return text;
          }
        }
      }
    }
  }

  return undefined;
};

const extractSoundNameFromPath = (soundPath: string): string | undefined => {
  const segments = soundPath.split("/");
  const last = segments[segments.length - 1];
  if (!last) {
    return undefined;
  }
  const base = last.replace(/\.[^/.]+$/, "");
  return base.length > 0 ? base : undefined;
};

export const resolveCodexSound = (payload: Record<string, unknown>): string | undefined => {
  const envValue = asNonEmptyString(processEnv.CODEX_NOTIFICATION_SOUND);
  const raw = Object.prototype.hasOwnProperty.call(payload, "sound") ? payload.sound : envValue;

  if (raw === undefined || raw === null) {
    return undefined;
  }

  if (typeof raw === "boolean") {
    return raw ? "Glass" : "None";
  }

  if (typeof raw === "number") {
    return raw === 0 ? "None" : undefined;
  }

  const stringValue = asNonEmptyString(raw);
  if (typeof stringValue !== "string") {
    return undefined;
  }

  const lower = stringValue.toLowerCase();
  if (lower === "none") {
    return "None";
  }
  if (lower === "true") {
    return "Glass";
  }
  if (lower === "false") {
    return "None";
  }
  if (lower === "default" || lower === "glass") {
    return "Glass";
  }

  if (stringValue.includes("/")) {
    return extractSoundNameFromPath(stringValue) ?? "Glass";
  }

  return stringValue;
};
