import { describe, expect, it } from "vitest";

// @ts-ignore verify-npm-pack is a runtime-only ESM script without TS declarations.
import { runPackCheck } from "../../scripts/verify-npm-pack.mjs";

type PackFile = {
  readonly path: string;
  readonly mode: number;
};

const baseFiles: readonly PackFile[] = [
  { path: "package.json", mode: 0o644 },
  { path: "README.md", mode: 0o644 },
  { path: "LICENSE", mode: 0o644 },
  { path: "dist/cli.js", mode: 0o755 }
];

const buildPackOutput = (files: readonly PackFile[]): string => {
  return JSON.stringify([
    {
      name: "vde-notifier",
      version: "0.1.1",
      entryCount: files.length,
      files
    }
  ]);
};

describe("verify-npm-pack script", () => {
  it("passes for a valid package layout", () => {
    const message = runPackCheck(buildPackOutput(baseFiles));
    expect(message).toContain("npm pack check passed:");
  });

  it("fails when required files are missing", () => {
    const files = baseFiles.filter((file) => file.path !== "dist/cli.js");
    expect(() => runPackCheck(buildPackOutput(files))).toThrow("npm package is missing required file: dist/cli.js");
  });

  it("fails when dist/cli.js is not executable", () => {
    const files = baseFiles.map((file) => (file.path === "dist/cli.js" ? { ...file, mode: 0o644 } : file));
    expect(() => runPackCheck(buildPackOutput(files))).toThrow("CLI entrypoint is not executable");
  });

  it("fails when source directories leak into tarball", () => {
    const files = [...baseFiles, { path: "src/cli.ts", mode: 0o644 }];
    expect(() => runPackCheck(buildPackOutput(files))).toThrow(
      "npm tarball includes unexpected source/control files: src/cli.ts"
    );
  });
});
