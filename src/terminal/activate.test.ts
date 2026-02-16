import { describe, expect, it, vi, beforeEach } from "vitest";

vi.mock("execa", () => ({
  execa: vi.fn()
}));

import { execa } from "execa";
import { activateTerminal } from "./profile";

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

  it("escapes bundle identifiers before embedding in AppleScript", async () => {
    execaMock.mockResolvedValue(result(""));
    const bundleId = 'com.example."evil"\nterm\\id';

    await activateTerminal(bundleId);

    const activationScript = (execaMock.mock.calls[0][1] as string[])[1];
    expect(activationScript).toBe('tell application id "com.example.\\"evil\\" term\\\\id" to activate');

    const frontmostScript = (execaMock.mock.calls[1][1] as string[])[1];
    expect(frontmostScript).toContain('if bundle identifier of proc is "com.example.\\"evil\\" term\\\\id" then');
  });
});
