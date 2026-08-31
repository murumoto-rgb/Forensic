import { afterEach, describe, expect, it, vi } from "vitest";
import { Readable } from "node:stream";
vi.mock("../src/env.js", () => ({ env: { R2_ACCOUNT_ID: "synthetic", R2_ACCESS_KEY_ID: "synthetic", R2_SECRET_ACCESS_KEY: "synthetic", R2_BUCKET: "synthetic" } }));
import { getObjectBytes, r2 } from "../src/r2.js";

afterEach(() => { vi.restoreAllMocks(); vi.useRealTimers(); });
describe("R2 complete-body deadlines and byte limits", () => {
  it("uses a single deadline spanning header latency and a stalled body", async () => {
    vi.useFakeTimers();
    const body = new Readable({ read() {} });
    let signal: AbortSignal | undefined;
    vi.spyOn(r2, "send").mockImplementation((async (_command: unknown, options: { abortSignal: AbortSignal }) => {
      signal = options.abortSignal;
      await new Promise(resolve => setTimeout(resolve, 12));
      body.push(Buffer.from("partial"));
      return { Body: body, ContentLength: 100 };
    }) as never);
    const outcome = getObjectBytes("synthetic/photo", { timeoutMs: 20 }).then(() => null, error => error);
    await vi.advanceTimersByTimeAsync(12);
    expect(body.destroyed).toBe(false);
    await vi.advanceTimersByTimeAsync(8);
    expect(await outcome).toMatchObject({ name: "TimeoutError" });
    expect(signal?.aborted).toBe(true);
    expect(body.destroyed).toBe(true);
  });
  it("rejects a stalled header request even if the transport ignores abort", async () => {
    vi.useFakeTimers();
    vi.spyOn(r2, "send").mockImplementation((() => new Promise(() => {})) as never);
    const outcome = getObjectBytes("synthetic/photo", { timeoutMs: 10 }).then(() => null, error => error);
    await vi.advanceTimersByTimeAsync(10);
    expect(await outcome).toMatchObject({ name: "TimeoutError" });
  });
  it("enforces actual streamed bytes when ContentLength is absent", async () => {
    const body = Readable.from([Buffer.from("12"), Buffer.from("34")]);
    vi.spyOn(r2, "send").mockResolvedValue({ Body: body } as never);
    await expect(getObjectBytes("synthetic/photo", { maxBytes: 3 })).rejects.toThrow(/read limit/);
    expect(body.destroyed).toBe(true);
  });
  it("rejects oversized headers without consuming the body", async () => {
    const body = new Readable({ read() { throw new Error("must not read"); } });
    vi.spyOn(r2, "send").mockResolvedValue({ Body: body, ContentLength: 4 } as never);
    await expect(getObjectBytes("synthetic/photo", { maxBytes: 3 })).rejects.toThrow(/read limit/);
    expect(body.destroyed).toBe(true);
  });
  it("rejects truncation instead of returning a successful partial image", async () => {
    vi.spyOn(r2, "send").mockResolvedValue({ Body: Readable.from([Buffer.from("12")]), ContentLength: 3 } as never);
    await expect(getObjectBytes("synthetic/photo")).rejects.toThrow(/does not match/);
  });
  it("returns a complete bounded body and clears its deadline", async () => {
    vi.useFakeTimers();
    vi.spyOn(r2, "send").mockResolvedValue({ Body: Readable.from([Buffer.from("12"), Buffer.from("34")]), ContentLength: 4 } as never);
    expect(await getObjectBytes("synthetic/photo", { maxBytes: 4 })).toEqual(Buffer.from("1234"));
    expect(vi.getTimerCount()).toBe(0);
  });
  it("does not allow callers to extend the 60-second maximum", async () => {
    await expect(getObjectBytes("synthetic/photo", { timeoutMs: 300000 })).rejects.toThrow(/Invalid object-read limits/);
  });
});
