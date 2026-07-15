import { beforeEach, describe, expect, it, vi } from "vitest";
import { focusPane, validateFocusTargets } from "./control";
import type { TmuxContext } from "../types";

vi.mock("execa", () => ({
  execa: vi.fn()
}));

import { execa } from "execa";

const execaMock = vi.mocked(execa);

const context: TmuxContext = {
  tmuxBin: "/opt/homebrew/bin/tmux",
  socketPath: "/tmp/tmux-501/default",
  clientTTY: "/dev/ttys002",
  sessionId: "$1",
  sessionName: "dev",
  windowId: "@2",
  windowIndex: 2,
  paneId: "%2",
  paneIndex: 0,
  paneCurrentCommand: "npm"
};

describe("focusPane", () => {
  beforeEach(() => {
    execaMock.mockReset();
    execaMock
      .mockResolvedValueOnce({ stdout: "" } as Awaited<ReturnType<typeof execa>>)
      .mockResolvedValueOnce({ stdout: `${context.windowId}\n` } as Awaited<ReturnType<typeof execa>>)
      .mockResolvedValueOnce({ stdout: `${context.paneId}\n` } as Awaited<ReturnType<typeof execa>>)
      .mockResolvedValueOnce({ stdout: `${context.clientTTY}\n` } as Awaited<ReturnType<typeof execa>>)
      .mockResolvedValue({ stdout: "" } as Awaited<ReturnType<typeof execa>>);
  });

  it("invokes tmux commands in order", async () => {
    await focusPane(context);

    expect(execaMock).toHaveBeenCalledTimes(7);
    expect(execaMock.mock.calls[4]).toEqual([
      context.tmuxBin,
      ["-S", context.socketPath, "switch-client", "-c", context.clientTTY, "-t", context.sessionId]
    ]);
    expect(execaMock.mock.calls[5]).toEqual([
      context.tmuxBin,
      ["-S", context.socketPath, "select-window", "-t", context.windowId]
    ]);
    expect(execaMock.mock.calls[6]).toEqual([
      context.tmuxBin,
      ["-S", context.socketPath, "select-pane", "-t", context.paneId]
    ]);
  });

  it("propagates tmux errors", async () => {
    execaMock.mockReset();
    execaMock.mockRejectedValueOnce(new Error("no socket"));

    await expect(focusPane(context)).rejects.toThrow("no socket");
  });

  it("does not switch clients when the pane was deleted", async () => {
    execaMock.mockReset();
    execaMock
      .mockResolvedValueOnce({ stdout: "" } as Awaited<ReturnType<typeof execa>>)
      .mockResolvedValueOnce({ stdout: `${context.windowId}\n` } as Awaited<ReturnType<typeof execa>>)
      .mockResolvedValueOnce({ stdout: "%99\n" } as Awaited<ReturnType<typeof execa>>);

    await expect(focusPane(context)).rejects.toThrow(`tmux pane is no longer available: ${context.paneId}`);
    expect(execaMock).toHaveBeenCalledTimes(3);
    expect(execaMock.mock.calls.flatMap((call) => call[1])).not.toContain("switch-client");
  });

  it("does not switch clients when the original TTY reconnected elsewhere", async () => {
    execaMock.mockReset();
    execaMock
      .mockResolvedValueOnce({ stdout: "" } as Awaited<ReturnType<typeof execa>>)
      .mockResolvedValueOnce({ stdout: `${context.windowId}\n` } as Awaited<ReturnType<typeof execa>>)
      .mockResolvedValueOnce({ stdout: `${context.paneId}\n` } as Awaited<ReturnType<typeof execa>>)
      .mockResolvedValueOnce({ stdout: "/dev/ttys099\n" } as Awaited<ReturnType<typeof execa>>);

    await expect(focusPane(context)).rejects.toThrow(`tmux client is no longer available: ${context.clientTTY}`);
    expect(execaMock).toHaveBeenCalledTimes(4);
    expect(execaMock.mock.calls.flatMap((call) => call[1])).not.toContain("switch-client");
  });

  it("rejects a missing client TTY before querying clients", async () => {
    execaMock.mockReset();
    execaMock
      .mockResolvedValueOnce({ stdout: "" } as Awaited<ReturnType<typeof execa>>)
      .mockResolvedValueOnce({ stdout: `${context.windowId}\n` } as Awaited<ReturnType<typeof execa>>)
      .mockResolvedValueOnce({ stdout: `${context.paneId}\n` } as Awaited<ReturnType<typeof execa>>);

    await expect(validateFocusTargets({ ...context, clientTTY: "" })).rejects.toThrow("tmux client TTY is unavailable");
    expect(execaMock).toHaveBeenCalledTimes(3);
  });
});
