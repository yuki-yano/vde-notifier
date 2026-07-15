import { existsSync, readFileSync } from "node:fs";
import { basename, join, relative, resolve } from "node:path";
import { env as processEnv } from "node:process";
import { spawnSync } from "node:child_process";
import {
  asNonEmptyString,
  defaultAgentTitle,
  extractCodexMessage,
  readStdin,
  resolveCodexSound,
  type AgentContext
} from "./context";

type ProcessInfo = {
  readonly parentPid: number;
  readonly command: string;
};

const CLAUDE_DEFAULT_TITLE = defaultAgentTitle("claude");
const CLAUDE_PARENT_PROCESS_SCAN_DEPTH = 16;

const isPathWithinBase = (target: string, base: string): boolean => {
  const relativePath = relative(base, target);
  if (relativePath === "") {
    return true;
  }
  if (relativePath.startsWith("..")) {
    return false;
  }
  if (relativePath.includes("../") || relativePath.includes("..\\")) {
    return false;
  }
  return true;
};

const resolveClaudeTranscriptPath = (rawPath: unknown): string | undefined => {
  const home = asNonEmptyString(processEnv.HOME);
  const inputPath = asNonEmptyString(rawPath);
  if (typeof inputPath !== "string" || inputPath.length === 0) {
    return undefined;
  }

  const expanded = inputPath.startsWith("~/") && typeof home === "string" ? join(home, inputPath.slice(2)) : inputPath;
  const absolute = resolve(expanded);

  const allowedBases =
    typeof home === "string"
      ? [resolve(home, ".claude", "projects"), resolve(home, ".config", "claude", "projects")]
      : [];

  if (allowedBases.length > 0 && !allowedBases.some((base) => isPathWithinBase(absolute, base))) {
    return undefined;
  }

  if (!existsSync(absolute)) {
    return undefined;
  }

  return absolute;
};

const extractTextFromClaudeMessage = (message: Record<string, unknown>): string | undefined => {
  const direct = asNonEmptyString((message as { text?: string }).text);
  if (typeof direct === "string") {
    return direct;
  }

  const content = (message as { content?: unknown }).content;
  if (typeof content === "string") {
    const textValue = asNonEmptyString(content);
    if (typeof textValue === "string") {
      return textValue;
    }
  }

  if (Array.isArray(content)) {
    for (const part of content) {
      if (typeof part === "string") {
        const textValue = asNonEmptyString(part);
        if (typeof textValue === "string") {
          return textValue;
        }
        continue;
      }
      if (part !== null && typeof part === "object") {
        const textValue = asNonEmptyString((part as { text?: string }).text);
        if (typeof textValue === "string") {
          return textValue;
        }
      }
    }
  }

  return undefined;
};

const readClaudeTranscript = (transcriptPath: string): string | undefined => {
  try {
    const content = readFileSync(transcriptPath, { encoding: "utf8" });
    const lines = content.split(/\r?\n/);
    for (let index = lines.length - 1; index >= 0; index -= 1) {
      const line = lines[index]?.trim();
      if (!line) {
        continue;
      }
      try {
        const parsedLine = JSON.parse(line) as { message?: unknown };
        const message = parsedLine.message;
        if (message === null || typeof message !== "object") {
          continue;
        }
        const role = asNonEmptyString((message as { role?: string }).role);
        if (typeof role === "string" && role !== "assistant") {
          continue;
        }
        const text = extractTextFromClaudeMessage(message as Record<string, unknown>);
        if (typeof text === "string" && text.length > 0) {
          return text;
        }
      } catch {
        // Skip malformed transcript lines and continue searching backwards.
      }
    }
  } catch {
    return undefined;
  }

  return undefined;
};

const extractClaudeTitle = (payload: Record<string, unknown>): string | undefined => {
  const explicit =
    asNonEmptyString((payload as { notification_title?: unknown }).notification_title) ??
    asNonEmptyString(payload["notification-title"]);
  if (typeof explicit === "string") {
    return explicit;
  }
  const fallback = asNonEmptyString(payload.title);
  if (typeof fallback === "string") {
    return fallback;
  }
  return CLAUDE_DEFAULT_TITLE;
};

const extractClaudeMessage = (payload: Record<string, unknown>): string | undefined => {
  const explicit =
    asNonEmptyString((payload as { notification_message?: unknown }).notification_message) ??
    asNonEmptyString(payload["notification-message"]);
  if (typeof explicit === "string") {
    return explicit;
  }
  const printResult = asNonEmptyString(payload.result);
  if (typeof printResult === "string") {
    return printResult;
  }
  return extractCodexMessage(payload);
};

const extractCommandFirstToken = (command: string): string | undefined => {
  const trimmed = command.trim();
  if (trimmed.length === 0) {
    return undefined;
  }

  const match = trimmed.match(/^"[^"]*"|^'[^']*'|^\S+/);
  if (!match || match[0] === undefined) {
    return undefined;
  }
  const token = match[0].trim();
  if (token.length === 0) {
    return undefined;
  }
  if ((token.startsWith('"') && token.endsWith('"')) || (token.startsWith("'") && token.endsWith("'"))) {
    return token.slice(1, -1);
  }
  return token;
};

const isClaudeExecutableCommand = (command: string): boolean => {
  const firstToken = extractCommandFirstToken(command);
  if (typeof firstToken !== "string" || firstToken.length === 0) {
    return false;
  }
  return basename(firstToken) === "claude";
};

const hasClaudePrintFlag = (command: string): boolean => {
  return /(^|\s)-p(\s|$)/.test(command) || /(^|\s)--print(\s|$)/.test(command);
};

const readProcessField = (pid: number, field: "ppid" | "command"): string | undefined => {
  const fieldArg = field === "ppid" ? "ppid=" : "command=";
  const result = spawnSync("ps", ["-o", fieldArg, "-p", String(pid)], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"]
  });
  if (result.status !== 0) {
    return undefined;
  }
  const value = result.stdout.trim();
  return value.length > 0 ? value : undefined;
};

const readProcessInfo = (pid: number): ProcessInfo | undefined => {
  const command = readProcessField(pid, "command");
  const parentPidRaw = readProcessField(pid, "ppid");
  if (typeof command !== "string" || typeof parentPidRaw !== "string") {
    return undefined;
  }

  const parentPid = Number.parseInt(parentPidRaw, 10);
  if (!Number.isInteger(parentPid) || parentPid < 0) {
    return undefined;
  }

  return {
    parentPid,
    command
  };
};

export const detectClaudePrintModeFromProcessChain = (
  readProcess: (pid: number) => ProcessInfo | undefined = readProcessInfo,
  startPid: number = process.ppid,
  maxDepth: number = CLAUDE_PARENT_PROCESS_SCAN_DEPTH
): boolean => {
  if (!Number.isInteger(startPid) || startPid <= 1) {
    return false;
  }

  let currentPid = startPid;
  for (let depth = 0; depth < maxDepth && currentPid > 1; depth += 1) {
    const info = readProcess(currentPid);
    if (info === undefined) {
      return false;
    }

    if (isClaudeExecutableCommand(info.command)) {
      return hasClaudePrintFlag(info.command);
    }

    if (!Number.isInteger(info.parentPid) || info.parentPid <= 0 || info.parentPid === currentPid) {
      return false;
    }
    currentPid = info.parentPid;
  }

  return false;
};

const isClaudeNonInteractivePayload = (payload: Record<string, unknown>, detectPrintMode: () => boolean): boolean => {
  const type = asNonEmptyString(payload.type);
  if (type !== "result") {
    const hookEventName = asNonEmptyString(payload.hook_event_name);
    if (hookEventName === "Stop" || hookEventName === "SubagentStop") {
      return detectPrintMode();
    }
    return false;
  }

  return (
    typeof asNonEmptyString(payload.subtype) === "string" ||
    Object.prototype.hasOwnProperty.call(payload, "result") ||
    typeof payload.total_cost_usd === "number"
  );
};

export const loadClaudeContext = async (
  stdinOverride?: string,
  detectClaudePrintMode: () => boolean = detectClaudePrintModeFromProcessChain
): Promise<AgentContext | undefined> => {
  const rawInput = typeof stdinOverride === "string" ? stdinOverride : await readStdin();
  const source = rawInput.trim();
  if (source.length === 0) {
    return undefined;
  }

  try {
    const parsed = JSON.parse(source);
    if (parsed === null || typeof parsed !== "object") {
      return undefined;
    }
    const record = parsed as Record<string, unknown>;
    const messageFromPayload = extractClaudeMessage(record);
    const transcriptPath = resolveClaudeTranscriptPath(
      (record as { transcript_path?: unknown }).transcript_path ?? record.transcriptPath
    );
    const transcriptMessage = typeof transcriptPath === "string" ? readClaudeTranscript(transcriptPath) : undefined;

    return {
      title: extractClaudeTitle(record),
      message: messageFromPayload ?? transcriptMessage,
      sound: resolveCodexSound(record),
      isNonInteractive: isClaudeNonInteractivePayload(record, detectClaudePrintMode)
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Failed to parse Claude payload JSON: ${message}`);
  }
};
