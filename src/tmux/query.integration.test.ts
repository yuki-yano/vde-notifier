import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { resolveTmuxContext } from "./query";

const resolveTmuxPath = (): string | undefined => {
  try {
    const path = execFileSync("/usr/bin/which", ["tmux"], { encoding: "utf8" }).trim();
    return path.length > 0 ? path : undefined;
  } catch {
    return undefined;
  }
};

const tmuxPath = resolveTmuxPath();

describe.skipIf(tmuxPath === undefined)("resolveTmuxContext integration", () => {
  const originalTmux = process.env.TMUX;
  const originalTmuxPane = process.env.TMUX_PANE;
  let temporaryDirectory = "";
  let socketPath = "";

  beforeEach(() => {
    temporaryDirectory = mkdtempSync(join(tmpdir(), "vde-notifier-tmux-"));
    socketPath = join(temporaryDirectory, "server.sock");
    execFileSync(tmuxPath!, ["-S", socketPath, "-f", "/dev/null", "new-session", "-d", "-s", "before"]);

    const paneId = execFileSync(
      tmuxPath!,
      ["-S", socketPath, "display-message", "-p", "-t", "before:0.0", "#{pane_id}"],
      {
        encoding: "utf8"
      }
    ).trim();
    const serverPid = execFileSync(tmuxPath!, ["-S", socketPath, "display-message", "-p", "-t", paneId, "#{pid}"], {
      encoding: "utf8"
    }).trim();
    process.env.TMUX = `${socketPath},${serverPid},0`;
    process.env.TMUX_PANE = paneId;
  });

  afterEach(() => {
    try {
      execFileSync(tmuxPath!, ["-S", socketPath, "kill-server"]);
    } catch {
      // The server may already have exited after a failed assertion.
    }
    rmSync(temporaryDirectory, { recursive: true, force: true });
    if (originalTmux === undefined) {
      delete process.env.TMUX;
    } else {
      process.env.TMUX = originalTmux;
    }
    if (originalTmuxPane === undefined) {
      delete process.env.TMUX_PANE;
    } else {
      process.env.TMUX_PANE = originalTmuxPane;
    }
  });

  it("keeps the session target valid after the session is renamed", async () => {
    const context = await resolveTmuxContext(tmuxPath!);
    expect(context.sessionName).toBe("before");
    expect(context.sessionId).toMatch(/^\$\d+$/);

    execFileSync(tmuxPath!, ["-S", socketPath, "rename-session", "-t", context.sessionId, "after"]);

    expect(() =>
      execFileSync(tmuxPath!, ["-S", socketPath, "has-session", "-t", context.sessionId], { stdio: "ignore" })
    ).not.toThrow();
    expect(() =>
      execFileSync(tmuxPath!, ["-S", socketPath, "has-session", "-t", context.sessionName], { stdio: "ignore" })
    ).toThrow();
  });
});
