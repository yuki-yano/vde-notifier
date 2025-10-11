import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, writeFileSync, chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, delimiter } from "node:path";
import { ensureBinary } from "../binary.js";

const createExecutable = (directory: string, name: string, mode = 0o755) => {
  const filePath = join(directory, name);
  writeFileSync(filePath, "#!/bin/sh\nexit 0\n", { mode });
  if (mode & 0o100) {
    chmodSync(filePath, mode);
  }
  return filePath;
};

describe("ensureBinary", () => {
  let originalPath: string | undefined;
  let tempDir: string;

  beforeEach(() => {
    originalPath = process.env.PATH;
    tempDir = mkdtempSync(join(tmpdir(), "vde-notifier-binary-"));
  });

  afterEach(() => {
    if (originalPath === undefined) {
      delete process.env.PATH;
    } else {
      process.env.PATH = originalPath;
    }
    rmSync(tempDir, { recursive: true, force: true });
  });

  it("accepts an explicit absolute executable path", async () => {
    const executable = createExecutable(tempDir, "cli-explicit");
    await expect(ensureBinary("cli-explicit", executable)).resolves.toBe(executable);
  });

  it("throws when explicit path is not absolute", async () => {
    await expect(ensureBinary("cli", "relative/path")).rejects.toThrow("The given path must be absolute");
  });

  it("throws when explicit path is not executable", async () => {
    const filePath = createExecutable(tempDir, "cli-nonexec", 0o644);
    await expect(ensureBinary("cli-nonexec", filePath)).rejects.toThrow("Command is not executable");
  });

  it("locates a command via PATH lookup", async () => {
    const executable = createExecutable(tempDir, "cli-path");
    const existingPath = originalPath ?? "";
    process.env.PATH = `${tempDir}${existingPath.length > 0 ? delimiter + existingPath : ""}`;

    await expect(ensureBinary("cli-path")).resolves.toBe(executable);
  });

  it("throws when command cannot be found on PATH", async () => {
    process.env.PATH = tempDir; // empty directory
    await expect(ensureBinary("missing-binary")).rejects.toThrow("Unable to locate command on PATH: missing-binary");
  });
});
