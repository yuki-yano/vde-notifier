import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { appendDiagnosticLog, logVerbose } from "./logging";

const temporaryDirectories: string[] = [];

const makeTemporaryDirectory = (): string => {
  const directory = mkdtempSync(join(tmpdir(), "vde-notifier-diagnostics-"));
  temporaryDirectories.push(directory);
  return directory;
};

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { recursive: true, force: true });
  }
  vi.restoreAllMocks();
});

describe("diagnostic logging", () => {
  it("creates parent directories and writes a JSON line", () => {
    const directory = makeTemporaryDirectory();
    const logFile = join(directory, "nested", "diagnostics.jsonl");

    appendDiagnosticLog(logFile, { stage: "notify", ok: true });

    const entry = JSON.parse(readFileSync(logFile, "utf8")) as {
      timestamp: string;
      detail: unknown;
    };
    expect(entry.timestamp).toMatch(/^\d{4}-\d{2}-\d{2}T/u);
    expect(entry.detail).toEqual({ stage: "notify", ok: true });
  });

  it("keeps command behavior unchanged when the log path is unwritable", () => {
    const directory = makeTemporaryDirectory();
    const parentFile = join(directory, "not-a-directory");
    writeFileSync(parentFile, "file", "utf8");

    expect(() => appendDiagnosticLog(join(parentFile, "diagnostics.jsonl"), { stage: "focus" })).not.toThrow();
  });

  it("prints verbose details and mirrors them to the log", () => {
    const directory = makeTemporaryDirectory();
    const logFile = join(directory, "diagnostics.jsonl");
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);

    logVerbose(true, logFile, { stage: "forward" });

    expect(errorSpy).toHaveBeenCalledWith(JSON.stringify({ stage: "forward" }, null, 2));
    expect(JSON.parse(readFileSync(logFile, "utf8"))).toEqual(
      expect.objectContaining({ detail: { stage: "forward" } })
    );
  });
});
