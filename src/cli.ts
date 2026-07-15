#!/usr/bin/env node
import { fileURLToPath } from "node:url";
import { argv, exit } from "node:process";
import { realpathSync } from "node:fs";
import { bold, red } from "kleur/colors";
import { extractCodexMessage, resolveCodexSound } from "./agents/context";
import { isCodexTitleGenerationPayload } from "./agents/codex";
import { detectClaudePrintModeFromProcessChain, loadClaudeContext } from "./agents/claude";
import { runFocus } from "./commands/focus";
import { loadCodexContext, resolveNotificationDetails, runNotify } from "./commands/notify";
import {
  formatUsage,
  parseArguments,
  resolveCliVersion,
  resolveControlOptions,
  resolveProgramName
} from "./cli/arguments";
import { assertRuntimeSupport } from "./utils/runtime";

const isMainModule = (): boolean => {
  const entry = argv[1];
  if (typeof entry !== "string") {
    return false;
  }
  try {
    const normalizedEntry = realpathSync(entry);
    const modulePath = realpathSync(fileURLToPath(import.meta.url));
    return modulePath === normalizedEntry;
  } catch {
    return false;
  }
};

const printError = (error: unknown): void => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(red(bold(message)));
};

export const main = async (): Promise<number> => {
  try {
    const rawArgs = argv.slice(2);
    const controls = resolveControlOptions(rawArgs);
    if (controls.help) {
      console.log(formatUsage(resolveProgramName()));
      return 0;
    }
    if (controls.version) {
      console.log(resolveCliVersion());
      return 0;
    }

    const options = parseArguments(rawArgs);
    assertRuntimeSupport();
    if (options.mode === "notify") {
      return await runNotify(options, undefined, rawArgs);
    }
    return await runFocus(options);
  } catch (error) {
    printError(error);
    if (error instanceof Error && error.message.startsWith("Failed to parse CLI options:")) {
      console.error("");
      console.error(formatUsage(resolveProgramName()));
    }
    return 1;
  }
};

if (isMainModule()) {
  main()
    .then((code) => exit(code))
    .catch((error) => {
      printError(error);
      exit(1);
    });
}

export const __internal = {
  formatUsage,
  resolveCliVersion,
  resolveControlOptions,
  parseArguments,
  runNotify,
  runFocus,
  resolveNotificationDetails,
  loadCodexContext,
  loadClaudeContext,
  detectClaudePrintModeFromProcessChain,
  extractCodexMessage,
  isCodexTitleGenerationPayload,
  resolveCodexSound
};
