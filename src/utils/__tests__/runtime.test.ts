import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { EnvironmentReport } from "../../types.js";

const mockEnsureBinary = vi.fn();

vi.mock("../binary.js", () => ({
  ensureBinary: mockEnsureBinary
}));

describe("runtime utilities", () => {
  let runtime: typeof import("../runtime.js");
  let originalNodeVersion: PropertyDescriptor | undefined;
  const restoreNodeVersion = () => {
    if (originalNodeVersion !== undefined) {
      Object.defineProperty(process.versions, "node", originalNodeVersion);
    }
  };

  beforeEach(async () => {
    runtime = await import("../runtime.js");
    mockEnsureBinary.mockReset();
    originalNodeVersion = Object.getOwnPropertyDescriptor(process.versions, "node") ?? undefined;
  });

  afterEach(() => {
    restoreNodeVersion();
    delete (globalThis as { Bun?: unknown }).Bun;
  });

  describe("assertRuntimeSupport", () => {
    it("throws when neither Node nor Bun is available", () => {
      Object.defineProperty(process.versions, "node", { value: undefined, configurable: true, enumerable: true });

      expect(() => runtime.assertRuntimeSupport()).toThrow("Unsupported runtime");
    });

    it("passes when Bun is available even without Node", () => {
      Object.defineProperty(process.versions, "node", { value: undefined, configurable: true, enumerable: true });
      (globalThis as unknown as { Bun: { version: string } }).Bun = { version: "1.1.0" };

      expect(() => runtime.assertRuntimeSupport()).not.toThrow();
    });
  });

  describe("verifyRequiredBinaries", () => {
    it("ensures tmux, terminal-notifier, and osascript binaries", async () => {
      mockEnsureBinary.mockResolvedValueOnce("/usr/bin/tmux");
      mockEnsureBinary.mockResolvedValueOnce("/usr/bin/terminal-notifier");
      mockEnsureBinary.mockResolvedValueOnce("/usr/bin/osascript");

      const report = await runtime.verifyRequiredBinaries();

      expect(mockEnsureBinary).toHaveBeenCalledTimes(3);
      expect(mockEnsureBinary).toHaveBeenNthCalledWith(1, "tmux");
      expect(mockEnsureBinary).toHaveBeenNthCalledWith(2, "terminal-notifier");
      expect(mockEnsureBinary).toHaveBeenNthCalledWith(3, "osascript");
      expect(report.binaries.tmux).toBe("/usr/bin/tmux");
      expect(report.binaries.terminalNotifier).toBe("/usr/bin/terminal-notifier");
      expect(report.binaries.osascript).toBe("/usr/bin/osascript");
    });
  });

  describe("logBinaryReport", () => {
    it("prints report only when verbose", () => {
      const spy = vi.spyOn(console, "error").mockImplementation(() => undefined);

      const report: EnvironmentReport = {
        runtime: {
          nodeVersion: "22.0.0"
        },
        binaries: {
          tmux: "/tmp/tmux",
          terminalNotifier: "/tmp/tn",
          osascript: "/usr/bin/osascript"
        }
      };

      runtime.logBinaryReport(report, false);
      runtime.logBinaryReport(report, true);

      expect(spy).toHaveBeenCalledTimes(1);
      spy.mockRestore();
    });
  });
});
