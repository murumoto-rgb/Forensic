import { useEffect, useState } from "react";
import type { AITagPhotoModel } from "@forensic/shared";

/**
 * Per-user AI prefs hook (Build #5.85.1).
 *
 * Backs three knobs the settings page (and the batch-retag control)
 * read every render: AI model, parallel-request concurrency, and the
 * tag confidence threshold. localStorage-backed today; a follow-on
 * PR will sync these to the server so they follow the user across
 * devices.
 *
 * Mirrors the storage-event + custom-in-tab-event pattern from
 * `useTagConfidenceThreshold` so multiple instances stay in sync.
 * The threshold key (`sitephoto.tagConfidenceThreshold`) is the
 * same one `useTagConfidenceThreshold` uses — both hooks back the
 * same value, and updating either re-renders the other.
 *
 * Model storage key is `sitephoto.aiModel` — mirrors the iOS
 * UserDefault of the same name.
 * Concurrency key is `sitephoto.aiConcurrency` — iOS-side is per-
 * batch + ephemeral, no UserDefault to mirror.
 */

const MODEL_KEY = "sitephoto.aiModel";
const CONCURRENCY_KEY = "sitephoto.aiConcurrency";
const THRESHOLD_KEY = "sitephoto.tagConfidenceThreshold";

const DEFAULT_MODEL: AITagPhotoModel = "claude-sonnet-4-6";
const DEFAULT_CONCURRENCY = 3;
const DEFAULT_THRESHOLD = 0.5;

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

export interface UserPrefs {
  model: AITagPhotoModel;
  concurrency: number;
  threshold: number;
  setModel: (next: AITagPhotoModel) => void;
  setConcurrency: (next: number) => void;
  setThreshold: (next: number) => void;
}

export function useUserPrefs(): UserPrefs {
  const [model, setModelState] = useState<AITagPhotoModel>(() => readModel());
  const [concurrency, setConcurrencyState] = useState<number>(() =>
    readConcurrency()
  );
  const [threshold, setThresholdState] = useState<number>(() => readThreshold());

  useEffect(() => {
    function refresh() {
      setModelState(readModel());
      setConcurrencyState(readConcurrency());
      setThresholdState(readThreshold());
    }
    function onStorage(e: StorageEvent) {
      if (
        e.key === MODEL_KEY ||
        e.key === CONCURRENCY_KEY ||
        e.key === THRESHOLD_KEY
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
  }

  function setConcurrency(next: number) {
    const clamped = Math.max(1, Math.min(20, Math.round(next)));
    setConcurrencyState(clamped);
    window.localStorage.setItem(CONCURRENCY_KEY, String(clamped));
    window.dispatchEvent(new Event(EVENT_NAME));
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
  }

  return {
    model,
    concurrency,
    threshold,
    setModel,
    setConcurrency,
    setThreshold,
  };
}
