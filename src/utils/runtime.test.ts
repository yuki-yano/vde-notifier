import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { EnvironmentReport } from "../types";

const mockEnsureBinary = vi.fn();

vi.mock("./binary", () => ({
  ensureBinary: mockEnsureBinary
}));

describe("runtime utilities", () => {
  let runtime: typeof import("./runtime");
  let originalNodeVersion: PropertyDescriptor | undefined;
  const restoreNodeVersion = () => {
    if (originalNodeVersion !== undefined) {
      Object.defineProperty(process.versions, "node", originalNodeVersion);
    }
  };

  beforeEach(async () => {
    runtime = await import("./runtime");
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

    it("throws when Node major version is below minimum requirement", () => {
      Object.defineProperty(process.versions, "node", { value: "20.11.1", configurable: true, enumerable: true });

      expect(() => runtime.assertRuntimeSupport()).toThrow("Node.js >= 22");
    });

    it("passes when Node major version meets minimum requirement", () => {
      Object.defineProperty(process.versions, "node", { value: "22.0.0", configurable: true, enumerable: true });

      expect(() => runtime.assertRuntimeSupport()).not.toThrow();
    });

    it("passes when Bun is available even without Node", () => {
      Object.defineProperty(process.versions, "node", { value: undefined, configurable: true, enumerable: true });
      (globalThis as unknown as { Bun: { version: string } }).Bun = { version: "1.1.0" };

      expect(() => runtime.assertRuntimeSupport()).not.toThrow();
    });
  });

  describe("verifyRequiredBinaries", () => {
    it("ensures tmux, vde-notifier-app, and osascript binaries by default", async () => {
      mockEnsureBinary.mockResolvedValueOnce("/usr/bin/tmux");
      mockEnsureBinary.mockResolvedValueOnce("/opt/homebrew/bin/vde-notifier-app");
      mockEnsureBinary.mockResolvedValueOnce("/usr/bin/osascript");

      const report = await runtime.verifyRequiredBinaries();

      expect(mockEnsureBinary).toHaveBeenCalledTimes(3);
      expect(mockEnsureBinary).toHaveBeenNthCalledWith(1, "tmux");
      expect(mockEnsureBinary).toHaveBeenNthCalledWith(2, "vde-notifier-app");
      expect(mockEnsureBinary).toHaveBeenNthCalledWith(3, "osascript");
      expect(report.binaries.tmux).toBe("/usr/bin/tmux");
      expect(report.binaries.notifier).toBe("/opt/homebrew/bin/vde-notifier-app");
      expect(report.binaries.notifierKind).toBe("vde-notifier-app");
      expect(report.binaries.osascript).toBe("/usr/bin/osascript");
    });

    it("prints installation guidance when default notifier is missing", async () => {
      mockEnsureBinary.mockResolvedValueOnce("/usr/bin/tmux");
      mockEnsureBinary.mockRejectedValueOnce(new Error("Unable to locate command on PATH: vde-notifier-app"));

      let thrown: unknown;
      try {
        await runtime.verifyRequiredBinaries();
      } catch (error) {
        thrown = error;
      }

      expect(thrown).toBeInstanceOf(Error);
      const message = (thrown as Error).message;
      expect(message).toContain("Default notifier `vde-notifier-app` is not installed.");
      expect(message).toContain("brew install --cask yuki-yano/vde-notifier/vde-notifier-app");
    });

    it("supports selecting swiftDialog as notifier", async () => {
      mockEnsureBinary.mockResolvedValueOnce("/usr/bin/tmux");
      mockEnsureBinary.mockResolvedValueOnce("/usr/local/bin/dialog");
      mockEnsureBinary.mockResolvedValueOnce("/usr/bin/osascript");

      const report = await runtime.verifyRequiredBinaries("swiftdialog");

      expect(mockEnsureBinary).toHaveBeenCalledTimes(3);
      expect(mockEnsureBinary).toHaveBeenNthCalledWith(2, "dialog");
      expect(report.binaries.notifier).toBe("/usr/local/bin/dialog");
      expect(report.binaries.notifierKind).toBe("swiftdialog");
    });

    it("supports selecting vde-notifier-app as notifier", async () => {
      mockEnsureBinary.mockResolvedValueOnce("/usr/bin/tmux");
      mockEnsureBinary.mockResolvedValueOnce("/opt/homebrew/bin/vde-notifier-app");
      mockEnsureBinary.mockResolvedValueOnce("/usr/bin/osascript");

      const report = await runtime.verifyRequiredBinaries("vde-notifier-app");

      expect(mockEnsureBinary).toHaveBeenCalledTimes(3);
      expect(mockEnsureBinary).toHaveBeenNthCalledWith(2, "vde-notifier-app");
      expect(report.binaries.notifier).toBe("/opt/homebrew/bin/vde-notifier-app");
      expect(report.binaries.notifierKind).toBe("vde-notifier-app");
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
          notifier: "/tmp/tn",
          notifierKind: "terminal-notifier",
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
