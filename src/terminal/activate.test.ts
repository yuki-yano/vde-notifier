import { describe, expect, it, vi, beforeEach } from "vitest";

vi.mock("execa", () => ({
  execa: vi.fn()
}));

import { execa } from "execa";
import { activateTerminal } from "./profile.js";

const execaMock = vi.mocked(execa);
const result = (stdout: string) => ({ stdout }) as unknown as Awaited<ReturnType<typeof execa>>;

describe("activateTerminal", () => {
  beforeEach(() => {
    execaMock.mockReset();
  });

  it("activates application id and forces frontmost state", async () => {
    execaMock.mockResolvedValue(result(""));

    await activateTerminal("org.alacritty");

    expect(execaMock).toHaveBeenCalledTimes(2);
    expect(execaMock.mock.calls[0][1] as string[]).toEqual(["-e", 'tell application id "org.alacritty" to activate']);
    expect(execaMock.mock.calls[1][1] as string[]).toEqual(["-e", expect.stringContaining("System Events")]);
  });

  it("includes NotificationCenter hand-off in frontmost script", async () => {
    execaMock.mockResolvedValue(result(""));

    await activateTerminal("org.alacritty");

    const script = (execaMock.mock.calls[1][1] as string[])[1];
    expect(script).toContain("NotificationCenter");
    expect(script).toContain("frontmost");
  });

  it("still runs frontmost script when activation throws", async () => {
    execaMock.mockRejectedValueOnce(new Error("activate failed"));
    execaMock.mockResolvedValueOnce(result(""));

    await activateTerminal("org.alacritty");

    expect(execaMock).toHaveBeenCalledTimes(2);
  });

  it("suppresses frontmost errors when primary activation succeeds", async () => {
    execaMock.mockResolvedValueOnce(result(""));
    execaMock.mockRejectedValueOnce(new Error("not authorised"));

    await expect(activateTerminal("org.alacritty")).resolves.not.toThrow();
  });

  it("throws when both activation and frontmost hand-off fail", async () => {
    execaMock.mockRejectedValueOnce(new Error("activate failed"));
    execaMock.mockRejectedValueOnce(new Error("frontmost failed"));

    await expect(activateTerminal("org.alacritty")).rejects.toThrow("frontmost failed");
  });
});
