import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { z } from "zod";
import type { FocusCommand, FocusPayload } from "../types.js";

const encode = (payload: FocusPayload): string => {
  const json = JSON.stringify(payload);
  return Buffer.from(json, "utf8").toString("base64");
};

const decode = (encoded: string): string => {
  try {
    return Buffer.from(encoded, "base64").toString("utf8");
  } catch (error) {
    throw new Error(`Failed to decode payload: ${(error as Error).message}`);
  }
};

const escapeShell = (value: string): string => `'${value.replace(/'/g, "'\\''")}'`;

const resolveEntryPoint = (): string => {
  const entryFromArgv = process.argv[1];
  if (typeof entryFromArgv === "string" && entryFromArgv.length > 0) {
    return resolve(entryFromArgv);
  }
  const fallback = fileURLToPath(new URL("../dist/index.js", import.meta.url));
  return resolve(fallback);
};

const tmuxSchema = z.object({
  tmuxBin: z.string(),
  socketPath: z.string(),
  clientTTY: z.string(),
  sessionName: z.string(),
  windowId: z.string(),
  windowIndex: z.number(),
  paneId: z.string(),
  paneIndex: z.number(),
  paneCurrentCommand: z.string()
});

const terminalSchema = z.object({
  key: z.string(),
  name: z.string(),
  bundleId: z.string(),
  source: z.enum(["override", "env", "default"])
});

const payloadSchema = z.object({
  tmux: tmuxSchema,
  terminal: terminalSchema
});

export const buildFocusCommand = (
  payload: FocusPayload,
  options: { readonly verbose?: boolean } = {}
): FocusCommand => {
  const encoded = encode(payload);
  const execPath = process.execPath;
  const entryPoint = resolveEntryPoint();

  const args = [entryPoint, "--mode", "focus", "--payload", encoded];
  if (options.verbose === true) {
    args.push("--verbose");
  }
  const serialized = `${escapeShell(execPath)} ${args.map(escapeShell).join(" ")}`;

  return {
    command: serialized,
    args,
    payload: encoded
  };
};

export const parseFocusPayload = (raw?: string): FocusPayload => {
  if (typeof raw !== "string" || raw.length === 0) {
    throw new Error("Focus payload is required");
  }
  let decoded: string;
  try {
    decoded = decode(raw);
  } catch (error) {
    throw new Error(`Invalid focus payload: ${(error as Error).message}`);
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(decoded);
  } catch (error) {
    throw new Error(`Failed to parse focus payload JSON: ${(error as Error).message}`);
  }

  const result = payloadSchema.safeParse(parsed);
  if (!result.success) {
    const message = result.error.issues.map((issue) => issue.message).join(", ");
    throw new Error(`Focus payload validation failed: ${message}`);
  }

  return result.data as FocusPayload;
};
