import { afterAll, beforeEach, describe, expect, it, vi } from "vitest";
import { resolveTmuxContext } from "../query.js";

vi.mock("execa", () => ({
  execa: vi.fn()
}));

import { execa } from "execa";

const execaMock = vi.mocked(execa);

describe("resolveTmuxContext", () => {
  const originalTmuxPane = process.env.TMUX_PANE;

  beforeEach(() => {
    execaMock.mockReset();
    delete process.env.TMUX_PANE;
  });

  afterAll(() => {
    if (originalTmuxPane === undefined) {
      delete process.env.TMUX_PANE;
    } else {
      process.env.TMUX_PANE = originalTmuxPane;
    }
  });

  it("parses tmux display output into structured context", async () => {
    process.env.TMUX_PANE = "%5";
    const stdout = ["/tmp/tmux-501/default", "/dev/ttys005", "dev", "@4", "2", "%17", "1", "node"].join("\n");
    execaMock.mockResolvedValue({ stdout } as unknown as Awaited<ReturnType<typeof execa>>);

    const context = await resolveTmuxContext("/opt/homebrew/bin/tmux");

    expect(context.sessionName).toBe("dev");
    expect(context.windowIndex).toBe(2);
    expect(context.paneIndex).toBe(1);
    expect(context.tmuxBin).toBe("/opt/homebrew/bin/tmux");
    const lastArgs = execaMock.mock.calls[0]?.[1];
    expect(lastArgs).toEqual([
      "display-message",
      "-p",
      "-t",
      "%5",
      "#{socket_path}\n#{client_tty}\n#{session_name}\n#{window_id}\n#{window_index}\n#{pane_id}\n#{pane_index}\n#{pane_current_command}"
    ]);
  });

  it("throws when tmux returns unexpected number of lines", async () => {
    delete process.env.TMUX_PANE;
    const stdout = "incomplete";
    execaMock.mockResolvedValue({ stdout } as unknown as Awaited<ReturnType<typeof execa>>);

    await expect(resolveTmuxContext("tmux")).rejects.toThrow("Unexpected tmux response");
  });

  it("throws when numeric fields cannot be parsed", async () => {
    delete process.env.TMUX_PANE;
    const stdout = ["/tmp/tmux-501/default", "/dev/ttys005", "dev", "@4", "NaN", "%17", "oops", "node"].join("\n");
    execaMock.mockResolvedValue({ stdout } as unknown as Awaited<ReturnType<typeof execa>>);

    await expect(resolveTmuxContext("tmux")).rejects.toThrow("Failed to parse window index as number");
  });

  it("omits target argument when TMUX_PANE is undefined", async () => {
    delete process.env.TMUX_PANE;
    const stdout = ["/tmp/tmux-501/default", "/dev/ttys005", "dev", "@4", "2", "%17", "1", "node"].join("\n");
    execaMock.mockResolvedValue({ stdout } as unknown as Awaited<ReturnType<typeof execa>>);

    await resolveTmuxContext("/opt/homebrew/bin/tmux");

    const args = execaMock.mock.calls[0]?.[1];
    expect(args).toEqual([
      "display-message",
      "-p",
      "#{socket_path}\n#{client_tty}\n#{session_name}\n#{window_id}\n#{window_index}\n#{pane_id}\n#{pane_index}\n#{pane_current_command}"
    ]);
  });
});
