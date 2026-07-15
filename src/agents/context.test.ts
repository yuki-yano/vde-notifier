import { afterEach, describe, expect, it } from "vitest";
import { asNonEmptyString, extractCodexMessage, resolveCodexSound } from "./context";

describe("agent context helpers", () => {
  const originalSound = process.env.CODEX_NOTIFICATION_SOUND;

  afterEach(() => {
    if (originalSound === undefined) {
      delete process.env.CODEX_NOTIFICATION_SOUND;
    } else {
      process.env.CODEX_NOTIFICATION_SOUND = originalSound;
    }
  });

  it("normalizes non-empty strings", () => {
    expect(asNonEmptyString(undefined)).toBeUndefined();
    expect(asNonEmptyString("   ")).toBeUndefined();
    expect(asNonEmptyString("  done  ")).toBe("done");
  });

  it("uses supported direct message fields in priority order", () => {
    expect(extractCodexMessage({ last_agent_message: "task complete", message: "fallback" })).toBe("task complete");
    expect(extractCodexMessage({ message: "fallback" })).toBe("fallback");
  });

  it("finds the latest assistant string message", () => {
    expect(
      extractCodexMessage({
        messages: [
          null,
          { role: "assistant", content: "older" },
          { role: "user", content: "question" },
          { role: "assistant", content: "latest" }
        ]
      })
    ).toBe("latest");
  });

  it("finds text in an assistant content array", () => {
    expect(
      extractCodexMessage({
        messages: [{ role: "assistant", content: [null, { type: "text", text: "array content" }] }]
      })
    ).toBe("array content");
  });

  it("reads the final transcript content part", () => {
    expect(
      extractCodexMessage({
        transcript: {
          message: {
            content: [{ text: "first" }, { text: "transcript result" }]
          }
        }
      })
    ).toBe("transcript result");
    expect(extractCodexMessage({ transcript: { message: { content: [] } } })).toBeUndefined();
  });

  it("maps boolean and numeric sound values", () => {
    expect(resolveCodexSound({ sound: true })).toBe("Glass");
    expect(resolveCodexSound({ sound: false })).toBe("None");
    expect(resolveCodexSound({ sound: 0 })).toBe("None");
    expect(resolveCodexSound({ sound: 1 })).toBeUndefined();
  });

  it("maps string sound switches", () => {
    expect(resolveCodexSound({ sound: "true" })).toBe("Glass");
    expect(resolveCodexSound({ sound: "false" })).toBe("None");
    expect(resolveCodexSound({ sound: "default" })).toBe("Glass");
    expect(resolveCodexSound({ sound: "glass" })).toBe("Glass");
    expect(resolveCodexSound({ sound: "Ping" })).toBe("Ping");
  });

  it("uses the environment only when the payload omits sound", () => {
    process.env.CODEX_NOTIFICATION_SOUND = "Ping";

    expect(resolveCodexSound({})).toBe("Ping");
    expect(resolveCodexSound({ sound: null })).toBeUndefined();
  });

  it("falls back to Glass for a path without a file name", () => {
    expect(resolveCodexSound({ sound: "/System/Library/Sounds/" })).toBe("Glass");
    expect(resolveCodexSound({ sound: "   " })).toBeUndefined();
  });
});
