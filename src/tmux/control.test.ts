import { beforeEach, describe, expect, it, vi } from "vitest";
import { focusPane } from "./control.js";
import type { TmuxContext } from "../types.js";

vi.mock("execa", () => ({
  execa: vi.fn()
}));

import { execa } from "execa";

const execaMock = vi.mocked(execa);

const context: TmuxContext = {
  tmuxBin: "/opt/homebrew/bin/tmux",
  socketPath: "/tmp/tmux-501/default",
  clientTTY: "/dev/ttys002",
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
    execaMock.mockResolvedValue({} as unknown as Awaited<ReturnType<typeof execa>>);
  });

  it("invokes tmux commands in order", async () => {
    await focusPane(context);

    expect(execaMock).toHaveBeenCalledTimes(3);
    expect(execaMock.mock.calls[0]).toEqual([
      context.tmuxBin,
      ["-S", context.socketPath, "switch-client", "-c", context.clientTTY, "-t", context.sessionName]
    ]);
    expect(execaMock.mock.calls[1]).toEqual([
      context.tmuxBin,
      ["-S", context.socketPath, "select-window", "-t", context.windowId]
    ]);
    expect(execaMock.mock.calls[2]).toEqual([
      context.tmuxBin,
      ["-S", context.socketPath, "select-pane", "-t", context.paneId]
    ]);
  });

  it("propagates tmux errors", async () => {
    execaMock.mockRejectedValueOnce(new Error("no socket"));

    await expect(focusPane(context)).rejects.toThrow("no socket");
  });
});
