import { useEffect, useRef, useState } from "react";
import type { AITagPhotoModel, PlanColorMode } from "@forensic/shared";
import { PLAN_COLOR_MODES } from "@forensic/shared";
import { api, ApiError } from "./api";

/**
 * Per-user AI prefs hook (Build #5.85.1; server-sync added #5.95.1).
 *
 * Backs three knobs the settings page (and the batch-retag control)
 * read every render: AI model, parallel-request concurrency, and the
 * tag confidence threshold.
 *
 * **localStorage is the source of truth** for hot reads — every
 * `useUserPrefs()` call returns the localStorage value immediately
 * so the UI never blocks on the network. On first mount we trigger
 * a single best-effort `GET /v1/me/prefs` and merge any server-side
 * values into localStorage if the user hadn't already set them
 * locally (defensive — don't clobber the user's local choice with
 * a stale server value). Subsequent setters write through both:
 * localStorage (instant) and a debounced `PUT /v1/me/prefs` (every
 * 1 second of idle).
 *
 * Cross-tab + cross-device sync paths:
 *   - Same tab: custom `sitephoto:prefsChanged` event.
 *   - Cross-tab (same browser): `storage` event.
 *   - Cross-device: server round-trip on next mount.
 *
 * Storage keys (unchanged from #5.85.1):
 *   - `sitephoto.aiModel`
 *   - `sitephoto.aiConcurrency`
 *   - `sitephoto.tagConfidenceThreshold` (shared with
 *     `useTagConfidenceThreshold`).
 */

const MODEL_KEY = "sitephoto.aiModel";
const CONCURRENCY_KEY = "sitephoto.aiConcurrency";
const THRESHOLD_KEY = "sitephoto.tagConfidenceThreshold";
// Build #6.13.1: was localStorage-only inside FloorPlanTab; now
// surfaced through useUserPrefs so it follows the user across browsers
// and devices alongside the existing AI prefs.
const BUBBLE_SCALE_KEY = "sitephoto.planBubbleScale";
// Build #6.26.1: same key + rawValues as iOS's PlanColorMode
// (UserDefaults "sitephoto.plan.colorMode") so both stores describe
// the same concept; synced cross-device via user_prefs like the rest.
const COLOR_MODE_KEY = "sitephoto.plan.colorMode";

const DEFAULT_MODEL: AITagPhotoModel = "claude-sonnet-4-6";
const DEFAULT_CONCURRENCY = 3;
const DEFAULT_THRESHOLD = 0.5;
const DEFAULT_BUBBLE_SCALE = 1.5;
export type { PlanColorMode };
const VALID_COLOR_MODES: PlanColorMode[] = [...PLAN_COLOR_MODES];
const DEFAULT_COLOR_MODE: PlanColorMode = "status";
const BUBBLE_SCALE_MIN = 0.5;
const BUBBLE_SCALE_MAX = 4;

const VALID_MODELS: AITagPhotoModel[] = [
  "claude-sonnet-4-6",
  "claude-haiku-4-5",
];

const EVENT_NAME = "sitephoto:prefsChanged";

function readModel(): AITagPhotoModel {
  if (typeof window === "undefined") return DEFAULT_MODEL;
  const raw = window.localStorage.getItem(MODEL_KEY);
  if (raw && (VALID_MODELS as string[]).includes(raw)) {
    return raw as AITagPhotoModel;
  }
  return DEFAULT_MODEL;
}

function readConcurrency(): number {
  if (typeof window === "undefined") return DEFAULT_CONCURRENCY;
  const raw = window.localStorage.getItem(CONCURRENCY_KEY);
  if (raw == null) return DEFAULT_CONCURRENCY;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed)) return DEFAULT_CONCURRENCY;
  return Math.max(1, Math.min(20, parsed));
}

function readThreshold(): number {
  if (typeof window === "undefined") return DEFAULT_THRESHOLD;
  const raw = window.localStorage.getItem(THRESHOLD_KEY);
  if (raw == null) return DEFAULT_THRESHOLD;
  const parsed = Number.parseFloat(raw);
  if (!Number.isFinite(parsed)) return DEFAULT_THRESHOLD;
  return Math.max(0, Math.min(1, parsed));
}

function readColorMode(): PlanColorMode {
  if (typeof window === "undefined") return DEFAULT_COLOR_MODE;
  const raw = window.localStorage.getItem(COLOR_MODE_KEY);
  if (raw && (VALID_COLOR_MODES as string[]).includes(raw)) {
    return raw as PlanColorMode;
  }
  return DEFAULT_COLOR_MODE;
}

function readBubbleScale(): number {
  if (typeof window === "undefined") return DEFAULT_BUBBLE_SCALE;
  const raw = window.localStorage.getItem(BUBBLE_SCALE_KEY);
  if (raw == null) return DEFAULT_BUBBLE_SCALE;
  const parsed = Number.parseFloat(raw);
  if (!Number.isFinite(parsed)) return DEFAULT_BUBBLE_SCALE;
  return Math.max(BUBBLE_SCALE_MIN, Math.min(BUBBLE_SCALE_MAX, parsed));
}

export interface UserPrefs {
  model: AITagPhotoModel;
  concurrency: number;
  threshold: number;
  bubbleScale: number;
  planColorMode: PlanColorMode;
  setModel: (next: AITagPhotoModel) => void;
  setConcurrency: (next: number) => void;
  setThreshold: (next: number) => void;
  setBubbleScale: (next: number) => void;
  setPlanColorMode: (next: PlanColorMode) => void;
}

// Module-scoped state so multiple useUserPrefs callers in the same
// app share one initial-hydration + one debounce timer.
const serverState: {
  hydrated: boolean;
  revision: string;
  pendingTimer: ReturnType<typeof setTimeout> | null;
} = {
  hydrated: false,
  revision: "",
  pendingTimer: null,
};

/**
 * Best-effort initial fetch + merge from the server. Called once
 * per app load (module-scoped flag). Server values fill in fields
 * that aren't already set in localStorage; existing local values
 * win (user's local choice should never get clobbered by a stale
 * server copy).
 */
async function hydrateOnce(refresh: () => void): Promise<void> {
  if (serverState.hydrated) return;
  serverState.hydrated = true;
  try {
    const resp = await api.getUserPrefs();
    serverState.revision = resp.revision;
    const {
      aiModel,
      tagConfidenceThreshold,
      aiConcurrency,
      planBubbleScale,
      planColorMode,
    } = resp.prefs;
    if (
      aiModel != null &&
      typeof window !== "undefined" &&
      window.localStorage.getItem(MODEL_KEY) == null
    ) {
      window.localStorage.setItem(MODEL_KEY, aiModel);
    }
    if (
      aiConcurrency != null &&
      typeof window !== "undefined" &&
      window.localStorage.getItem(CONCURRENCY_KEY) == null
    ) {
      window.localStorage.setItem(CONCURRENCY_KEY, String(aiConcurrency));
    }
    if (
      tagConfidenceThreshold != null &&
      typeof window !== "undefined" &&
      window.localStorage.getItem(THRESHOLD_KEY) == null
    ) {
      window.localStorage.setItem(THRESHOLD_KEY, String(tagConfidenceThreshold));
    }
    if (
      planBubbleScale != null &&
      typeof window !== "undefined" &&
      window.localStorage.getItem(BUBBLE_SCALE_KEY) == null
    ) {
      window.localStorage.setItem(BUBBLE_SCALE_KEY, String(planBubbleScale));
    }
    if (
      planColorMode != null &&
      typeof window !== "undefined" &&
      window.localStorage.getItem(COLOR_MODE_KEY) == null &&
      (VALID_COLOR_MODES as string[]).includes(planColorMode)
    ) {
      window.localStorage.setItem(COLOR_MODE_KEY, planColorMode);
    }
    refresh();
  } catch (e: unknown) {
    if (!(e instanceof ApiError)) {
      // Network failure — leave localStorage values intact and try
      // again on next mount (hydrated flag stays true for this
      // session to avoid hammering the endpoint, but it's only a
      // session-level penalty).
    }
  }
}

/**
 * Schedule a debounced PUT of the current localStorage prefs to the
 * server. Coalesces rapid writes into one request 1 second after
 * the latest change.
 */
function scheduleSync(): void {
  if (serverState.pendingTimer) clearTimeout(serverState.pendingTimer);
  serverState.pendingTimer = setTimeout(() => {
    serverState.pendingTimer = null;
    const prefs = {
      aiModel: typeof window === "undefined"
        ? null
        : window.localStorage.getItem(MODEL_KEY),
      aiConcurrency: typeof window === "undefined"
        ? null
        : (() => {
            const v = window.localStorage.getItem(CONCURRENCY_KEY);
            return v == null ? null : Number.parseInt(v, 10);
          })(),
      tagConfidenceThreshold: typeof window === "undefined"
        ? null
        : (() => {
            const v = window.localStorage.getItem(THRESHOLD_KEY);
            return v == null ? null : Number.parseFloat(v);
          })(),
      planBubbleScale: typeof window === "undefined"
        ? null
        : (() => {
            const v = window.localStorage.getItem(BUBBLE_SCALE_KEY);
            return v == null ? null : Number.parseFloat(v);
          })(),
      planColorMode: typeof window === "undefined"
        ? null
        : window.localStorage.getItem(COLOR_MODE_KEY),
    };
    api
      .putUserPrefs({
        prefs,
        expectedRevision: serverState.revision || null,
      })
      .then((resp) => {
        serverState.revision = resp.revision;
      })
      .catch(() => {
        // Network / 409 failures are non-fatal — localStorage stays
        // canonical for the current session; next mount will retry.
      });
  }, 1000);
}

export function useUserPrefs(): UserPrefs {
  const [model, setModelState] = useState<AITagPhotoModel>(() => readModel());
  const [concurrency, setConcurrencyState] = useState<number>(() =>
    readConcurrency()
  );
  const [threshold, setThresholdState] = useState<number>(() => readThreshold());
  const [bubbleScale, setBubbleScaleState] = useState<number>(() =>
    readBubbleScale()
  );
  const [planColorMode, setPlanColorModeState] = useState<PlanColorMode>(() =>
    readColorMode()
  );
  const refreshRef = useRef<() => void>(() => undefined);

  useEffect(() => {
    function refresh() {
      setModelState(readModel());
      setConcurrencyState(readConcurrency());
      setThresholdState(readThreshold());
      setBubbleScaleState(readBubbleScale());
      setPlanColorModeState(readColorMode());
    }
    refreshRef.current = refresh;
    function onStorage(e: StorageEvent) {
      if (
        e.key === MODEL_KEY ||
        e.key === CONCURRENCY_KEY ||
        e.key === THRESHOLD_KEY ||
        e.key === BUBBLE_SCALE_KEY ||
        e.key === COLOR_MODE_KEY
      ) {
        refresh();
      }
    }
    function onCustom() {
      refresh();
    }
    window.addEventListener("storage", onStorage);
    window.addEventListener(EVENT_NAME, onCustom);
    // Keep the legacy single-key event firing the threshold sync so
    // older `useTagConfidenceThreshold` instances still wake up.
    window.addEventListener("sitephoto:thresholdChanged", onCustom);
    // Fire the once-per-session server hydrate.
    void hydrateOnce(() => refreshRef.current());
    return () => {
      window.removeEventListener("storage", onStorage);
      window.removeEventListener(EVENT_NAME, onCustom);
      window.removeEventListener("sitephoto:thresholdChanged", onCustom);
    };
  }, []);

  function setModel(next: AITagPhotoModel) {
    if (!(VALID_MODELS as string[]).includes(next)) return;
    setModelState(next);
    window.localStorage.setItem(MODEL_KEY, next);
    window.dispatchEvent(new Event(EVENT_NAME));
    scheduleSync();
  }

  function setConcurrency(next: number) {
    const clamped = Math.max(1, Math.min(20, Math.round(next)));
    setConcurrencyState(clamped);
    window.localStorage.setItem(CONCURRENCY_KEY, String(clamped));
    window.dispatchEvent(new Event(EVENT_NAME));
    scheduleSync();
  }

  function setThreshold(next: number) {
    const clamped = Math.max(0, Math.min(1, next));
    setThresholdState(clamped);
    window.localStorage.setItem(THRESHOLD_KEY, String(clamped));
    // Notify both the new combined event AND the legacy
    // single-key event so existing `useTagConfidenceThreshold`
    // instances pick up the change without refactor.
    window.dispatchEvent(new Event(EVENT_NAME));
    window.dispatchEvent(new Event("sitephoto:thresholdChanged"));
    scheduleSync();
  }

  function setBubbleScale(next: number) {
    const clamped = Math.max(
      BUBBLE_SCALE_MIN,
      Math.min(BUBBLE_SCALE_MAX, next)
    );
    setBubbleScaleState(clamped);
    window.localStorage.setItem(BUBBLE_SCALE_KEY, String(clamped));
    window.dispatchEvent(new Event(EVENT_NAME));
    scheduleSync();
  }

  function setPlanColorMode(next: PlanColorMode) {
    if (!VALID_COLOR_MODES.includes(next)) return;
    setPlanColorModeState(next);
    window.localStorage.setItem(COLOR_MODE_KEY, next);
    window.dispatchEvent(new Event(EVENT_NAME));
    scheduleSync();
  }

  return {
    model,
    concurrency,
    threshold,
    bubbleScale,
    planColorMode,
    setModel,
    setConcurrency,
    setThreshold,
    setBubbleScale,
    setPlanColorMode,
  };
}
