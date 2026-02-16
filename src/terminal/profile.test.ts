import { describe, expect, it } from "vitest";
import { resolveTerminalProfile } from "./profile.js";

describe("resolveTerminalProfile", () => {
  it("prefers explicit key", () => {
    const profile = resolveTerminalProfile({ explicitKey: "wezterm" });
    expect(profile.bundleId).toBe("com.github.wez.wezterm");
    expect(profile.source).toBe("override");
  });

  it("falls back to environment", () => {
    const profile = resolveTerminalProfile({ env: { TERM_PROGRAM: "kitty" } });
    expect(profile.key).toBe("kitty");
    expect(profile.source).toBe("env");
  });

  it("returns custom bundle override when unknown", () => {
    const customBundle = "com.example.custom.term";
    const profile = resolveTerminalProfile({ bundleOverride: customBundle });
    expect(profile.bundleId).toBe(customBundle);
    expect(profile.key).toBe("custom");
  });

  it("returns custom profile for unknown explicit terminal key", () => {
    const explicitKey = "com.example.unknown-terminal";
    const profile = resolveTerminalProfile({ explicitKey });
    expect(profile.bundleId).toBe(explicitKey);
    expect(profile.key).toBe("custom");
    expect(profile.source).toBe("override");
  });
});
