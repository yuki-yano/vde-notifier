import { appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

export const appendDiagnosticLog = (logFile: string | undefined, detail: unknown): void => {
  if (typeof logFile !== "string" || logFile.trim().length === 0) {
    return;
  }
  try {
    const directory = dirname(logFile);
    if (directory !== "" && directory !== "." && directory !== "/") {
      mkdirSync(directory, { recursive: true });
    }
    const entry = {
      timestamp: new Date().toISOString(),
      detail
    };
    appendFileSync(logFile, `${JSON.stringify(entry)}\n`, { encoding: "utf8" });
  } catch {
    // Diagnostics must not change command behavior.
  }
};

export const logVerbose = (enabled: boolean, logFile: string | undefined, detail: unknown): void => {
  if (enabled) {
    console.error(JSON.stringify(detail, null, 2));
  }
  appendDiagnosticLog(logFile, detail);
};
