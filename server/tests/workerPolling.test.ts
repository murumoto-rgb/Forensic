import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { FastifyBaseLogger } from "fastify";
import { startQueuePoller } from "../src/exports/queuePoller.js";

const state = vi.hoisted(() => ({
  scans: 0, claims: 0, updates: [] as string[],
  readProject: (() => Promise.resolve({ data: null, error: null })) as () => Promise<unknown>,
}));
vi.mock("../src/supabase.js", () => ({ supabaseAdmin: { from(table: string) {
  let update: { status?: string } | undefined;
  let kind = "pdf";
  const execute = (single: boolean) => {
    if (table === "projects") return state.readProject();
    if (update) {
      state.updates.push(update.status ?? "progress");
      if (update.status === "running") state.claims++;
      return Promise.resolve({ data: update.status === "running" ? { id: `job-${state.claims}`, project_id: "synthetic", kind, status: "running", options: {} } : null, error: null });
    }
    state.scans++;
    const job = { id: `candidate-${state.scans}`, project_id: "synthetic", kind, status: "queued", options: {} };
    return Promise.resolve({ data: single ? job : [job], error: null });
  };
  const query = {
    select() { return query; }, order() { return query; }, limit() { return query; },
    eq(key: string, value: string) { if (key === "kind") kind = value; return query; },
    update(value: { status?: string }) { update = value; return query; },
    maybeSingle() { return execute(true); },
    then(resolve: never, reject: never) { return execute(false).then(resolve, reject); },
  };
  return query;
} } }));
vi.mock("../src/r2.js", () => ({ r2: {}, r2Bucket: "synthetic", getObjectStream: vi.fn(), getObjectSize: vi.fn(), putObjectBytes: vi.fn(), getObjectBytes: vi.fn() }));
vi.mock("../src/sentry.js", () => ({ captureException: vi.fn() }));
vi.mock("../src/reportBranding.js", () => ({ loadReportBrandingForExport: vi.fn() }));
vi.mock("puppeteer", () => ({ default: { launch: vi.fn() } }));

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(yes => { resolve = yes; });
  return { promise, resolve };
}
beforeEach(() => {
  vi.useFakeTimers(); vi.resetModules();
  state.scans = 0; state.claims = 0; state.updates = [];
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); });

describe("idle queue polling", () => {
  it("backs off to 60 seconds, stays capped, and resets after actual work", async () => {
    let work = false;
    const tick = vi.fn(async () => work);
    const stop = startQueuePoller(tick, vi.fn());
    let calls = 0;
    for (const delay of [5_000, 10_000, 20_000, 40_000, 60_000, 60_000]) {
      await vi.advanceTimersByTimeAsync(delay - 1);
      expect(tick).toHaveBeenCalledTimes(calls);
      await vi.advanceTimersByTimeAsync(1);
      expect(tick).toHaveBeenCalledTimes(++calls);
    }
    work = true;
    await vi.advanceTimersByTimeAsync(60_000);
    expect(tick).toHaveBeenCalledTimes(++calls);
    await vi.advanceTimersByTimeAsync(4_999);
    expect(tick).toHaveBeenCalledTimes(calls);
    await vi.advanceTimersByTimeAsync(1);
    expect(tick).toHaveBeenCalledTimes(++calls);
    stop();
  });
  it("schedules no callbacks while a slow tick is pending and does not catch up afterward", async () => {
    const held = deferred<boolean>();
    const tick = vi.fn(() => held.promise);
    const stop = startQueuePoller(tick, vi.fn());
    await vi.advanceTimersByTimeAsync(300_000);
    expect(tick).toHaveBeenCalledTimes(1);
    expect(vi.getTimerCount()).toBe(0);
    held.resolve(true);
    await vi.advanceTimersByTimeAsync(0);
    expect(vi.getTimerCount()).toBe(1);
    await vi.advanceTimersByTimeAsync(4_999);
    expect(tick).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(tick).toHaveBeenCalledTimes(2);
    stop();
  });
  it("reports a rejected scan, backs off, and resumes polling", async () => {
    const error = new Error("database unavailable");
    const tick = vi.fn<() => Promise<boolean>>().mockRejectedValueOnce(error).mockResolvedValue(true);
    const onError = vi.fn();
    const stop = startQueuePoller(tick, onError);
    await vi.advanceTimersByTimeAsync(5_000);
    expect(onError).toHaveBeenCalledWith(error);
    await vi.advanceTimersByTimeAsync(9_999);
    expect(tick).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(tick).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(5_000);
    expect(tick).toHaveBeenCalledTimes(3);
    stop();
  });
  it("does not rearm after being stopped during a pending tick", async () => {
    const held = deferred<boolean>();
    const tick = vi.fn(() => held.promise);
    const stop = startQueuePoller(tick, vi.fn());
    await vi.advanceTimersByTimeAsync(5_000);
    stop(); held.resolve(true);
    await vi.advanceTimersByTimeAsync(300_000);
    expect(tick).toHaveBeenCalledTimes(1);
    expect(vi.getTimerCount()).toBe(0);
  });
});

describe("actual worker scheduling", () => {
  it.each(["pdf", "folder", "csv"] as const)("%s waits for a claimed job before scanning again, even after repeated startup", async kind => {
    const held = deferred<unknown>();
    state.readProject = () => held.promise;
    const log = { info() {}, warn() {}, error() {} } as unknown as FastifyBaseLogger;
    const start = kind === "pdf" ? (await import("../src/exports/pdfWorker.js")).startPdfExportWorker
      : kind === "folder" ? (await import("../src/exports/folderBundleWorker.js")).startFolderExportWorker
      : (await import("../src/exports/csvWorker.js")).startCsvExportWorker;
    start(log); start(log);
    await vi.advanceTimersByTimeAsync(300_000);
    expect(state.scans).toBe(1); expect(state.claims).toBe(1);
    expect(vi.getTimerCount()).toBe(0);
    held.resolve({ data: null, error: new Error("manifest unavailable") });
    await vi.advanceTimersByTimeAsync(0);
    expect(state.updates).toContain("failed");
    await vi.advanceTimersByTimeAsync(4_999);
    expect(state.claims).toBe(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(state.scans).toBe(2); expect(state.claims).toBe(2);
  });
});
